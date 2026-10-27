from std.ffi import external_call
from std.testing import assert_equal, assert_true, assert_false, TestSuite

from despell.fsutil import hash_text, join, parent, real_path, relative_to, basename
from despell.jsonio import Json, encode, parse
from despell.fsutil import mkdirs, rmtree, write_text
from despell.sysutil import ProcessPool, cpu_ticks, environment, kill_strays, lock_file, memory_available, run_command, unlock_file
from despell.toml import read_table


def test_json_round_trip() raises:
    var obj = Json.object()
    obj.set("name", Json.of(String('a "quoted"\nline\\ é')))
    obj.set("n", Json.of(3))
    obj.set("x", Json.of(2.5))
    obj.set("none", Json())
    obj.set("flag", Json.of(True))
    obj.set("list", Json.ints([1, 2, 3]))
    var back = parse(encode(obj, indent=1))
    assert_equal(back.str_or("name", ""), String('a "quoted"\nline\\ é'))
    assert_equal(back.int_or("n", 0), 3)
    assert_equal(back.float_or("x", 0), 2.5)
    assert_true(back.get("none").is_null())
    assert_true(back.get("flag").as_bool())
    assert_equal(len(back.int_list("list")), 3)
    assert_equal(encode(back), encode(obj))


def test_json_unicode_escapes() raises:
    assert_equal(parse('"\\u00e9\\ud83d\\ude00"').as_string(), String("é😀"))


def test_toml_tables() raises:
    var text = String(
        "[workspace]\nname = \"x\"  # comment\n\n[tool.despell]\n"
        "paths_to_mutate = [\n  \"src\",  # mine\n  'lib',\n]\n"
        "timeout_multiplier = 2.5\nmojo = \"a#b\"\nworkers = 3\n\n[other]\nk = { a = 1 }\n"
    )
    var t = read_table(text, "tool.despell").value().copy()
    assert_equal(len(t.str_list("paths_to_mutate")), 2)
    assert_equal(t.str_list("paths_to_mutate")[1], String("lib"))
    assert_equal(t.float_or("timeout_multiplier", 0), 2.5)
    assert_equal(t.str_or("mojo", ""), String("a#b"))
    assert_equal(t.int_or("workers", 0), 3)
    assert_false(Bool(read_table(text, "tool.missing")))
    assert_equal(read_table(String("tests_dir = \"t\"\n[x]\ny = 1\n"), "").value().copy().str_or("tests_dir", ""), String("t"))


def test_paths() raises:
    assert_equal(join("a", "b"), String("a/b"))
    assert_equal(join("a/", "b"), String("a/b"))
    assert_equal(parent("a/b/c.mojo"), String("a/b"))
    assert_equal(basename("a/b/c.mojo"), String("c.mojo"))
    assert_equal(relative_to("/x/y/z", "/x"), String("y/z"))


def test_a_child_using_too_much_memory_is_stopped() raises:
    var pool = ProcessPool()
    var argv = List[String]()
    for a in ["perl", "-e", "$x = 'a' x 400_000_000; sleep 10"]:
        argv.append(String(a))
    pool.start(1, argv, ".", environment(), 20, memory_limit=100_000_000)
    var f = pool.wait_any()
    assert_true(f.over_memory)
    assert_true(f.memory > 100_000_000, String(f.memory))
    assert_true(f.seconds < 5, String(f.seconds))


def test_peak_memory_of_a_child() raises:
    var pool = ProcessPool()
    var argv = List[String]()
    for a in ["perl", "-e", "$x = 'a' x 50_000_000"]:
        argv.append(String(a))
    pool.start(1, argv, ".", environment(), 20)
    var f = pool.wait_any()
    assert_false(f.over_memory)
    assert_true(f.memory > 50_000_000, String(f.memory))
    var available = memory_available()
    assert_true(available > 0 and available <= 1, String(available))


def test_cpu_ticks_count_up() raises:
    var a = cpu_ticks()
    var spin = 0
    for i in range(50_000_000):
        spin += i % 7
    var b = cpu_ticks()
    assert_true(a.total > 0 and a.idle <= a.total, String(a.idle) + " " + String(a.total))
    assert_true(b.total > a.total and b.idle >= a.idle, String(spin))


def test_children_dont_inherit_locks() raises:
    # one outliving us would hold the lock forever
    mkdirs("tmp/infra")
    var lock = lock_file("tmp/infra/held.lock", False)
    assert_true(lock >= 0)
    var pool = ProcessPool()
    var argv = List[String]()
    for a in ["sleep", "5"]:
        argv.append(String(a))
    pool.start(1, argv, ".", environment(), 20)
    unlock_file(lock)
    var again = lock_file("tmp/infra/held.lock", False)
    assert_true(again >= 0)
    unlock_file(again)
    pool.kill_all()


def test_strays_are_killed() raises:
    rmtree("tmp/infra/strays")
    mkdirs("tmp/infra/strays/.despell/bin")
    # a program of our own (a copy of a system one doesn't run)
    write_text("tmp/infra/strays/sleepy.mojo", "from std.time import sleep\n\n\ndef main():\n    sleep(30.0)\n")
    var build = List[String]()
    for a in ["mojo", "build", "tmp/infra/strays/sleepy.mojo", "-o", "tmp/infra/strays/.despell/bin/sleepy"]:
        build.append(String(a))
    assert_equal(run_command(build, ".", environment()).code, 0)
    var pool = ProcessPool()
    var argv = List[String]()
    for a in ["tmp/infra/strays/.despell/bin/sleepy", "30"]:
        argv.append(String(a))
    pool.start(1, argv, ".", environment(), 60)
    var other = List[String]()
    for a in ["sleep", "30"]:
        other.append(String(a))
    pool.start(2, other, ".", environment(), 60)
    _ = external_call["usleep", Int32](UInt32(200000))
    assert_equal(kill_strays(real_path("tmp/infra/strays/.despell")), 1)
    var f = pool.wait_any()
    assert_equal(f.tag, 1)
    assert_true(f.seconds < 5, String(f.seconds))
    pool.kill_all()


def test_hash_is_stable() raises:
    assert_equal(hash_text("abc"), hash_text("abc"))
    assert_true(hash_text("abc") != hash_text("abd"))
    assert_equal(hash_text("").byte_length(), 16)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
