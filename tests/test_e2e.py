"""End-to-end: run despell against e2e_projects/simple with a real Mojo."""

import json
import os
import shutil
from pathlib import Path

import pytest

from despell.cli import main
from despell.project import ConfigError, find_mojo, load_config

ROOT = Path(__file__).parent.parent
PROJECT = ROOT / "e2e_projects" / "simple"

EXPECTED = {
    "mylib.mathx.add.1": "killed",
    "mylib.mathx.clamp.1": "survived",
    "mylib.mathx.clamp.2": "survived",
    "mylib.mathx.is_even.1": "killed",
    "mylib.mathx.is_even.2": "killed",
    "mylib.mathx.is_even.3": "killed",
    "mylib.mathx.is_even.4": "killed",
    "mylib.mathx.table_size.1": "skipped",
    "mylib.mathx.table_size.2": "skipped",
    "mylib.mathx.table_size.3": "skipped",
    "mylib.mathx.sum_to.1": "killed",
    "mylib.mathx.sum_to.2": "killed",
    "mylib.mathx.sum_to.3": "killed",
    "mylib.mathx.scale.1": "killed",
    "mylib.mathx.greeting.1": "killed",
    "mylib.mathx.greeting.2": "compile_error",
    "mylib.mathx.Counter.__init__.1": "survived",
    "mylib.mathx.Counter.tick.1": "survived",
    "mylib.mathx.Counter.tick.2": "survived",
    "mylib.mathx.Counter.is_done.1": "survived",
    "mylib.mathx.Counter.is_done.2": "killed",
    "mylib.mathx.Counter.is_done.3": "survived",
    "mylib.mathx.Counter.is_done.4": "survived",
    "mylib.mathx.Counter.is_done.5": "survived",
    "mylib.mathx.countdown.1": "killed",
    "mylib.mathx.countdown.2": "killed",
    "mylib.mathx.countdown.3": "killed",
    "mylib.mathx.countdown.4": "killed",
    "mylib.mathx.countdown.5": "timeout",
    "mylib.mathx.countdown.6": "killed",
    "mylib.mathx.countdown.7": "killed",
    "mylib.mathx.countdown.8": "killed",
    "mylib.mathx.countdown.9": "killed",
    "mylib.mathx.untested.1": "no_tests",
    "mylib.mathx.untested.2": "no_tests",
    "mylib.tricky.Shape.describe.1": "killed",
    "mylib.tricky.Shape.describe.2": "compile_error",
    "mylib.tricky.Rect.area.1": "killed",
    "mylib.tricky.Rect.__eq__.1": "killed",
    "mylib.tricky.Rect.__eq__.2": "survived",
    "mylib.tricky.Rect.__eq__.3": "killed",
    "mylib.tricky.banner.1": "killed",
    "mylib.tricky.nested.1": "killed",
    "mylib.tricky.nested.2": "killed",
    "mylib.tricky.take_list.1": "survived",
    "mylib.tricky.take_list.2": "survived",
    "mylib.tricky.count_words.1": "killed",
    "mylib.tricky.count_words.2": "compile_error",
    "mylib.tricky.count_words.3": "survived",
    "mylib.tricky.count_words.4": "survived",
    "mylib.tricky.count_words.5": "killed",
    "mylib.tricky.count_words.6": "killed",
    "mylib.tricky.count_words.7": "killed",
    "mylib.tricky.count_words.8": "killed",
    "mylib.tricky.first_big.1": "survived",
    "mylib.tricky.first_big.2": "survived",
    "mylib.tricky.first_big.3": "survived",
    "mylib.tricky.bits.1": "survived",
    "mylib.tricky.bits.2": "survived",
    "mylib.tricky.bits.3": "survived",
    "mylib.tricky.bits.4": "survived",
    "mylib.tricky.bits.5": "survived",
    "mylib.tricky.bits.6": "survived",
    "mylib.tricky.bits.7": "survived",
    "mylib.tricky.bits.8": "survived",
    "mylib.tricky.float_math.1": "killed",
    "mylib.tricky.float_math.2": "killed",
    "mylib.tricky.float_math.3": "killed",
    "mylib.tricky.float_math.4": "killed",
    "mylib.tricky.comptime_branch.1": "killed",
    "mylib.tricky.comptime_branch.2": "killed",
    "mylib.tricky.safe_div.1": "killed",
    "mylib.tricky.safe_div.2": "killed",
    "mylib.tricky.safe_div.3": "killed",
    "mylib.tricky.partly_ignored.1": "killed",
    "mylib.tricky.partly_ignored.2": "killed",
}


@pytest.fixture(scope="module")
def project():
    # inside the repo so a pixi.toml up the tree supplies mojo
    dest = ROOT / "tmp" / "e2e" / "simple"
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(PROJECT, dest, ignore=shutil.ignore_patterns("mutants"))
    try:
        find_mojo(load_config(dest))
    except ConfigError as e:
        pytest.skip(str(e))
    old = os.getcwd()
    os.chdir(dest)
    try:
        assert main(["run", "-j", "4"]) == 0
        yield dest
    finally:
        os.chdir(old)


def test_statuses(project):
    data = json.loads((project / "mutants" / "despell.json").read_text())
    assert {m["id"]: m["status"] for m in data["mutants"]} == EXPECTED


def test_results_lists_actionable(project, capsys):
    assert main(["results"]) == 0
    out = capsys.readouterr().out
    assert "survived      mylib.mathx.clamp.1" in out
    assert "no_tests      mylib.mathx.untested.1" in out
    assert "mylib.mathx.add.1" not in out


def test_show(project, capsys):
    assert main(["show", "mylib.mathx.clamp.1"]) == 0
    out = capsys.readouterr().out
    assert "tests reaching clamp: tests/test_mathx.mojo::test_clamp" in out
    assert "-    if x < lo:\n+    if x <= lo:" in out


def test_rerun_single_mutant_after_adding_a_test(project, capsys):
    test_file = project / "tests" / "test_mathx.mojo"
    source = test_file.read_text()
    test_file.write_text(
        source.replace(
            "def main() raises:",
            "def test_tick_twice() raises:\n    var c = Counter(2)\n    c.tick()\n    c.tick()\n    assert_equal(c.count, 4)\n\n\ndef main() raises:",
        )
    )
    try:
        assert main(["run", "-j", "4", "mylib.mathx.Counter.tick"]) == 0
        out = capsys.readouterr().out
        assert "2 mutants: 2 killed" in out
        data = json.loads((project / "mutants" / "despell.json").read_text())
        statuses = {m["id"]: m["status"] for m in data["mutants"]}
        # untouched mutants keep their earlier results
        assert statuses["mylib.mathx.untested.1"] == "no_tests"
        assert statuses["mylib.mathx.clamp.1"] == "survived"
    finally:
        test_file.write_text(source)
