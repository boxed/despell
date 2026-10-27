from std.collections import Dict, Set
from std.testing import assert_equal, assert_true, assert_false, TestSuite

from despell.fsutil import mkdirs, real_path, rmtree
from despell.project import load_config
from despell.state import (
    KILLED, SURVIVED, MutantRecord, State, TestRecord, merge_result, note_matches, plan, read_state, unmatched_error,
    write_state,
)
from despell.sysutil import monotonic_ns, seconds_since


def mutant(status: String = "not_checked", fingerprint: String = "abc", tested_with: String = "", killed_by: String = "") -> MutantRecord:
    var m = MutantRecord("m.f.1", 1, 0, "src/m.mojo", 1, 1, 2, "f", "`<` -> `<=`", "<", "<=", fingerprint)
    m.status = status
    m.tested_with = tested_with
    m.killed_by = killed_by
    return m^


def snap(b: String = "2", star: String = "x", extra: String = "") -> Dict[String, String]:
    var d = Dict[String, String]()
    d["tests/a.mojo"] = "1"
    d["tests/b.mojo"] = b
    d["*"] = star
    d["sources"] = "s"
    if extra.byte_length():
        d["tests/c.mojo"] = extra
    return d^


def snapshots() -> Dict[String, Dict[String, String]]:
    var s = Dict[String, Dict[String, String]]()
    s["s1"] = snap()
    return s^


def test_new_mutant_runs_against_everything() raises:
    var p = plan(mutant(), None, snapshots(), snap())
    assert_true(p.run and p.all_files)


def test_changed_code_runs_against_everything() raises:
    var p = plan(mutant(), mutant(SURVIVED, "old", "s1"), snapshots(), snap())
    assert_true(p.run and p.all_files)


def test_survivor_runs_against_new_and_changed_test_files_only() raises:
    var p = plan(mutant(), mutant(SURVIVED, "abc", "s1"), snapshots(), snap("changed", "x", "new"))
    assert_true(p.run and not p.all_files)
    assert_equal(len(p.files), 2)
    assert_true("tests/b.mojo" in p.files and "tests/c.mojo" in p.files)
    assert_false(plan(mutant(), mutant(SURVIVED, "abc", "s1"), snapshots(), snap()).run)


def test_killed_stays_killed_while_its_killer_is_unchanged() raises:
    var old = mutant(KILLED, "abc", "s1", "tests/a.mojo::test_x")
    assert_false(plan(mutant(), old.copy(), snapshots(), snap("changed")).run)
    # when it changes, it's tried first, and everything else only if it no
    # longer kills it
    var now = snap()
    now["tests/a.mojo"] = "changed"
    var p = plan(mutant(), old.copy(), snapshots(), now)
    assert_true(p.run and not p.all_files and p.retry)
    assert_true("tests/a.mojo" in p.files)
    # and when it's gone, everything that reaches it is
    var gone = snap()
    _ = gone.pop("tests/a.mojo")
    p = plan(mutant(), old^, snapshots(), gone)
    assert_true(p.run and p.all_files and not p.retry)


def test_changed_shared_test_code_runs_everything() raises:
    var p = plan(mutant(), mutant(SURVIVED, "abc", "s1"), snapshots(), snap("2", "y"))
    assert_true(p.run and p.all_files)


def test_merging_keeps_a_kill_another_run_saved_meanwhile() raises:
    var killed = mutant(KILLED, "abc", "newer", "tests/new.mojo::test_x")
    var survived = mutant(SURVIVED, "abc", "older")
    var before = mutant(SURVIVED, "abc", "oldest")
    assert_equal(merge_result(survived, killed.copy(), before.copy(), True).status, String(KILLED))
    # a kill that was already there when this run started is what it re-checked
    assert_equal(merge_result(survived, killed.copy(), killed.copy(), True).status, String(SURVIVED))
    assert_equal(merge_result(survived, killed.copy(), before.copy(), False).status, String(KILLED))
    assert_equal(merge_result(survived, mutant(KILLED, "other code"), None, False).status, String(SURVIVED))


def test_every_selector_that_matches_nothing_is_named() raises:
    var selectors: List[String] = ["m.f", "src/m.mojo:1", "m.g", "src/m.mojo::f", "m.*.1"]
    var matched = List[Bool](length=len(selectors), fill=False)
    assert_true(note_matches(mutant(), selectors, matched))
    assert_equal(String(matched), String([True, True, False, False, True]))
    var error = unmatched_error(selectors, matched)
    assert_true(error.startswith("no mutants match m.g src/m.mojo::f ("), error)
    matched = [True, True, True, True, True]
    assert_equal(unmatched_error(selectors, matched), "")


def test_a_result_kept_from_before_moves_with_the_code() raises:
    # lines added above the function: same code, new line and numbers
    var moved = MutantRecord("m.f.1", 7, 3, "src/m.mojo", 11, 1, 2, "f", "`<` -> `<=`", "<", "<=", "abc", 40)
    var saved = merge_result(moved, mutant(KILLED, "abc", "s1", "tests/a.mojo::test_x"), None, False)
    assert_equal(saved.status, String(KILLED))
    assert_equal(saved.killed_by, String("tests/a.mojo::test_x"))
    assert_equal(saved.line, 11)
    assert_equal(saved.number, 7)
    assert_equal(saved.site, 40)


def test_coverage_from_other_code_reaches_by_function_name() raises:
    var state = State()
    var now = snap()
    now["sources"] = "new"
    state.snapshots["now"] = now^
    var before = snap()
    before["functions"] = "src/m.mojo::g\nsrc/m.mojo::f\n"
    state.snapshots["before"] = before^
    state.numbered = "now"
    var m = mutant()  # in f, function 0 and site -1 now
    m.site = 5
    var fresh = TestRecord("tests/a.mojo::test_fresh", "tests/a.mojo", "test_fresh")
    fresh.snapshot = "now"
    fresh.sites = [5]
    var old_f = TestRecord("tests/b.mojo::test_f", "tests/b.mojo", "test_f")
    old_f.snapshot = "before"
    old_f.functions = [1]  # f, then
    old_f.sites = [5]  # some other statement, then
    var old_g = TestRecord("tests/b.mojo::test_g", "tests/b.mojo", "test_g")
    old_g.snapshot = "before"
    old_g.functions = [0]
    old_g.sites = [5]
    state.tests[fresh.id] = fresh^
    state.tests[old_f.id] = old_f^
    state.tests[old_g.id] = old_g^
    var reaching = state.tests_reaching(m)
    assert_equal(len(reaching[0]), 2)
    assert_equal(reaching[0][0], String("tests/a.mojo::test_fresh"))
    assert_equal(reaching[0][1], String("tests/b.mojo::test_f"))
    assert_false(reaching[1])
    _ = state.tests.pop("tests/b.mojo::test_f")
    _ = state.tests.pop("tests/b.mojo::test_g")
    assert_true(state.tests_reaching(m)[1])


def test_a_build_remembers_what_compiles_for_mutants_it_didnt_run() raises:
    # an interrupted run built mutants it never got to: a resumed run can
    # skip pre-checking them
    var built = mutant()
    built.compiles = True
    var saved = merge_result(built, mutant(), None, False)
    assert_equal(saved.status, String("not_checked"))
    assert_true(saved.compiles)
    assert_true(MutantRecord.from_json(saved.to_json()).compiles)
    assert_false(MutantRecord.from_json(mutant().to_json()).compiles)


def test_a_large_state_saves_and_loads_quickly() raises:
    # turbokod has ~53k mutants (25 MB of state), saved every 10s during a
    # run; anything quadratic in reading or writing it stalls the run
    var root = String("tmp/state_perf")
    rmtree(root)
    mkdirs(root + "/tests")
    var config = load_config(real_path(root))
    var state = State()
    for i in range(60000):
        var m = mutant(SURVIVED, tested_with="s1")
        m.id = "pkg.mod.f." + String(i)
        m.number = i + 1
        m.detail = "a \"quoted\" detail\nwith a newline"
        state.mutants[m.id] = m^
    state.snapshots = snapshots()
    var start = monotonic_ns()
    write_state(config, state)
    var loaded = read_state(config)
    var took = seconds_since(start)
    assert_equal(len(loaded.mutants), 60000)
    assert_equal(loaded.mutants["pkg.mod.f.59999"].detail, state.mutants["pkg.mod.f.59999"].detail)
    assert_true(took < 5.0, "saving and loading took " + String(took) + "s")
    rmtree(root)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
