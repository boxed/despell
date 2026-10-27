"""A `despell run`: what to run, the coverage and mutant phases, and saving."""

from std.collections import Dict, Set
from std.os import getenv

from .equivalence import EQ_VERSION
from .fsutil import join, mkdirs, rmtree, write_text, hash_text
from .project import Config
from .runner import WORK_DIR, Command, Run, discover_tests, log, run_parallel
from .state import (
    COMPILE_ERROR, EQUIVALENT, KILLED, MAIN_LOCK, NO_TESTS, NOT_CHECKED, SIDE_DIR, SKIPPED, SURVIVED, TIMEOUT, MutantRecord, Plan, State,
    StateLock, TestRecord, is_actionable, merge_result, note_matches, plan, read_state, snapshot_id, test_file_hashes,
    unmatched_error, write_state,
)
from .sysutil import (
    CpuTicks, Finished, children_cpu_seconds, cpu_ticks, getpid, kill_strays, lock_file, memory_available, monotonic_ns, seconds_since,
    unlock_file, with_env,
)
from .textutil import first_failed_test, format_seconds, numbers_after, split_lines

comptime STATS_MODE = "-1"
# the snapshot entry naming each function number (see `_function_names`)
comptime FUNCTIONS = "functions"
# Building with this many mutants or more, test files without up-to-date
# coverage are first built without mutants to measure it: then each binary
# only gets the mutants its tests reach. DESPELL_COVERAGE_FIRST overrides it.
comptime COVERAGE_FIRST = 1000
# The share of the machine's memory under which fewer mutants run at once
comptime LOW_MEMORY = 0.2


# ---- phase 3: coverage ---------------------------------------------------------


def _test_argv(r: Run, file: String, names: List[String]) -> List[String]:
    var argv = r.test_prefix.copy()
    argv.append(r.binary_for(file))
    if len(names) > 0:
        argv.append("--only")
        for n in names:
            argv.append(n)
    return argv^


def _test_output(r: Run, output: String) -> String:
    """A failing test's output for the user: without the coverage lines
    despell's hooks print, the tests `--only` skipped and Mojo's boilerplate,
    and with paths into despell's copies of the project made relative to it."""
    var out = String("")
    for line in split_lines(output):
        var l = String(line)
        var stripped = String(l.strip())
        if (
            l.startswith("despell-hit ") or l.startswith("despell-site ") or stripped.startswith("SKIP [")
            or stripped.startswith("stack trace was not collected") or stripped == "Unhandled exception caught during execution:"
            or stripped.startswith("Test suite'")
        ):
            continue
        out += _relative_paths(l, r.mdir) + "\n"
    return String(out.strip())


def _relative_paths(line: String, mdir: String) -> String:
    """`line` with `<mdir>/` and `<mdir>/.despell/trees/<n>/` taken out."""
    var out = line
    var trees = mdir + "/.despell/trees/"
    while trees in out:
        var at = out.find(trees)
        var after = out.find("/", at + trees.byte_length())
        if after < 0:
            break
        out = String(out[byte=0:at]) + String(out[byte = after + 1 :])
    return out.replace(mdir + "/", "")


def _pass_unsandboxed(r: Run, commands: List[Command], failing: List[Int]) raises -> Bool:
    """Whether the `failing` commands pass without the sandbox."""
    var again = List[Command]()
    for k in failing:
        ref c = commands[k]
        again.append(Command(List[String](c.argv[len(r.test_prefix) :]), c.cwd, c.env.copy(), c.timeout))
    for res in run_parallel(again, r.workers):
        if res.code != 0:
            return False
    return True


def collect_stats(mut r: Run, only_files: Set[String] = Set[String]()) raises:
    """Run each test (of `only_files`, default all) on its own, unmutated,
    recording which functions and statements it reaches (and checking the
    suite is green)."""
    var env = with_env(r.mojo.env, ["DESPELL_MUTANT=" + String(STATS_MODE)])
    var commands = List[Command]()
    var indices = List[Int]()
    for i in range(len(r.tests)):
        ref t = r.tests[i]
        if len(only_files) > 0 and not (t.file in only_files):
            continue
        indices.append(i)
        var names = List[String]()
        if t.name.byte_length():
            names.append(t.name)
        commands.append(Command(_test_argv(r, t.file, names), r.mdir, env.copy(), 0))
    var t0 = monotonic_ns()
    var results = run_parallel(commands, r.workers)
    var failing = List[Int]()  # into results
    var reached = False
    for k in range(len(indices)):
        ref t = r.tests[indices[k]]
        t.binary = String(r.binary_for(t.file)[byte = r.mdir.byte_length() + 1 :])
        t.duration = results[k].seconds
        t.memory = results[k].memory
        t.functions = numbers_after(results[k].output, "despell-hit ")
        t.sites = numbers_after(results[k].output, "despell-site ")
        t.complete = True
        if len(t.functions) > 0:
            reached = True
        if results[k].code != 0:
            failing.append(k)
    if len(failing) > 0:
        var msg = String(len(failing)) + " tests fail without any mutation applied:\n"
        for k in range(min(5, len(failing))):
            msg += "\n--- " + r.tests[indices[failing[k]]].id + "\n" + _test_output(r, results[failing[k]].output) + "\n"
        if len(r.test_prefix) > 0 and _pass_unsandboxed(r, commands, failing):
            msg += (
                "\nThey pass outside the sandbox despell runs tests in, which keeps them from signaling processes "
                + "they didn't start (a mutant can turn stopping a child into `kill(-1, SIGTERM)`, which takes down "
                + "every program you have open). Tests that check whether another process is alive with "
                + "`kill(pid, 0)` get EPERM for it there: only ESRCH means it's gone. Fix the tests, or turn the "
                + "sandbox off with `sandbox_tests = false` in the config."
            )
        raise Error(msg)
    log("ran " + String(len(indices)) + " tests on unmutated code (" + format_seconds(seconds_since(t0)) + "s)")
    if len(r.mutants) > 0 and not reached:
        log("warning: no test reached any mutated function; check include_dirs")


# ---- phase 4: mutants ----------------------------------------------------------


@fieldwise_init
struct _Batch(Copyable, Movable):
    var file: String
    var names: List[String]
    var budget: Float64
    var memory: Int  # the most its tests use unmutated (0: not known)


@fieldwise_init
struct _Job(Copyable, Movable):
    var number: Int
    var batches: List[_Batch]
    var next: Int
    var start_ns: Int
    var processes: Int
    var tests: Int


def _by_duration(a: TestRecord, b: TestRecord) -> Bool:
    return a.duration < b.duration


def _batches(r: Run, indices: List[Int]) -> List[_Batch]:
    """One failing test is enough, but a TestSuite runs all the tests it's
    given. Most mutants that get killed fail the first test they meet, so the
    fastest test runs on its own, then the rest in batches that double in
    size: a killed mutant stops early, and a survivor only pays for a few
    more process starts (milliseconds each)."""
    var sorted_tests = List[TestRecord]()
    for i in indices:
        ref t = r.tests[i]
        # without the coverage lists, which can be long
        var copy = TestRecord(t.id, t.file, t.name)
        copy.duration = t.duration
        copy.memory = t.memory
        sorted_tests.append(copy^)
    sort(Span(sorted_tests), _by_duration)
    var batches = List[_Batch]()
    ref first = sorted_tests[0]
    var first_names = List[String]()
    if first.name.byte_length():
        first_names.append(first.name)
    batches.append(_Batch(first.file, first_names^, first.duration, first.memory))
    # the rest per binary, the cheapest binary first
    var files = List[String]()
    var totals = List[Float64]()
    for i in range(1, len(sorted_tests)):
        ref t = sorted_tests[i]
        var k = -1
        for j in range(len(files)):
            if files[j] == t.file:
                k = j
        if k < 0:
            files.append(t.file)
            totals.append(0)
            k = len(files) - 1
        totals[k] += t.duration
    var order = List[Int]()
    for j in range(len(files)):
        order.append(j)
    for a in range(len(order)):
        for b in range(a + 1, len(order)):
            if totals[order[b]] < totals[order[a]]:
                var tmp = order[a]
                order[a] = order[b]
                order[b] = tmp
    for j in order:
        var size = 2
        var count = 0
        var names = List[String]()
        var budget: Float64 = 0
        var memory = 0
        for i in range(1, len(sorted_tests)):
            ref t = sorted_tests[i]
            if t.file != files[j]:
                continue
            if t.name.byte_length():
                names.append(t.name)
            budget += t.duration
            memory = max(memory, t.memory)
            count += 1
            if count == size:
                batches.append(_Batch(files[j], names^, budget, memory))
                names = List[String]()
                budget = 0
                memory = 0
                count = 0
                size *= 2
        if count > 0:
            batches.append(_Batch(files[j], names^, budget, memory))
    return batches^


def _tests_for(r: Run, m: MutantRecord, by_fid: Dict[Int, List[Int]], by_site: Dict[Int, List[Int]]) -> List[Int]:
    """The tests (indices into `r.tests`) that run the mutant's statement
    (only they can kill it), within the test files it's allowed."""
    var indices = by_site.get(m.site, List[Int]()) if m.site >= 0 else by_fid.get(m.fid, List[Int]())
    var restricted = m.number in r.allowed
    var allowed = r.allowed.get(m.number, Set[String]())
    var tests = List[Int]()
    for i in indices:
        # coverage can vary between runs (timing): only binaries holding the
        # mutant can test it
        if (not restricted or r.tests[i].file in allowed) and r.holds(r.tests[i].file, m.number):
            tests.append(i)
    return tests^


def _slow_tests(r: Run, todo: List[Int], by_fid: Dict[Int, List[Int]], by_site: Dict[Int, List[Int]]):
    """Point out tests that take a large share of the mutant run: every
    survivor runs every test that reaches it, so one slow test reaching much
    of the code can dominate it, and making it faster pays off in every run."""
    var reached = List[Int](length=len(r.tests), fill=0)
    for n in todo:
        for i in _tests_for(r, r.mutants[n - 1], by_fid, by_site):
            reached[i] += 1
    var total: Float64 = 0
    for i in range(len(r.tests)):
        total += r.tests[i].duration * Float64(reached[i])
    if total < 600:  # worker-seconds: a short run either way
        return
    for _ in range(3):
        var best = -1
        var best_cost: Float64 = 0
        for i in range(len(r.tests)):
            var cost = r.tests[i].duration * Float64(reached[i])
            if cost > best_cost:
                best = i
                best_cost = cost
        if best < 0 or best_cost < total * 0.1:
            return
        ref t = r.tests[best]
        log(
            "slow test: " + t.id + " takes " + format_seconds(t.duration) + "s and reaches " + String(reached[best])
            + " of these mutants, up to " + String(Int(100 * best_cost / total + 0.5))
            + "% of the time running them takes; making it faster speeds up every run"
        )
        reached[best] = 0


struct _Scaler(Movable):
    """Without `-j`, the number of workers follows how much CPU the tests
    use: tests that mostly wait (on I/O, the network, their own timeouts)
    leave cores idle that more workers can use, as long as there's memory to
    spare. Not fewer than to start with, unless memory runs low."""

    var on: Bool
    var cores: Int
    var low: Int
    var high: Int
    var t_ns: Int
    var cpu: Float64
    var busy: Float64  # cores the tests keep busy, smoothed
    var ticks: CpuTicks

    def __init__(out self, on: Bool, workers: Int):
        from std.sys.info import num_physical_cores

        self.on = on
        self.cores = num_physical_cores()
        self.low = workers
        self.high = max(workers, 4 * self.cores)
        self.t_ns = monotonic_ns()
        self.cpu = children_cpu_seconds()
        self.busy = -1
        self.ticks = cpu_ticks()

    def adjust(mut self, workers: Int) -> Int:
        """How many workers to have now (looked at every few seconds)."""
        var now = monotonic_ns()
        if not self.on or now - self.t_ns < 5_000_000_000:
            return workers
        var memory = memory_available()
        if memory < LOW_MEMORY:
            self.t_ns = now
            self.cpu = children_cpu_seconds()
            return max(1, workers - max(1, workers // 4))
        # finished children only, so a long test counts all at once: smooth
        var cpu = children_cpu_seconds()
        var busy = (cpu - self.cpu) / (Float64(now - self.t_ns) / 1e9)
        self.busy = busy if self.busy < 0 else (self.busy + busy) / 2
        self.t_ns = now
        self.cpu = cpu
        # the machine's idle share, which other work counts against too
        var ticks = cpu_ticks()
        var idle = 1.0
        if ticks.total > self.ticks.total:
            idle = Float64(ticks.idle - self.ticks.idle) / Float64(ticks.total - self.ticks.total)
        self.ticks = ticks^
        var target = 0.8 * Float64(self.cores)
        if self.busy > target or idle < 0.1:
            return max(self.low, workers - max(1, workers // 8))
        if self.busy < 0.6 * target and idle > 0.3 and memory > 2 * LOW_MEMORY:
            return min(self.high, workers + max(1, workers // 4))
        return workers


def _memory_limit(b: _Batch) -> Int:
    """What a mutant's tests may use before they're stopped: a mutant can make
    them allocate without end, which takes the machine down before a timeout."""
    comptime GB = 1024 * 1024 * 1024
    if b.memory == 0:
        return 4 * GB
    return max(4 * b.memory, b.memory + GB)


def _start(mut r: Run, mut job: _Job) raises:
    ref b = job.batches[job.next]
    var timeout = max(r.config.timeout_floor, b.budget * r.config.timeout_multiplier)
    var env = with_env(r.mojo.env, ["DESPELL_MUTANT=" + String(job.number)])
    r._pool.start(job.number, _test_argv(r, b.file, b.names), r.mdir, env, timeout, _memory_limit(b))
    job.processes += 1
    job.tests += max(1, len(b.names))


def run_mutants(
    mut r: Run, selected: List[Int], config: Config, before: State, current: Dict[String, String], snap: String,
    adaptive: Bool = False,
) raises:
    """Run the selected mutants (by number), saving now and then. With
    `adaptive`, `r.workers` is where to start (see `_Scaler`)."""
    var by_fid = Dict[Int, List[Int]]()
    var by_site = Dict[Int, List[Int]]()
    for i in range(len(r.tests)):
        for fid in r.tests[i].functions:
            var l = by_fid.get(fid, List[Int]())
            l.append(i)
            by_fid[fid] = l^
        for site in r.tests[i].sites:
            var l = by_site.get(site, List[Int]())
            l.append(i)
            by_site[site] = l^
    var todo = List[Int]()
    for n in selected:
        var status = r.mutants[n - 1].status
        if status != COMPILE_ERROR and status != SKIPPED:
            todo.append(n)
    if len(todo) == 0:
        return
    _slow_tests(r, todo, by_fid, by_site)
    var scaler = _Scaler(adaptive, r.workers)
    log(
        "running " + String(len(todo)) + " mutants with " + String(r.workers) + " workers"
        + (", more while the tests leave cores idle" if adaptive else "")
    )
    var t0 = monotonic_ns()
    var last_report = t0
    var last_save = t0
    var save_gap = 10_000_000_000  # ns between saves; grows if saving is slow
    var done = Set[String]()
    var jobs = Dict[Int, _Job]()
    var next = 0
    var timings = String("id\tstatus\tprocesses\ttests\tseconds\n")

    while next < len(todo) or len(r._pool) > 0:
        # keep the workers busy
        r.workers = scaler.adjust(r.workers)
        # with memory low, nothing new until something finishes
        var room = len(r._pool) == 0 or memory_available() >= LOW_MEMORY / 2
        while room and next < len(todo) and len(r._pool) < r.workers:
            var n = todo[next]
            next += 1
            var tests = _tests_for(r, r.mutants[n - 1], by_fid, by_site)
            if len(tests) == 0:
                # with tests restricted to new or changed files, none of
                # which reach it, the earlier result stands
                if not (n in r.allowed):
                    r.mutants[n - 1].status = NO_TESTS
                    r.mutants[n - 1].killed_by = String("")
                    r.mutants[n - 1].detail = String("")
                done.add(r.mutants[n - 1].id)
                _report(r.mutants[n - 1])
                continue
            var job = _Job(n, _batches(r, tests), 0, monotonic_ns(), 0, 0)
            _start(r, job)
            jobs[n] = job^
        if len(r._pool) == 0:
            continue
        var f: Finished
        try:
            f = r._pool.wait_any()
        except e:
            # Ctrl-C: keep what's done
            _save(r, config, before, current, snap, done)
            _write_timings(r, timings)
            log("interrupted after " + String(len(done)) + "/" + String(len(todo)) + " mutants; `despell run` continues from there")
            raise e^
        var n = f.tag
        var job = jobs.pop(n)
        var file = job.batches[job.next].file
        var timeout = max(r.config.timeout_floor, job.batches[job.next].budget * r.config.timeout_multiplier)
        var finished = True
        if f.over_memory:
            r.mutants[n - 1].status = KILLED
            r.mutants[n - 1].killed_by = file
            r.mutants[n - 1].detail = (
                "stopped after using " + _megabytes(f.memory) + " of memory (unmutated, its tests use "
                + _megabytes(job.batches[job.next].memory) + ")"
            )
        elif f.timed_out:
            r.mutants[n - 1].status = TIMEOUT
            r.mutants[n - 1].killed_by = file
            r.mutants[n - 1].detail = "no result after " + format_seconds(timeout) + "s"
        elif f.code != 0:
            var failed = first_failed_test(f.output)
            r.mutants[n - 1].status = KILLED
            r.mutants[n - 1].killed_by = file + "::" + failed if failed.byte_length() else file
            r.mutants[n - 1].detail = String("")
        elif job.next + 1 < len(job.batches):
            job.next += 1
            _start(r, job)
            jobs[n] = job.copy()
            finished = False
        else:
            r.mutants[n - 1].status = SURVIVED
            r.mutants[n - 1].killed_by = String("")
            r.mutants[n - 1].detail = String("")
        if finished:
            done.add(r.mutants[n - 1].id)
            timings += (
                r.mutants[n - 1].id + "\t" + r.mutants[n - 1].status + "\t" + String(job.processes) + "\t"
                + String(job.tests) + "\t" + format_seconds(seconds_since(job.start_ns)) + "\n"
            )
            _report(r.mutants[n - 1])
        var now = monotonic_ns()
        if now - last_report > 10_000_000_000 and len(done) < len(todo):
            log(
                "  " + String(len(done)) + "/" + String(len(todo)) + " mutants done"
                + (" (" + String(r.workers) + " workers)" if adaptive else "")
            )
            last_report = now
        if now - last_save > save_gap:
            _save(r, config, before, current, snap, done)
            last_save = monotonic_ns()
            var took = last_save - now
            # don't let saving crowd out testing: nothing runs meanwhile
            save_gap = max(10_000_000_000, 30 * took)
            if took > 5_000_000_000:
                log("  saving results took " + format_seconds(Float64(took) / 1e9) + "s")
    _write_timings(r, timings)
    var elapsed = seconds_since(t0)
    log("ran " + String(len(todo)) + " mutants (" + format_seconds(elapsed) + "s, " + String(Int(Float64(len(todo)) / max(elapsed, 1e-9) + 0.5)) + "/s)")


def _megabytes(n: Int) -> String:
    return String(n // (1024 * 1024)) + " MB"


def _report(m: MutantRecord):
    if is_actionable(m.status):
        # as they come, so an agent can start on them right away
        var status = m.status
        while status.byte_length() < 10:
            status += " "
        log("  " + status + " " + m.id + "  " + m.location() + "  " + m.description)


def _write_timings(r: Run, timings: String) raises:
    mkdirs(join(r.work, "logs"))
    write_text(join(join(r.work, "logs"), "mutants.tsv"), timings)


# ---- saving --------------------------------------------------------------------


def _save(mut r: Run, config: Config, before: State, current: Dict[String, String], snap: String, fresh: Set[String]) raises -> State:
    """Merge this run's results into the state file: the mutants in `fresh`,
    its compile verdicts and its coverage. Another run may have saved since,
    so everything else comes from the file."""
    var lock = StateLock(config)
    var state = read_state(config)
    var ids = Set[String]()
    for m in r.mutants:
        ids.add(m.id)
        var ran_it = m.id in fresh or m.status == COMPILE_ERROR or m.status == SKIPPED
        state.mutants[m.id] = merge_result(m, state.mutants.get(m.id), before.mutants.get(m.id), ran_it)
    var gone = List[String]()
    for k in state.mutants.keys():
        if not (k in ids):
            gone.append(k)
    for k in gone:
        _ = state.mutants.pop(k)
    if r.stats_done:
        var ran = Set[String]()
        for t in r.tests:
            ran.add(t.file)
        var tests = Dict[String, TestRecord]()
        for item in state.tests.items():
            if not (item.value.file in ran) and item.value.file in current:
                tests[item.key] = item.value.copy()
        for t in r.tests:
            tests[t.id] = t.copy()
        state.tests = tests^
    var saved = current.copy()
    saved[FUNCTIONS] = _function_names(r)
    state.snapshots[snap] = saved^
    state.numbered = snap
    write_state(config, state)
    lock.release()
    return state^


# ---- what to run ---------------------------------------------------------------


def _coverage_current(
    f: String, ids: List[String], old_tests: Dict[String, TestRecord], snapshots: Dict[String, Dict[String, String]],
    current: Dict[String, String],
) -> Bool:
    """Whether the saved coverage of test file `f` (its tests `ids`) holds:
    measured on every statement, with the same code and tests."""
    if len(ids) == 0:
        return False
    try:
        for id in ids:
            if not old_tests[id].complete:
                return False
        var snap_id = old_tests[ids[0]].snapshot
        if not (snap_id in snapshots):
            return False
        ref snap = snapshots[snap_id]
        return (
            snap.get("sources", "") == current.get("sources", "")
            and snap.get("*", "") == current.get("*", "")
            and snap.get(f, "") == current.get(f, "-")
        )
    except:
        return False


def _reached(r: Run, tests: List[TestRecord]) -> Set[Int]:
    """The mutants (numbers) the tests reach."""
    var sites = Set[Int]()
    var fids = Set[Int]()
    for t in tests:
        for n in t.sites:
            sites.add(n)
        for n in t.functions:
            fids.add(n)
    var out = Set[Int]()
    for m in r.mutants:
        if (m.site in sites) if m.site >= 0 else (m.fid in fids):
            out.add(m.number)
    return out^


def _coverage(
    mut r: Run, old_tests: Dict[String, TestRecord], snapshots: Dict[String, Dict[String, String]],
    current: Dict[String, String],
) raises -> Set[String]:
    """Learn what each test file to build reaches: from the last run where
    that still holds, else, for a big build, by building it without mutants
    first. Then each binary only needs the mutants its tests reach. Returns
    the test files whose tests ran here."""
    var by_file = Dict[String, List[String]]()
    for item in old_tests.items():
        var l = by_file.get(item.value.file, List[String]())
        l.append(item.key)
        by_file[item.value.file] = l^
    var stale = List[String]()
    for f in r.test_files():
        var ids = by_file.get(f, List[String]())
        if _coverage_current(f, ids, old_tests, snapshots, current):
            var tests = List[TestRecord]()
            for id in ids:
                tests.append(old_tests[id].copy())
            r.file_sets[f] = _reached(r, tests)
        else:
            stale.append(f)
    var threshold = COVERAGE_FIRST
    var override = getenv("DESPELL_COVERAGE_FIRST", "")
    if override.byte_length():
        threshold = Int(atol(override))
    if len(stale) == 0 or len(r.enabled) < threshold:
        return Set[String]()
    var t0 = monotonic_ns()
    log("measuring coverage first: building " + String(len(stale)) + " test files without mutants")
    try:
        r.coverage_build(stale)
    except e:
        if String(e) == "interrupted":
            raise e^
        log("building without mutants to measure coverage failed, so every binary gets every mutant: " + String(e))
        return Set[String]()
    var stale_set = Set[String]()
    for f in stale:
        stale_set.add(f)
    collect_stats(r, stale_set)
    for f in stale:
        var tests = List[TestRecord]()
        for t in r.tests:
            if t.file == f:
                tests.append(t.copy())
        r.file_sets[f] = _reached(r, tests)
    log("measured coverage (" + format_seconds(seconds_since(t0)) + "s)")
    return stale_set^


def _function_names(r: Run) -> String:
    """`<file>::<name>` of each function, one line per function number:
    coverage is saved by number, and numbers shift when the code changes."""
    var names = List[String](length=r.n_functions, fill=String(""))
    for m in r.mutants:
        if m.fid < len(names):
            names[m.fid] = m.file + "::" + m.function
    var out = String("")
    for n in names:
        out += n + "\n"
    return out^


def _reaches_by_name(
    ids: List[String], old_tests: Dict[String, TestRecord], snapshots: Dict[String, Dict[String, String]],
    current: Dict[String, String], f: String, wanted: Set[String],
) -> Optional[Bool]:
    """Whether the tests `ids` of test file `f` reached any of the `wanted`
    functions (`<file>::<name>`) when last measured, when only the code under
    test changed since: then the function numbers have shifted, but the
    functions the tests reach mostly haven't, like the results of mutants in
    functions that didn't change. None when that can't be told."""
    try:
        for id in ids:
            if not old_tests[id].complete:
                return None
        var snap_id = old_tests[ids[0]].snapshot
        if not (snap_id in snapshots):
            return None
        ref snap = snapshots[snap_id]
        if not (FUNCTIONS in snap) or snap.get("*", "") != current.get("*", "") or snap.get(f, "") != current.get(f, "-"):
            return None
        var names = snap[FUNCTIONS].split("\n")
        for id in ids:
            for fid in old_tests[id].functions:
                if fid < len(names) and String(names[fid]) in wanted:
                    return True
        return False
    except:
        return None


def _files_to_build(
    r: Run, selected: List[Int], plans: Dict[Int, Plan], old_tests: Dict[String, TestRecord],
    snapshots: Dict[String, Dict[String, String]], current: Dict[String, String],
) -> Set[String]:
    """The test files that can kill the selected mutants.

    For a mutant re-checked against new or changed tests, those. Otherwise
    the files whose tests reached it last time, and any file without coverage
    measured on the same sources and tests, which might.
    """
    var needed = Set[String]()
    var full = List[Int]()
    for n in selected:
        var p = plans.get(n, Plan(True, True, Set[String](), False))
        if p.all_files:
            full.append(n)
        else:
            for f in p.files:
                needed.add(f)
    if len(full) == 0:
        return needed^
    var by_file = Dict[String, List[String]]()
    for item in old_tests.items():
        var l = by_file.get(item.value.file, List[String]())
        l.append(item.key)
        by_file[item.value.file] = l^
    var wanted = Set[String]()
    for n in full:
        wanted.add(r.mutants[n - 1].file + "::" + r.mutants[n - 1].function)
    for item in current.items():
        var f = item.key
        if f == "*" or f == "sources" or f in needed:
            continue
        var ids = by_file.get(f, List[String]())
        if len(ids) == 0:
            needed.add(f)  # coverage unknown: it might reach them
            continue
        if not _coverage_current(f, ids, old_tests, snapshots, current):
            var by_name = _reaches_by_name(ids, old_tests, snapshots, current, f, wanted)
            if not by_name or by_name.value():
                needed.add(f)
            continue
        var reaches = False
        for id in ids:
            ref t = old_tests.get(id).value()
            for n in full:
                if t.covers(r.mutants[n - 1]):
                    reaches = True
        if reaches:
            needed.add(f)
    return needed^


def run(
    config: Config, selectors: List[String], workers: Int, force: Bool = False, adaptive: Bool = False
) raises -> List[MutantRecord]:
    """Run the selected mutants, or, without selectors, every mutant without
    an up-to-date result (with `force`, whatever their results). Returns the
    selected mutants, or all of them. With `adaptive`, the number of workers
    running mutants follows the CPU the tests use, starting at `workers`."""
    # mutants/ itself, or a private copy beside it if another run has it
    mkdirs(config.mutants_dir())
    # test processes of a run that died (in mutants/ or a side copy) hold a
    # CPU, and with older despells, which let them inherit it, its lock
    var orphans = kill_strays(config.mutants_dir(), orphans_only=True)
    var main_lock = lock_file(join(config.mutants_dir(), MAIN_LOCK), False)
    var tree = config.mutants_dir()
    if orphans > 0:
        log("stopped " + String(orphans) + " test processes an earlier despell run left running")
    if main_lock >= 0:
        # with the lock, nothing alive uses this tree's test binaries
        var strays = kill_strays(join(tree, WORK_DIR))
        if strays > 0:
            log("stopped " + String(strays) + " test processes an earlier despell run left running")
    if main_lock < 0:
        tree = join(join(config.mutants_dir(), SIDE_DIR), String(getpid()))
        log("another despell run is using mutants/; this one works in mutants/" + String(SIDE_DIR) + "/" + String(getpid()))
    try:
        var result = _run(config, selectors, workers, tree, force, adaptive)
        _release(main_lock, tree, config)
        return result^
    except e:
        _release(main_lock, tree, config)
        raise e^


def _release(lock: Int, tree: String, config: Config):
    if lock >= 0:
        unlock_file(lock)
    else:
        rmtree(tree)


def _run(
    config: Config, selectors: List[String], workers: Int, tree: String, force: Bool, adaptive: Bool
) raises -> List[MutantRecord]:
    var t0 = monotonic_ns()
    var lock = StateLock(config)
    var before = read_state(config)
    lock.release()
    var r = Run(config, workers, tree)
    r.prepare()
    r.contain_tests()
    var all_tests = discover_tests(config)
    if len(all_tests) == 0:
        raise Error("no test files found in " + config.tests_dir)
    var test_files = Set[String]()
    for t in all_tests:
        test_files.add(t.file)
    var current = test_file_hashes(config, test_files)
    var sources = String("")
    for sf in r.files:
        sources += sf.source + "\0"
    current["sources"] = hash_text(sources)
    var snap = snapshot_id(current)
    r.test_hashes = current.copy()
    log(
        "generated " + String(len(r.mutants)) + " mutants in " + String(r.n_functions) + " functions across "
        + String(len(r.files)) + " files; " + String(len(all_tests)) + " tests"
    )

    # earlier results stand until replaced
    var plans = Dict[Int, Plan]()
    for i in range(len(r.mutants)):
        ref m = r.mutants[i]
        var old = before.mutants.get(m.id)
        if old and old.value().fingerprint == m.fingerprint:
            ref o = old.value()
            m.status = o.status
            m.killed_by = o.killed_by
            m.detail = o.detail
            m.tested_with = o.tested_with
            m.compiles = o.compiles
            m.eq_checked = o.eq_checked
        plans[m.number] = plan(m, old, before.snapshots, current)
    var chosen = List[Int]()
    var matched = List[Bool](length=len(selectors), fill=False)
    for m in r.mutants:
        if len(selectors) == 0 or note_matches(m, selectors, matched):
            chosen.append(m.number)
            if force:
                plans[m.number] = Plan(True, True, Set[String](), False)
    var unmatched = unmatched_error(selectors, matched)
    if unmatched:
        raise Error(unmatched)
    var selected = List[Int]()
    for n in chosen:
        if plans[n].run:
            selected.append(n)
    if len(selected) < len(chosen):
        log(
            String(len(chosen) - len(selected)) + " mutants have results that no change to the code or tests since "
            + "can affect; running the other " + String(len(selected))
        )
    if len(selected) == 0:
        log("nothing to run: every result is up to date. `despell run --force <selector>` runs them anyway")
        var state = _save(r, config, before, current, snap, _find_equivalent(r, chosen))
        return _records(state, r, chosen)
    for n in selected:
        r.mutants[n - 1].tested_with = snap
        if plans[n].retry:
            # if the changed files don't even reach it any more, the old
            # kill doesn't stand either
            r.mutants[n - 1].status = NOT_CHECKED
        if not plans[n].all_files:
            r.allowed[n] = plans[n].files.copy()
    # Only the selected mutants go into the build, and only the test files
    # that can kill them get built: that's what makes the write-a-test,
    # re-check loop fast, above all with new tests in a new, small file.
    var partial = len(selected) < len(r.mutants)
    var only: Optional[Set[Int]] = None
    if partial:
        var needed = _files_to_build(r, selected, plans, before.tests, before.snapshots, current)
        var tests = List[TestRecord]()
        for t in all_tests:
            if t.file in needed:
                tests.append(t.copy())
        r.tests = tests^
        if len(needed) < len(test_files):
            log("building the " + String(len(needed)) + " of " + String(len(test_files)) + " test files that can reach these mutants")
        var s = Set[Int]()
        for n in selected:
            s.add(n)
        only = s^
    else:
        r.tests = all_tests^
    r.begin_build(before.mutants, only)
    var measured = _coverage(r, before.tests, before.snapshots, current)
    r.finish_build(before.mutants)
    # a long build's verdicts survive whatever goes wrong after it
    _ = _save(r, config, before, current, snap, Set[String]())
    # the binaries with mutants run the same code when none is active, so
    # what was just measured holds
    var unmeasured = Set[String]()
    for f in r.test_files():
        if not (f in measured):
            unmeasured.add(f)
    if len(unmeasured) > 0:
        collect_stats(r, unmeasured)
    for i in range(len(r.tests)):
        r.tests[i].snapshot = snap
    r.stats_done = True
    run_mutants(r, selected, config, before, current, snap, adaptive)
    var fresh = Set[String]()
    for n in selected:
        fresh.add(r.mutants[n - 1].id)
    var state = _save(r, config, before, current, snap, fresh)
    for id in _find_equivalent(r, chosen):
        fresh.add(id)
    state = _save(r, config, before, current, snap, fresh)
    # killed by a test file that changed, and it no longer does
    var again = List[String]()
    for n in selected:
        ref m = r.mutants[n - 1]
        if plans[n].retry and m.status != KILLED and m.status != TIMEOUT:
            again.append(m.id)
    if len(again) > 0:
        log(
            String(len(again)) + " mutants are no longer killed by the test files that changed; running them against "
            + "every test that reaches them"
        )
        _ = _run(config, again, workers, tree, True, adaptive)
        var relock = StateLock(config)
        state = read_state(config)
        relock.release()
    log("done in " + format_seconds(seconds_since(t0)) + "s")
    if len(selectors) > 0:
        return _records(state, r, chosen)
    var all = List[MutantRecord]()
    for item in state.mutants.items():
        all.append(item.value.copy())
    return all^


def _find_equivalent(mut r: Run, chosen: List[Int]) raises -> Set[String]:
    """Mark the survivors (and untested) of the `chosen` that compile to the
    same code as the original `equivalent`: no test can kill them. Each is
    only compared once, while its function doesn't change. Returns the ids
    of the ones compared."""
    var candidates = List[Int]()
    var ids = Set[String]()
    for n in chosen:
        ref m = r.mutants[n - 1]
        if (m.status == SURVIVED or m.status == NO_TESTS) and m.eq_checked < EQ_VERSION:
            candidates.append(n)
            ids.add(m.id)
    if len(candidates) == 0:
        return ids^
    var t0 = monotonic_ns()
    var found = r.find_equivalent(candidates)
    for n in candidates:
        r.mutants[n - 1].eq_checked = EQ_VERSION
    for n in found:
        r.mutants[n - 1].status = EQUIVALENT
        r.mutants[n - 1].killed_by = String("")
        r.mutants[n - 1].detail = String("compiles to the same code as the original")
    log(
        "compared " + String(len(candidates)) + " surviving mutants' code with the original's ("
        + format_seconds(seconds_since(t0)) + "s): " + String(len(found)) + " compile to the same code, so are "
        + "equivalent"
    )
    return ids^


def _records(state: State, r: Run, numbers: List[Int]) -> List[MutantRecord]:
    var out = List[MutantRecord]()
    for n in numbers:
        var id = r.mutants[n - 1].id
        var m = state.mutants.get(id)
        out.append(m.value().copy() if m else r.mutants[n - 1].copy())
    return out^
