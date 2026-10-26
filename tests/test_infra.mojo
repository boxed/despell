from std.testing import assert_equal, assert_true, assert_false, TestSuite

from despell.fsutil import hash_text, join, parent, relative_to, basename
from despell.jsonio import Json, encode, parse
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


def test_hash_is_stable() raises:
    assert_equal(hash_text("abc"), hash_text("abc"))
    assert_true(hash_text("abc") != hash_text("abd"))
    assert_equal(hash_text("").byte_length(), 16)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
