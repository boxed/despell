from despell.runner import KILLED, MutantRecord, SURVIVED, _claim_tree, _plan, merge_result
from despell.project import Config


def mutant(**kw) -> MutantRecord:
    fields = dict(
        id="m.f.1", number=1, fid=0, file="src/m.mojo", line=1, col=1, end_col=2, function="f",
        description="`<` -> `<=`", original="<", replacement="<=", fingerprint="abc",
    )
    return MutantRecord(**(fields | kw))


SNAP = {"tests/a.mojo": "1", "tests/b.mojo": "2", "*": "x", "sources": "s"}


def test_new_mutant_runs_against_everything():
    assert _plan(mutant(), None, {}, SNAP) == (True, None)


def test_changed_code_runs_against_everything():
    old = mutant(fingerprint="old", status=SURVIVED, tested_with="s1")
    assert _plan(mutant(), old, {"s1": SNAP}, SNAP) == (True, None)


def test_survivor_runs_against_new_and_changed_test_files_only():
    old = mutant(status=SURVIVED, tested_with="s1")
    now = SNAP | {"tests/b.mojo": "changed", "tests/c.mojo": "new"}
    assert _plan(mutant(), old, {"s1": SNAP}, now) == (True, {"tests/b.mojo", "tests/c.mojo"})
    assert _plan(mutant(), old, {"s1": SNAP}, SNAP) == (False, None)


def test_killed_stays_killed_while_its_killer_is_unchanged():
    old = mutant(status=KILLED, killed_by="tests/a.mojo::test_x", tested_with="s1")
    assert _plan(mutant(), old, {"s1": SNAP}, SNAP | {"tests/b.mojo": "changed"}) == (False, None)
    assert _plan(mutant(), old, {"s1": SNAP}, SNAP | {"tests/a.mojo": "changed"}) == (True, None)


def test_changed_shared_test_code_runs_everything():
    old = mutant(status=SURVIVED, tested_with="s1")
    assert _plan(mutant(), old, {"s1": SNAP}, SNAP | {"*": "y"}) == (True, None)


def test_a_second_run_gets_its_own_tree(tmp_path):
    config = Config(root=tmp_path, paths_to_mutate=["src"], tests_dir="tests", include_dirs=["src"])
    with _claim_tree(config) as first:
        assert first == tmp_path / "mutants"
        with _claim_tree(config) as second:
            assert second.parent == tmp_path / "mutants" / ".side"
            second.mkdir(parents=True)
        assert not second.exists()


def test_merging_keeps_a_kill_another_run_saved_meanwhile():
    killed = mutant(status=KILLED, killed_by="tests/new.mojo::test_x", tested_with="newer")
    survived = mutant(status=SURVIVED, tested_with="older")
    before = mutant(status=SURVIVED, tested_with="oldest")
    assert merge_result(survived, killed, before, ran_it=True) is killed
    # a kill that was already there when this run started is what it re-checked
    assert merge_result(survived, killed, killed, ran_it=True) is survived
    assert merge_result(survived, killed, before, ran_it=False) is killed
    assert merge_result(survived, mutant(fingerprint="other code", status=KILLED), None, ran_it=False) is survived
