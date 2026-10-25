"""Command line interface.

The output is designed to be read by coding agents as much as by people:
plain lines, no progress bars, stable mutant ids, and every listing ends with
the command to run next.
"""

from __future__ import annotations

import argparse
import difflib
import json
import os
import sys
from collections import Counter
from dataclasses import asdict
from pathlib import Path

from .project import ConfigError, load_config
from .runner import (
    ACTIONABLE,
    STATUS_ORDER,
    MutantRecord,
    RunError,
    load_state,
    matches,
    run,
)

AGENT_GUIDE = """\
despell: mutation testing for Mojo

A mutant is a small change to your source code (e.g. `<` -> `<=`). If your
tests still pass with the change in place, the mutant "survived": either the
tests miss a behavior, or the change is equivalent and doesn't matter.

Workflow:
  despell run                     mutate everything under paths_to_mutate and test it
  despell results                 list survivors (and mutants with no covering tests)
  despell show <id> [<id> ...]    diff, location, and the tests that reach the code
  ... write or strengthen a test that would fail with the mutant applied ...
  despell run <id> [<id> ...]     re-check just those mutants

Selectors for `run`, `results` and `show`: a mutant id (mylib.math.clamp.2),
a function or module prefix (mylib.math.clamp, mylib.math), a glob
('mylib.*.clamp.*'), a source file (src/mylib/math.mojo) or file:line.

Statuses:
  killed         a test failed with the mutant applied (good)
  survived       all covering tests passed: add or improve a test
  no_tests       no test executes this function: add a test
  timeout        tests hung with the mutant applied (counts as killed)
  compile_error  the mutant doesn't compile (counts as killed)
  skipped        the function can't hold mutation schemata (e.g. evaluated at compile time)

Equivalent mutants (that can't be killed) can be silenced by adding
`# pragma: no mutate` to the line, or to the `def` line for a whole function.

Configuration, in despell.toml or [tool.despell] in pixi.toml/pyproject.toml:
  paths_to_mutate = ["src"]   tests_dir = "tests"   include_dirs = ["src"]
  also_copy = []  do_not_mutate = []  build_args = []  mojo = "mojo"
  timeout_multiplier = 10.0  timeout_floor = 2.0
Results are stored in mutants/despell.json.
"""


def _root() -> Path:
    return Path.cwd()


def _location(m: MutantRecord) -> str:
    return f"{m.file}:{m.line}:{m.col}"


def _print_table(mutants: list[MutantRecord], *, with_status: bool):
    if not mutants:
        return
    id_w = max(len(m.id) for m in mutants)
    loc_w = max(len(_location(m)) for m in mutants)
    for m in mutants:
        status = f"{m.status:<14}" if with_status else ""
        print(f"  {status}{m.id:<{id_w}}  {_location(m):<{loc_w}}  {m.description}")


def _summary(mutants: list[MutantRecord]):
    counts = Counter(m.status for m in mutants)
    parts = [f"{counts[s]} {s}" for s in STATUS_ORDER if counts[s]]
    total = len(mutants)
    killed = counts["killed"] + counts["timeout"] + counts["compile_error"]
    tested = total - counts["skipped"] - counts["not_checked"]
    score = f", score {100 * killed / tested:.1f}%" if tested else ""
    print(f"{total} mutants: {', '.join(parts) if parts else 'none'}{score}")


def _report(mutants: list[MutantRecord]):
    _summary(mutants)
    todo = [m for m in mutants if m.status in ACTIONABLE]
    if todo:
        print()
        print("To act on:")
        _print_table(_sorted(todo), with_status=True)
        print()
        print("Next: `despell show <id>` to see a mutant's diff and the tests that reach it.")


def _sorted(mutants: list[MutantRecord]) -> list[MutantRecord]:
    return sorted(mutants, key=lambda m: (m.file, m.line, m.col, m.number))


def cmd_run(args) -> int:
    config = load_config(_root())
    workers = args.jobs or max(1, (os.cpu_count() or 2) // 2)
    selected = run(config, selectors=args.selectors, workers=workers)
    print()
    _report(selected)
    return 0


def _load_selected(selectors: list[str]) -> list[MutantRecord]:
    config = load_config(_root())
    mutants, _ = load_state(config)
    if not mutants:
        raise RunError("no results yet; run `despell run` first")
    result = [m for m in mutants.values() if not selectors or matches(m, selectors)]
    if selectors and not result:
        raise RunError(f"no mutants match {' '.join(selectors)}")
    return _sorted(result)


def cmd_results(args) -> int:
    mutants = _load_selected(args.selectors)
    if args.status:
        wanted = set(args.status.split(","))
        shown = [m for m in mutants if m.status in wanted]
    elif args.all:
        shown = mutants
    else:
        shown = [m for m in mutants if m.status in ACTIONABLE]
    if args.json:
        print(json.dumps([asdict(m) for m in shown], indent=1))
        return 0
    _summary(mutants)
    if shown:
        print()
        _print_table(shown, with_status=True)
    if not args.all and not args.status and shown:
        print()
        print("Next: `despell show <id>` to see a mutant's diff and the tests that reach it.")
    return 0


def mutant_diff(m: MutantRecord, root: Path) -> str:
    path = root / m.file
    lines = path.read_text().splitlines(keepends=True)
    line = lines[m.line - 1]
    if line[m.col - 1 : m.end_col - 1] != m.original:
        return f"(source changed since the run; expected `{m.original}` at {_location(m)})\n"
    mutated = list(lines)
    mutated[m.line - 1] = line[: m.col - 1] + m.replacement + line[m.end_col - 1 :]
    return "".join(difflib.unified_diff(lines, mutated, fromfile=m.file, tofile=m.file, n=3))


def cmd_show(args) -> int:
    config = load_config(_root())
    mutants = _load_selected(args.selectors)
    _, tests = load_state(config)
    out = []
    for m in mutants:
        covering = [t.id for t in tests.values() if m.fid in t.functions]
        entry = asdict(m) | {"diff": mutant_diff(m, config.root), "covering_tests": covering}
        out.append(entry)
    if args.json:
        print(json.dumps(out, indent=1))
        return 0
    for i, (m, e) in enumerate(zip(mutants, out)):
        if i:
            print()
        print(f"{m.id}  [{m.status}]")
        print(f"  {_location(m)} in {m.function}: {m.description}")
        if m.killed_by:
            print(f"  killed by: {m.killed_by}")
        if m.detail:
            print(f"  detail: {m.detail}")
        tests_line = ", ".join(e["covering_tests"]) if e["covering_tests"] else "none"
        print(f"  tests reaching {m.function}: {tests_line}")
        print(e["diff"].rstrip("\n"))
    return 0


def cmd_guide(args) -> int:
    print(AGENT_GUIDE, end="")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="despell",
        description="Mutation testing for Mojo. Run `despell guide` for the workflow.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("run", help="generate mutants and test them")
    p.add_argument("selectors", nargs="*", help="only run these mutants (ids, prefixes, globs, files)")
    p.add_argument("-j", "--jobs", type=int, help="parallel workers (default: half the CPUs)")
    p.set_defaults(func=cmd_run)

    p = sub.add_parser("results", help="list mutants from the last run (default: the ones to act on)")
    p.add_argument("selectors", nargs="*")
    p.add_argument("--all", action="store_true", help="include killed/skipped mutants")
    p.add_argument("--status", help="comma separated statuses to list")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_results)

    p = sub.add_parser("show", help="show diff, location and covering tests for mutants")
    p.add_argument("selectors", nargs="+")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_show)

    p = sub.add_parser("guide", help="explain the workflow, statuses and config (start here)")
    p.set_defaults(func=cmd_guide)

    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except (RunError, ConfigError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
