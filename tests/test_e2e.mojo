"""End to end: run the despell binary (build/despell) on e2e_projects/simple.

The tests share one copy of the project and run in order, each building on
the state the previous ones left.
"""

from std.collections import Dict
from std.testing import assert_equal, assert_true, assert_false, TestSuite

from despell.fsutil import copy_tree, join, read_text, real_path, rmtree, write_text, remove_file
from despell.jsonio import Json, encode, parse
from despell.sysutil import Finished, environment, run_command, with_env

comptime PROJECT = "tmp/e2e/simple"


def despell(*args: String) raises -> String:
    """Run despell in the project; its output (failing on a non-zero exit)."""
    var argv = List[String]()
    for a in args:
        argv.append(a)
    return despell_with(List[String](), argv)


def despell_with(env: List[String], args: List[String]) raises -> String:
    """`despell`, with `env` (NAME=value) added to the environment."""
    var argv = List[String]()
    argv.append(real_path("build/despell"))
    for a in args:
        argv.append(a)
    var r = run_command(argv, real_path(PROJECT), with_env(environment(), env))
    if r.code != 0:
        raise Error("despell " + args[0] + " exited with " + String(r.code) + ":\n" + r.output)
    return r.output


def statuses() raises -> Dict[String, String]:
    var data = parse(read_text(join(PROJECT, "mutants/despell.json")))
    var out = Dict[String, String]()
    for m in data.get("mutants").items:
        out[m.str_or("id", "")] = m.str_or("status", "")
    return out^


def expected() raises -> Dict[String, String]:
    var out = Dict[String, String]()
    for line in read_text("tests/e2e_expected.txt").splitlines():
        var parts = String(line).split(" ")
        out[String(parts[0])] = String(parts[1])
    return out^


def assert_expected() raises:
    var got = statuses()
    var want = expected()
    assert_equal(len(got), len(want))
    for item in want.items():
        assert_equal(got.get(item.key, "missing"), item.value, item.key)


def test_1_statuses() raises:
    rmtree(PROJECT)
    var skip = List[String]()
    skip.append("mutants")
    copy_tree("e2e_projects/simple", PROJECT, skip)
    _ = despell("run", "-j", "4")
    assert_expected()


def test_2_results_lists_actionable() raises:
    var out = despell("results")
    assert_true("survived      mylib.mathx.clamp.1" in out)
    assert_true("no_tests      mylib.mathx.untested.1" in out)
    assert_false("mylib.mathx.add.1" in out)


def test_3_show() raises:
    var out = despell("show", "mylib.mathx.clamp.1")
    assert_true("tests reaching line 10: tests/test_mathx.mojo::test_clamp" in out)
    assert_true("-    if x < lo:\n+    if x <= lo:" in out)


def test_4_run_continues_where_it_stopped() raises:
    var path = join(PROJECT, "mutants/despell.json")
    var data = parse(read_text(path))
    # as if the run was interrupted before these two
    var mutants = data.get("mutants")
    for i in range(len(mutants.items)):
        var id = mutants.items[i].str_or("id", "")
        if id == "mylib.mathx.add.1" or id == "mylib.mathx.clamp.1":
            mutants.items[i].set("status", Json.of(String("not_checked")))
    data.set("mutants", mutants^)
    write_text(path, encode(data))
    var out = despell("run", "-j", "4")
    assert_true("running the other 2" in out, out)
    # nothing changed since the binaries were built, and they hold both
    assert_true("reusing the last build's test binaries" in out, out)
    assert_expected()
    assert_true("nothing to run" in despell("run", "-j", "4"))
    var forced = despell("run", "-j", "4", "--force", "mylib.mathx.add.1")
    assert_true("running 1 mutants" in forced and "1 mutants: 1 killed" in forced, forced)


def test_5_rerun_single_mutant_after_adding_a_test() raises:
    var test_file = join(PROJECT, "tests/test_mathx.mojo")
    var source = read_text(test_file)
    write_text(
        test_file,
        source.replace(
            "def main() raises:",
            "def test_tick_twice() raises:\n    var c = Counter(2)\n    c.tick()\n    c.tick()\n    assert_equal(c.count, 4)\n\n\ndef main() raises:",
        ),
    )
    var out = despell("run", "-j", "4", "mylib.mathx.Counter.tick")
    write_text(test_file, source)
    assert_true("2 mutants: 2 killed" in out, out)
    # test_tricky doesn't reach Counter.tick and didn't change
    assert_true("building the 1 of 2 test files" in out, out)
    assert_false("reusing" in out, out)
    var s = statuses()
    # untouched mutants keep their earlier results
    assert_equal(s["mylib.mathx.untested.1"], String("no_tests"))
    assert_equal(s["mylib.mathx.clamp.1"], String("survived"))


def test_6_new_test_file_is_checked_against_survivors_only() raises:
    var new_file = join(PROJECT, "tests/test_bits.mojo")
    write_text(
        new_file,
        "from std.testing import assert_equal, TestSuite\nfrom mylib.tricky import bits\n\n\n"
        + "def test_bits() raises:\n    assert_equal(bits(5), 23)\n    assert_equal(bits(6), 25)\n\n\n"
        + "def main() raises:\n    TestSuite.discover_tests[__functions_in_module()]().run(quiet=True)\n",
    )
    var out = despell("run", "-j", "4")
    # killed mutants stay killed and survivors are only run against new and
    # changed files (test_mathx changed back after the test above), so
    # test_tricky isn't even built
    assert_true("building the 2 of 3 test files" in out, out)
    var s = statuses()
    assert_equal(s["mylib.tricky.bits.1"], String("killed"))
    assert_equal(s["mylib.mathx.add.1"], String("killed"))
    assert_equal(s["mylib.mathx.clamp.1"], String("survived"))
    var again = despell("run", "-j", "4")
    remove_file(new_file)
    assert_true("nothing to run" in again, again)


def test_7_coverage_first() raises:
    # from scratch, measuring coverage before building with mutants: each
    # test binary only gets the mutants its tests reach, same results
    rmtree(PROJECT)
    var skip = List[String]()
    skip.append("mutants")
    copy_tree("e2e_projects/simple", PROJECT, skip)
    var out = despell_with([String("DESPELL_COVERAGE_FIRST=0")], [String("run"), String("-j"), String("4")])
    assert_true("measured coverage first, building 2 test files" in out, out)
    assert_expected()
    var files = parse(read_text(join(PROJECT, "mutants/.despell/bin/manifest.json"))).get("files")
    var a = len(files.get("tests/test_mathx.mojo").int_list("enabled"))
    var b = len(files.get("tests/test_tricky.mojo").int_list("enabled"))
    assert_true(a > 0 and b > 0 and a + b < 70, String(a) + " " + String(b))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
