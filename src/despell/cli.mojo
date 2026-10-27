"""Command line interface.

The output is designed to be read by coding agents as much as by people:
plain lines, no progress bars, stable mutant ids, and every listing ends with
the command to run next.
"""

from std.collections import Dict, Set
from std.sys import argv

from .fsutil import join, read_text, real_path
from .jsonio import Json, encode
from .project import Config, load_config
from .session import run
from .state import STATUS_ORDER, MutantRecord, TestRecord, is_actionable, load_state, note_matches, unmatched_error
from .sysutil import block_signals, environment, env_value
from .textutil import join_words, split_lines

comptime AGENT_GUIDE = """despell: mutation testing for Mojo

A mutant is a small change to your source code (e.g. `<` -> `<=`). If your
tests still pass with the change in place, the mutant "survived": either the
tests miss a behavior, or the change is equivalent and doesn't matter.

Workflow:
  1. Start `despell run` in the background, with its output going to a file.
     The first run builds everything and can take many minutes on a big
     project. It prints each survivor the moment it's found:
         survived   mylib.math.clamp.2  src/mylib/math.mojo:12:10  `<` -> `<=`
     and saves results as it goes: `despell results` shows them any time.
  2. Pick up survivors as they come, a function at a time:
     `despell show <id> [<id> ...]` gives the diff, the location and the
     tests that already run that line.
  3. Write tests that pass on the original code and fail with the mutant.
     Put them in a NEW test file, one per module under test, e.g.
     tests/test_math_mutants.mojo, importing only what it needs. A re-check
     only builds test files that are new or changed since a mutant was
     checked: a small file builds in seconds, while an edit to a big
     existing test file rebuilds all of it. Test files need top-level
     `def test_*() raises` functions and a `main` calling
     `TestSuite.discover_tests[__functions_in_module()]().run()`.
  4. Re-check: `despell run <id> [<id> ...]`, or a prefix like
     `despell run mylib.math.clamp`. It's safe to run while the long run is
     still going: it works on its own copy, and both save into the same
     results. Survivors are only run against new and changed test files.
  5. Repeat from 2. When done, the new test files can stay, or be merged
     into existing ones (that costs a rebuild of those files next time).

A plain `despell run` runs every mutant without an up-to-date result: an
interrupted run continues where it stopped, changed code is re-checked,
killed mutants stay killed while the test file that killed them is
unchanged (when it changes, it's tried first, and every other test that
reaches the mutant only if it no longer kills it, so adding tests to the
same file stays quick), and survivors are re-run against new or changed
test files only.
A change to shared test code (anything under tests_dir that isn't a test
file) re-runs everything. `despell run --force <selector>` re-runs the
selected mutants against every test that reaches them, whatever their
results (a flaky test, say). Delete mutants/ to start over.

Selectors for `run`, `results` and `show`: a mutant id (mylib.math.clamp.2),
a function or module prefix (mylib.math.clamp, mylib.math), a glob
('mylib.*.clamp.*'), a source file (src/mylib/math.mojo) or file:line.

Statuses:
  killed         a test failed with the mutant applied (good)
  survived       all tests that run this line passed: add or improve a test
  no_tests       no test runs this line: add a test
  timeout        tests hung with the mutant applied (counts as killed)
  compile_error  the mutant doesn't compile (counts as killed)
  skipped        the function can't hold mutation schemata
  equivalent     compiles to exactly the same code as the original, so no
                 test can kill it (not counted in the score)

Equivalent mutants (no input can tell them from the original, e.g. `x < lo`
-> `x <= lo` in a clamp that returns `lo` either way) can't be killed: don't
write a meaningless test for one. Silence it with `# pragma: no mutate` on
the line, or on the `def` line for a whole function.

Configuration, in despell.toml or [tool.despell] in pixi.toml/pyproject.toml:
  paths_to_mutate = ["src"]   tests_dir = "tests"   include_dirs = ["src"]
  also_copy = []  do_not_mutate = []  build_args = []  mojo = "mojo"
  timeout_multiplier = 10.0  timeout_floor = 2.0  sandbox_tests = true
Tests run in a copy of the project in mutants/ (also_copy lists extra files
they need). Results are stored in mutants/despell.json.
"""


comptime USAGE = """usage: despell <command> [options]

Mutation testing for Mojo. Run `despell guide` for the workflow.

commands:
  run [selector ...] [-j N] [--force]       generate mutants and test them (N workers; default: adapts to CPU use)
  results [selector ...] [--all] [--status s,s] [--json]
                                            list mutants from the last run (default: the ones to act on)
  show <selector> ... [--all] [--json]      show diff, location and covering tests (of the ones to act on)
  guide                                     explain the workflow, statuses and config (start here)
"""


def _pad(s: String, width: Int) -> String:
    var out = s
    while out.byte_length() < width:
        out += " "
    return out^


def _by_location(a: MutantRecord, b: MutantRecord) -> Bool:
    if a.file != b.file:
        return a.file < b.file
    if a.line != b.line:
        return a.line < b.line
    if a.col != b.col:
        return a.col < b.col
    return a.number < b.number


def _sorted(mutants: List[MutantRecord]) -> List[MutantRecord]:
    var out = mutants.copy()
    sort(Span(out), _by_location)
    return out^


def _print_table(mutants: List[MutantRecord], with_status: Bool):
    if len(mutants) == 0:
        return
    var id_w = 0
    var loc_w = 0
    for m in mutants:
        id_w = max(id_w, m.id.byte_length())
        loc_w = max(loc_w, m.location().byte_length())
    for m in mutants:
        var status = _pad(m.status, 14) if with_status else String("")
        print("  " + status + _pad(m.id, id_w) + "  " + _pad(m.location(), loc_w) + "  " + m.description)


def _summary(mutants: List[MutantRecord]):
    var counts = Dict[String, Int]()
    for m in mutants:
        counts[m.status] = counts.get(m.status, 0) + 1
    var parts = List[String]()
    for status in String(STATUS_ORDER).split(" "):
        var n = counts.get(String(status), 0)
        if n:
            parts.append(String(n) + " " + String(status))
    var total = len(mutants)
    var killed = counts.get("killed", 0) + counts.get("timeout", 0) + counts.get("compile_error", 0)
    var tested = total - counts.get("skipped", 0) - counts.get("not_checked", 0) - counts.get("equivalent", 0)
    var score = String("")
    if tested:
        var permille = Int(1000.0 * Float64(killed) / Float64(tested) + 0.5)
        score = ", score " + String(permille // 10) + "." + String(permille % 10) + "%"
    print(String(total) + " mutants: " + (join_words(parts, ", ") if len(parts) else String("none")) + score)


# Beyond this many mutants to act on, list them per function instead
comptime LIST_LIMIT = 50
comptime FUNCTIONS_SHOWN = 40


def _function_of(m: MutantRecord) -> String:
    """The mutant's function, as a selector (its id without the number)."""
    return String(m.id[byte = 0 : m.id.rfind(".")])


def _print_by_function(mutants: List[MutantRecord]):
    """One line per function, the ones with the most to act on first."""
    var names = List[String]()
    var counts = Dict[String, Int]()  # "<function> <status>" and "<function>"
    var first = Dict[String, String]()  # function -> location
    for m in _sorted(mutants):
        var f = _function_of(m)
        if not (f in first):
            names.append(f)
            first[f] = m.location()
        counts[f] = counts.get(f, 0) + 1
        counts[f + " " + m.status] = counts.get(f + " " + m.status, 0) + 1
    var order = List[Int]()
    for i in range(len(names)):
        order.append(i)
    # by count, then by location (insertion sort keeps that order)
    for a in range(1, len(order)):
        var b = a
        while b > 0 and counts.get(names[order[b - 1]], 0) < counts.get(names[order[b]], 0):
            var t = order[b - 1]
            order[b - 1] = order[b]
            order[b] = t
            b -= 1
    var shown = min(FUNCTIONS_SHOWN, len(order))
    var tallies = List[String]()
    var tally_w = 0
    var name_w = 0
    for k in range(shown):
        var f = names[order[k]]
        var parts = List[String]()
        for status in String(STATUS_ORDER).split(" "):
            var n = counts.get(f + " " + String(status), 0)
            if n:
                parts.append(String(n) + " " + String(status))
        tallies.append(join_words(parts, ", "))
        tally_w = max(tally_w, tallies[k].byte_length())
        name_w = max(name_w, f.byte_length())
    for k in range(shown):
        var f = names[order[k]]
        print("  " + _pad(tallies[k], tally_w) + "  " + _pad(f, name_w) + "  " + first.get(f, ""))
    if len(order) > shown:
        print("  ... and " + String(len(order) - shown) + " more functions (`despell results --all` lists every mutant)")


def _print_actionable(mutants: List[MutantRecord], every: Bool):
    """The mutants to act on: each, or for a long list without a selector,
    per function."""
    if every or len(mutants) <= LIST_LIMIT:
        _print_table(_sorted(mutants), True)
        print()
        print("Next: `despell show <id or function>` to see the diffs and the tests that reach them.")
        return
    print(String(len(mutants)) + " to act on, in these functions (most first):")
    _print_by_function(mutants)
    print()
    print("Next: `despell show <function>` to see a function's mutants and the tests that reach them.")


def _report(mutants: List[MutantRecord], selected: Bool):
    _summary(mutants)
    var todo = List[MutantRecord]()
    for m in mutants:
        if is_actionable(m.status):
            todo.append(m.copy())
    if len(todo):
        print()
        _print_actionable(todo, selected)


def _root() raises -> String:
    return real_path(".")


def _default_workers() -> Int:
    from std.sys.info import num_physical_cores

    return max(1, num_physical_cores() // 2)


def cmd_run(args: List[String]) raises -> Int:
    var selectors = List[String]()
    var workers = 0
    var force = False
    var i = 0
    while i < len(args):
        if args[i] == "--force":
            force = True
            i += 1
            continue
        if args[i] == "-j" or args[i] == "--jobs":
            if i + 1 >= len(args):
                raise Error("-j needs a number")
            workers = Int(atol(args[i + 1]))
            i += 2
            continue
        if args[i].startswith("-j") and args[i].byte_length() > 2:
            workers = Int(atol(String(args[i][byte=2:])))
            i += 1
            continue
        if args[i].startswith("-"):
            raise Error("unknown option for run: " + args[i])
        selectors.append(args[i])
        i += 1
    var config = load_config(_root())
    # without -j, the number of workers adapts to the CPU the tests use
    var mutants = run(config, selectors, workers if workers > 0 else _default_workers(), force, workers == 0)
    print()
    _report(mutants, len(selectors) > 0)
    return 0


def _load_selected(config: Config, selectors: List[String]) raises -> List[MutantRecord]:
    var state = load_state(config)
    if len(state.mutants) == 0:
        raise Error("no results yet; run `despell run` first")
    var result = List[MutantRecord]()
    var matched = List[Bool](length=len(selectors), fill=False)
    for item in state.mutants.items():
        if len(selectors) == 0 or note_matches(item.value, selectors, matched):
            result.append(item.value.copy())
    var unmatched = unmatched_error(selectors, matched)
    if unmatched:
        raise Error(unmatched)
    return _sorted(result)


def cmd_results(args: List[String]) raises -> Int:
    var selectors = List[String]()
    var show_all = False
    var as_json = False
    var wanted = Set[String]()
    var i = 0
    while i < len(args):
        if args[i] == "--all":
            show_all = True
        elif args[i] == "--json":
            as_json = True
        elif args[i] == "--status" and i + 1 < len(args):
            for s in args[i + 1].split(","):
                wanted.add(String(s))
            i += 1
        elif args[i].startswith("--status="):
            for s in String(args[i][byte=9:]).split(","):
                wanted.add(String(s))
        elif args[i].startswith("-"):
            raise Error("unknown option for results: " + args[i])
        else:
            selectors.append(args[i])
        i += 1
    var config = load_config(_root())
    var mutants = _load_selected(config, selectors)
    var shown = List[MutantRecord]()
    for m in mutants:
        if len(wanted) > 0:
            if m.status in wanted:
                shown.append(m.copy())
        elif show_all or is_actionable(m.status):
            shown.append(m.copy())
    if as_json:
        var arr = Json.array()
        for m in shown:
            arr.append(m.to_json())
        print(encode(arr, indent=1))
        return 0
    _summary(mutants)
    if len(shown) == 0:
        return 0
    print()
    if show_all or len(wanted) > 0:
        _print_table(_sorted(shown), True)
    else:
        _print_actionable(shown, len(selectors) > 0)
    return 0


def mutant_diff(m: MutantRecord, root: String) raises -> String:
    """A unified diff of the mutant against the source, with 3 lines of context."""
    var lines = split_lines(read_text(join(root, m.file)), keepends=True)
    var i = m.line - 1
    if i >= len(lines):
        return "(source changed since the run; expected `" + m.original + "` at " + m.location() + ")\n"
    var line = String(lines[i])
    var bytes = line.byte_length()
    if m.end_col - 1 > bytes or String(line[byte = m.col - 1 : m.end_col - 1]) != m.original:
        return "(source changed since the run; expected `" + m.original + "` at " + m.location() + ")\n"
    var mutated = String(line[byte = 0 : m.col - 1]) + m.replacement + String(line[byte = m.end_col - 1 :])
    var first = max(0, i - 3)
    var last = min(len(lines) - 1, i + 3)
    var n = last - first + 1
    var out = "--- " + m.file + "\n+++ " + m.file + "\n"
    out += "@@ -" + String(first + 1) + "," + String(n) + " +" + String(first + 1) + "," + String(n) + " @@\n"
    for k in range(first, last + 1):
        var text = String(lines[k])
        if not text.endswith("\n"):
            text += "\n"
        if k == i:
            out += "-" + text
            out += "+" + mutated + ("" if mutated.endswith("\n") else "\n")
        else:
            out += " " + text
    return out^


def _tests_text(tests: List[String]) -> String:
    """The tests, or for many, how many per test file."""
    if len(tests) == 0:
        return "none"
    if len(tests) <= 5:
        return join_words(tests, ", ")
    var files = List[String]()
    var per = Dict[String, Int]()
    for t in tests:
        var file = String(t[byte = 0 : t.find("::")]) if "::" in t else t
        if not (file in per):
            files.append(file)
        per[file] = per.get(file, 0) + 1
    var parts = List[String]()
    for f in files:
        parts.append(f + " (" + String(per.get(f, 0)) + ")")
    return String(len(tests)) + " tests in " + join_words(parts, ", ")


def cmd_show(args: List[String]) raises -> Int:
    var selectors = List[String]()
    var as_json = False
    var show_all = False
    for a in args:
        if a == "--json":
            as_json = True
        elif a == "--all":
            show_all = True
        elif a.startswith("-"):
            raise Error("unknown option for show: " + a)
        else:
            selectors.append(a)
    if len(selectors) == 0:
        raise Error("show needs at least one selector")
    var config = load_config(_root())
    var exact = Set[String]()
    for s in selectors:
        exact.add(s)
    var hidden = Dict[String, Int]()
    var mutants = List[MutantRecord]()
    for m in _sorted(_load_selected(config, selectors)):
        # for a function or module, only what's left to act on
        if as_json or show_all or is_actionable(m.status) or m.id in exact:
            mutants.append(m.copy())
        else:
            hidden[m.status] = hidden.get(m.status, 0) + 1
    var state = load_state(config)
    var out = Json.array()
    var measured_here = List[Bool]()
    for m in mutants:
        var covering = state.tests_reaching(m)
        var entry = m.to_json()
        entry.set("diff", Json.of(mutant_diff(m, config.root)))
        entry.set("covering_tests", Json.strings(covering[0]))
        out.append(entry^)
        measured_here.append(covering[1])
    if as_json:
        print(encode(out, indent=1))
        return 0
    var said = Dict[String, String]()  # tests text -> where it was printed
    for k in range(len(mutants)):
        ref m = mutants[k]
        if k:
            print()
        print(m.id + "  [" + m.status + "]")
        print("  " + m.location() + " in " + m.function + ": " + m.description)
        if m.killed_by.byte_length():
            print("  killed by: " + m.killed_by)
        if m.detail.byte_length():
            print("  detail: " + m.detail)
        var covering = out.items[k].str_list("covering_tests")
        var tests_line = _tests_text(covering)
        var reaching = m.function if m.site < 0 or not measured_here[k] else "line " + String(m.line)
        if not measured_here[k]:
            # the code changed since some of the coverage was measured
            reaching += " (when last measured)"
        # a function's mutants are mostly reached by the same tests
        var seen = said.get(tests_line, "")
        if seen.byte_length() and len(covering) > 0:
            print("  tests reaching " + reaching + ": the same as " + seen)
        else:
            print("  tests reaching " + reaching + ": " + tests_line)
            said[tests_line] = reaching
        print(String(out.items[k].str_or("diff", "").rstrip("\n")))
    if len(hidden) > 0:
        var parts = List[String]()
        for item in hidden.items():
            parts.append(String(item.value) + " " + item.key)
        if len(mutants):
            print()
        print("(not shown: " + join_words(parts, ", ") + "; `despell show --all` shows them)")
    return 0


def main_cli() -> Int:
    var args = List[String]()
    var all_args = argv()
    for i in range(1, len(all_args)):
        args.append(String(all_args[i]))
    if len(args) == 0 or args[0] == "-h" or args[0] == "--help":
        print(USAGE, end="")
        return 0 if len(args) else 2
    var command = args.pop(0)
    # Ctrl-C is noticed while waiting for children, which then get cleaned up
    block_signals()
    try:
        if command == "run":
            return cmd_run(args)
        if command == "results":
            return cmd_results(args)
        if command == "show":
            return cmd_show(args)
        if command == "guide":
            print(AGENT_GUIDE, end="")
            return 0
        print("error: unknown command " + command + "\n\n" + String(USAGE), end="")
        return 2
    except e:
        var msg = String(e)
        if msg == "interrupted":
            return 130
        print("error: " + msg)
        return 2
