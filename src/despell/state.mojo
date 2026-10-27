"""Mutant and test records, and the state file they live in.

Results are in `mutants/despell.json`. Each one remembers the snapshot of the
tests it was obtained with (a hash per test file), which is what lets later
runs re-run only what a change could affect.
"""

from std.collections import Dict, Set

from .fsutil import (
    Hasher, hash_bytes, is_file, join, mkdirs, read_bytes, read_text, rename_file, walk_files, write_text,
)
from .jsonio import Json, encode, parse
from .project import Config
from .sysutil import getpid, lock_file, unlock_file
from .textutil import glob_match

comptime STATE_FILE = "despell.json"
comptime STATE_LOCK = "despell.lock"
comptime MAIN_LOCK = "main.lock"  # held by the run working in mutants/ itself
comptime SIDE_DIR = ".side"  # runs alongside it work in mutants/.side/<pid>

comptime KILLED = "killed"
comptime SURVIVED = "survived"
comptime NO_TESTS = "no_tests"
comptime TIMEOUT = "timeout"
comptime COMPILE_ERROR = "compile_error"
comptime SKIPPED = "skipped"
comptime NOT_CHECKED = "not_checked"

comptime STATUS_ORDER = "survived no_tests timeout not_checked skipped compile_error killed"

# version control, environments and caches: big, and no test reads them
comptime NOT_COPIED = (
    "mutants .git .hg .jj .svn .pixi .venv .magic __pycache__ .pytest_cache .mypy_cache .ruff_cache .DS_Store"
)


def not_copied() -> List[String]:
    var out = List[String]()
    for name in String(NOT_COPIED).split(" "):
        out.append(String(name))
    return out^


def is_actionable(status: String) -> Bool:
    """Statuses an agent should act on."""
    return status == SURVIVED or status == NO_TESTS


def is_final(status: String) -> Bool:
    """Results that only change when the code or the tests do."""
    return status == KILLED or status == SURVIVED or status == TIMEOUT or status == NO_TESTS


struct MutantRecord(Copyable, Movable):
    var id: String
    var number: Int
    var fid: Int
    var file: String  # path relative to project root
    var line: Int  # 1-based
    var col: Int  # 1-based
    var end_col: Int  # 1-based, exclusive
    var function: String
    var description: String
    var original: String
    var replacement: String
    var fingerprint: String
    var status: String
    var killed_by: String  # "": none
    var detail: String  # "": none
    # the statement holding the mutant, for coverage (-1: use the function's)
    var site: Int
    # the snapshot of the tests this result was obtained with ("": none)
    var tested_with: String
    # passed the pre-check in a build (so a resumed run can skip it)
    var compiles: Bool

    def __init__(
        out self, id: String, number: Int, fid: Int, file: String, line: Int, col: Int, end_col: Int,
        function: String, description: String, original: String, replacement: String, fingerprint: String,
        site: Int = -1,
    ):
        self.id = id
        self.number = number
        self.fid = fid
        self.file = file
        self.line = line
        self.col = col
        self.end_col = end_col
        self.function = function
        self.description = description
        self.original = original
        self.replacement = replacement
        self.fingerprint = fingerprint
        self.status = NOT_CHECKED
        self.killed_by = String("")
        self.detail = String("")
        self.site = site
        self.tested_with = String("")
        self.compiles = False

    def to_json(self) -> Json:
        var j = Json.object()
        j.set("id", Json.of(self.id))
        j.set("number", Json.of(self.number))
        j.set("fid", Json.of(self.fid))
        j.set("file", Json.of(self.file))
        j.set("line", Json.of(self.line))
        j.set("col", Json.of(self.col))
        j.set("end_col", Json.of(self.end_col))
        j.set("function", Json.of(self.function))
        j.set("description", Json.of(self.description))
        j.set("original", Json.of(self.original))
        j.set("replacement", Json.of(self.replacement))
        j.set("fingerprint", Json.of(self.fingerprint))
        j.set("status", Json.of(self.status))
        j.set("killed_by", _opt(self.killed_by))
        j.set("detail", _opt(self.detail))
        j.set("site", Json.of(self.site) if self.site >= 0 else Json())
        j.set("tested_with", _opt(self.tested_with))
        if self.compiles:
            j.set("compiles", Json.of(True))
        return j^

    @staticmethod
    def from_json(j: Json) -> MutantRecord:
        var m = MutantRecord(
            j.str_or("id", ""), j.int_or("number", 0), j.int_or("fid", 0), j.str_or("file", ""),
            j.int_or("line", 0), j.int_or("col", 0), j.int_or("end_col", 0), j.str_or("function", ""),
            j.str_or("description", ""), j.str_or("original", ""), j.str_or("replacement", ""),
            j.str_or("fingerprint", ""), j.int_or("site", -1),
        )
        m.status = j.str_or("status", NOT_CHECKED)
        m.killed_by = j.str_or("killed_by", "")
        m.detail = j.str_or("detail", "")
        m.tested_with = j.str_or("tested_with", "")
        m.compiles = j.has("compiles") and j.get("compiles").as_bool()
        return m^

    def location(self) -> String:
        return self.file + ":" + String(self.line) + ":" + String(self.col)


def _opt(s: String) -> Json:
    return Json.of(s) if s.byte_length() else Json()


struct TestRecord(Copyable, Movable):
    var id: String  # "<test file>::<test name>"
    var file: String
    var name: String  # "" when the test file isn't a TestSuite
    var binary: String
    var duration: Float64
    var functions: List[Int]
    var sites: List[Int]
    # the snapshot of the sources and tests this coverage was measured with
    var snapshot: String
    # measured with coverage hooks on every statement; else (older despell
    # versions) only the statements of the mutants in that build
    var complete: Bool
    var memory: Int  # peak bytes, unmutated (0: not known)

    def __init__(out self, id: String, file: String, name: String):
        self.id = id
        self.file = file
        self.name = name
        self.binary = String("")
        self.duration = 0
        self.functions = List[Int]()
        self.sites = List[Int]()
        self.snapshot = String("")
        self.complete = False
        self.memory = 0

    def to_json(self) -> Json:
        var j = Json.object()
        j.set("id", Json.of(self.id))
        j.set("file", Json.of(self.file))
        j.set("name", _opt(self.name))
        j.set("binary", Json.of(self.binary))
        j.set("duration", Json.of(self.duration))
        j.set("functions", Json.ints(self.functions))
        j.set("sites", Json.ints(self.sites))
        j.set("snapshot", _opt(self.snapshot))
        j.set("complete", Json.of(self.complete))
        j.set("memory", Json.of(self.memory))
        return j^

    @staticmethod
    def from_json(j: Json) -> TestRecord:
        var t = TestRecord(j.str_or("id", ""), j.str_or("file", ""), j.str_or("name", ""))
        t.binary = j.str_or("binary", "")
        t.duration = j.float_or("duration", 0)
        t.memory = j.int_or("memory", 0)
        t.functions = j.int_list("functions")
        t.sites = j.int_list("sites")
        t.snapshot = j.str_or("snapshot", "")
        t.complete = j.has("complete") and j.get("complete").as_bool()
        return t^

    def covers(self, m: MutantRecord) -> Bool:
        return (m.site in self.sites) if m.site >= 0 else (m.fid in self.functions)


struct State(Movable):
    var mutants: Dict[String, MutantRecord]
    var tests: Dict[String, TestRecord]
    # snapshot id -> hash per test file, "*" for the rest of the tests
    # directory and "sources" for the code under test
    var snapshots: Dict[String, Dict[String, String]]

    def __init__(out self):
        self.mutants = Dict[String, MutantRecord]()
        self.tests = Dict[String, TestRecord]()
        self.snapshots = Dict[String, Dict[String, String]]()


def state_path(config: Config) -> String:
    return join(config.mutants_dir(), STATE_FILE)


struct StateLock:
    """Runs side by side share the state file: read, merge and write under
    this. Released by `release` (or when it goes away)."""

    var fd: Int

    def __init__(out self, config: Config) raises:
        mkdirs(config.mutants_dir())
        self.fd = lock_file(join(config.mutants_dir(), STATE_LOCK), True)

    def release(mut self):
        unlock_file(self.fd)
        self.fd = -1

    def __del__(deinit self):
        unlock_file(self.fd)


def read_state(config: Config) raises -> State:
    var state = State()
    var path = state_path(config)
    if not is_file(path):
        return state^
    var data = parse(read_text(path))
    var mutants = data.get("mutants")
    for i in range(len(mutants)):
        var m = MutantRecord.from_json(mutants.items[i])
        state.mutants[m.id] = m^
    var tests = data.get("tests")
    for i in range(len(tests)):
        var t = TestRecord.from_json(tests.items[i])
        state.tests[t.id] = t^
    var snapshots = data.get("snapshots")
    for i in range(len(snapshots.keys)):
        var snap = Dict[String, String]()
        ref s = snapshots.items[i]
        for k in range(len(s.keys)):
            snap[s.keys[k]] = s.items[k].as_string()
        state.snapshots[snapshots.keys[i]] = snap^
    return state^


def by_number(a: MutantRecord, b: MutantRecord) -> Bool:
    return a.number < b.number


def write_state(config: Config, state: State) raises:
    var used = Set[String]()
    var mutants = List[MutantRecord]()
    for item in state.mutants.items():
        mutants.append(item.value.copy())
        used.add(item.value.tested_with)
    sort(Span(mutants), by_number)
    var data = Json.object()
    data.set("version", Json.of(2))
    var ms = Json.array()
    for m in mutants:
        ms.append(m.to_json())
    data.set("mutants", ms^)
    var ts = Json.array()
    for item in state.tests.items():
        ts.append(item.value.to_json())
        used.add(item.value.snapshot)
    data.set("tests", ts^)
    var snaps = Json.object()
    for item in state.snapshots.items():
        if item.key in used:
            var s = Json.object()
            for kv in item.value.items():
                s.set(kv.key, Json.of(kv.value))
            snaps.set(item.key, s^)
    data.set("snapshots", snaps^)
    var path = state_path(config)
    var tmp = path + "." + String(getpid()) + ".tmp"
    write_text(tmp, encode(data, indent=1))
    rename_file(tmp, path)


def load_state(config: Config) raises -> State:
    var lock = StateLock(config)
    var state = read_state(config)
    lock.release()
    return state^


# ---- what to run --------------------------------------------------------------


def test_file_hashes(config: Config, test_files: Set[String]) raises -> Dict[String, String]:
    """A hash per test file, and one ("*") for the rest of the tests
    directory (shared helpers, fixtures), which every test file may use."""
    var tests_root = join(config.root, config.tests_dir)
    var rest = Hasher()
    var hashes = Dict[String, String]()
    for rel_in_tests in walk_files(tests_root, not_copied()):
        var rel = join(config.tests_dir, rel_in_tests)
        var data = read_bytes(join(config.root, rel))
        if rel in test_files:
            hashes[rel] = hash_bytes(data)
        else:
            rest.update(rel)
            rest.update(Span(data))
    hashes["*"] = rest.hex()
    return hashes^


def snapshot_id(snapshot: Dict[String, String]) -> String:
    var keys = List[String]()
    for k in snapshot.keys():
        keys.append(k)
    sort(keys)
    var h = Hasher()
    for k in keys:
        h.update(k)
        h.update(snapshot.get(k, ""))
    return String(h.hex()[byte=0:12])


@fieldwise_init
struct Plan(Copyable, Movable):
    """Whether a mutant needs running, and against which test files (with
    `all_files`, every one that reaches it)."""

    var run: Bool
    var all_files: Bool
    var files: Set[String]


def plan(m: MutantRecord, old: Optional[MutantRecord], snapshots: Dict[String, Dict[String, String]], current: Dict[String, String]) -> Plan:
    """A killed mutant stays killed while the test file that killed it is the
    same. A survivor can only be killed by a test file that's new or changed
    since it was checked, so it's run against those alone."""
    var everything = Plan(True, True, Set[String]())
    if not old:
        return everything^
    ref o = old.value()
    if o.fingerprint != m.fingerprint:
        return everything^
    if o.status == COMPILE_ERROR or o.status == SKIPPED:
        return Plan(False, True, Set[String]())  # the build carries these over
    if not is_final(o.status):
        return everything^
    if not (o.tested_with in snapshots):
        return everything^
    var snap = snapshots.get(o.tested_with, Dict[String, String]())
    if snap.get("*", "") != current.get("*", ""):
        return everything^
    var changed = Set[String]()
    for item in current.items():
        if item.key != "*" and item.key != "sources" and snap.get(item.key, "") != item.value:
            changed.add(item.key)
    if o.status == KILLED or o.status == TIMEOUT:
        var sep = o.killed_by.find("::")
        var killer = String(o.killed_by[byte=0:sep]) if sep >= 0 else o.killed_by
        if killer in changed or not (killer in current):
            return everything^
        return Plan(False, True, Set[String]())
    if len(changed) > 0:
        return Plan(True, False, changed^)
    return Plan(False, True, Set[String]())


def merge_result(ours: MutantRecord, theirs: Optional[MutantRecord], seen: Optional[MutantRecord], ran_it: Bool) -> MutantRecord:
    """The record to save for a mutant: this run's, or the one in the state
    file (`theirs`), which another run may have written since this one read
    it (`seen`)."""
    if not theirs or theirs.value().fingerprint != ours.fingerprint:
        return ours.copy()  # new, or the code changed
    ref t = theirs.value()
    if not ran_it:
        var kept = t.copy()
        kept.compiles = t.compiles or ours.compiles
        return kept^
    var written_since = not seen or t.status != seen.value().status or t.tested_with != seen.value().tested_with
    if written_since and (t.status == KILLED or t.status == TIMEOUT) and (ours.status == SURVIVED or ours.status == NO_TESTS):
        # another run killed it meanwhile, with other tests: a kill stands
        # while the test file that did it is unchanged, which the next run
        # checks
        return t.copy()
    return ours.copy()


def matches(m: MutantRecord, selectors: List[String]) -> Bool:
    for s in selectors:
        if glob_match(s, m.id) or m.id.startswith(s + "."):
            return True
        var colon = s.rfind(":")
        if colon >= 0:
            # file:line
            try:
                var line = atol(String(s[byte = colon + 1 :]))
                if m.file == String(s[byte=0:colon]) and m.line == line:
                    return True
            except:
                pass
        elif m.file == s:
            return True
    return False
