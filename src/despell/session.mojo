"""A `despell run`: what to run, the coverage and mutant phases, and saving."""

from std.collections import Dict, Set
from std.os import getenv

from .fsutil import join, mkdirs, rmtree, write_text, hash_text
from .project import Config
from .runner import Command, Run, discover_tests, log, run_parallel
from .state import (
    COMPILE_ERROR, KILLED, MAIN_LOCK, NO_TESTS, SIDE_DIR, SKIPPED, SURVIVED, TIMEOUT, MutantRecord, Plan, State,
    StateLock, TestRecord, is_actionable, matches, merge_result, plan, read_state, snapshot_id, test_file_hashes,
    write_state,
)
from .sysutil import Finished, getpid, lock_file, monotonic_ns, seconds_since, unlock_file, with_env
from .textutil import first_failed_test, format_seconds, numbers_after

comptime STATS_MODE = "-1"
# Building with this many mutants or more, test files without up-to-date
# coverage are first built without mutants to measure it: then each binary
# only gets the mutants its tests reach. DESPELL_COVERAGE_FIRST overrides it.
comptime COVERAGE_FIRST = 1000


# ---- phase 3: coverage ---------------------------------------------------------


def _test_argv(r: Run, file: String, names: List[String]) -> List[String]:
    var argv = List[String]()
    argv.append(r.binary_for(file))
    if len(names) > 0:
        argv.append("--only")
        for n in names:
            argv.append(n)
    return argv^


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
            msg += "\n--- " + r.tests[indices[failing[k]]].id + "\n" + String(results[failing[k]].output.strip()) + "\n"
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


def _batches(tests: List[TestRecord]) -> List[_Batch]:
    """One failing test is enough, but a TestSuite runs all the tests it's
    given. Most mutants that get killed fail the first test they meet, so the
    fastest test runs on its own, then the rest in batches that double in
    size: a killed mutant stops early, and a survivor only pays for a few
    more process starts (milliseconds each)."""
    var sorted_tests = tests.copy()
    sort(Span(sorted_tests), _by_duration)
    var batches = List[_Batch]()
    ref first = sorted_tests[0]
    var first_names = List[String]()
    if first.name.byte_length():
        first_names.append(first.name)
    batches.append(_Batch(first.file, first_names^, first.duration))
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
        for i in range(1, len(sorted_tests)):
            ref t = sorted_tests[i]
            if t.file != files[j]:
                continue
            if t.name.byte_length():
                names.append(t.name)
            budget += t.duration
            count += 1
            if count == size:
                batches.append(_Batch(files[j], names^, budget))
                names = List[String]()
                budget = 0
                count = 0
                size *= 2
        if count > 0:
            batches.append(_Batch(files[j], names^, budget))
    return batches^


def _tests_for(r: Run, m: MutantRecord, by_fid: Dict[Int, List[Int]], by_site: Dict[Int, List[Int]]) -> List[TestRecord]:
    """The tests that run the mutant's statement (only they can kill it),
    within the test files it's allowed."""
    var indices = by_site.get(m.site, List[Int]()) if m.site >= 0 else by_fid.get(m.fid, List[Int]())
    var restricted = m.number in r.allowed
    var allowed = r.allowed.get(m.number, Set[String]())
    var tests = List[TestRecord]()
    for i in indices:
        # coverage can vary between runs (timing): only binaries holding the
        # mutant can test it
        if (not restricted or r.tests[i].file in allowed) and r.holds(r.tests[i].file, m.number):
            tests.append(r.tests[i].copy())
    return tests^


def _start(mut r: Run, mut job: _Job) raises:
    ref b = job.batches[job.next]
    var timeout = max(r.config.timeout_floor, b.budget * r.config.timeout_multiplier)
    var env = with_env(r.mojo.env, ["DESPELL_MUTANT=" + String(job.number)])
    r._pool.start(job.number, _test_argv(r, b.file, b.names), r.mdir, env, timeout)
    job.processes += 1
    job.tests += max(1, len(b.names))


def run_mutants(
    mut r: Run, selected: List[Int], config: Config, before: State, current: Dict[String, String], snap: String
) raises:
    """Run the selected mutants (by number), saving now and then."""
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
    log("running " + String(len(todo)) + " mutants with " + String(r.workers) + " workers")
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
        while next < len(todo) and len(r._pool) < r.workers:
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
            var job = _Job(n, _batches(tests), 0, monotonic_ns(), 0, 0)
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
        if f.timed_out:
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
            log("  " + String(len(done)) + "/" + String(len(todo)) + " mutants done")
            last_report = now
        if now - last_save > save_gap:
            _save(r, config, before, current, snap, done)
            last_save = monotonic_ns()
            var took = last_save - now
            # don't let saving crowd out testing
            save_gap = max(10_000_000_000, 10 * took)
            if took > 2_000_000_000:
                log("  saving results took " + format_seconds(Float64(took) / 1e9) + "s")
    _write_timings(r, timings)
    var elapsed = seconds_since(t0)
    log("ran " + String(len(todo)) + " mutants (" + format_seconds(elapsed) + "s, " + String(Int(Float64(len(todo)) / max(elapsed, 1e-9) + 0.5)) + "/s)")


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
    state.snapshots[snap] = current.copy()
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
) raises:
    """Learn what each test file to build reaches: from the last run where
    that still holds, else, for a big build, by building it without mutants
    first. Then each binary only needs the mutants its tests reach."""
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
        return
    var t0 = monotonic_ns()
    try:
        r.coverage_build(stale)
    except e:
        if String(e) == "interrupted":
            raise e^
        log("building without mutants to measure coverage failed, so every binary gets every mutant: " + String(e))
        return
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
    log(
        "measured coverage first, building " + String(len(stale)) + " test files without mutants ("
        + format_seconds(seconds_since(t0)) + "s)"
    )


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
        var p = plans.get(n, Plan(True, True, Set[String]()))
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
    for item in current.items():
        var f = item.key
        if f == "*" or f == "sources" or f in needed:
            continue
        var ids = by_file.get(f, List[String]())
        if len(ids) == 0:
            needed.add(f)  # coverage unknown: it might reach them
            continue
        if not _coverage_current(f, ids, old_tests, snapshots, current):
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


def run(config: Config, selectors: List[String], workers: Int, force: Bool = False) raises -> List[MutantRecord]:
    """Run the selected mutants, or, without selectors, every mutant without
    an up-to-date result (with `force`, whatever their results). Returns the
    selected mutants, or all of them."""
    # mutants/ itself, or a private copy beside it if another run has it
    mkdirs(config.mutants_dir())
    var main_lock = lock_file(join(config.mutants_dir(), MAIN_LOCK), False)
    var tree = config.mutants_dir()
    if main_lock < 0:
        tree = join(join(config.mutants_dir(), SIDE_DIR), String(getpid()))
        log("another despell run is using mutants/; this one works in mutants/" + String(SIDE_DIR) + "/" + String(getpid()))
    try:
        var result = _run(config, selectors, workers, tree, force)
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


def _run(config: Config, selectors: List[String], workers: Int, tree: String, force: Bool) raises -> List[MutantRecord]:
    var t0 = monotonic_ns()
    var lock = StateLock(config)
    var before = read_state(config)
    lock.release()
    var r = Run(config, workers, tree)
    r.prepare()
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
        plans[m.number] = plan(m, old, before.snapshots, current)
    var chosen = List[Int]()
    for m in r.mutants:
        if len(selectors) == 0 or matches(m, selectors):
            chosen.append(m.number)
            if force:
                plans[m.number] = Plan(True, True, Set[String]())
    if len(selectors) > 0 and len(chosen) == 0:
        raise Error("no mutants match " + _joined(selectors))
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
        var state = _save(r, config, before, current, snap, Set[String]())
        return _records(state, r, chosen)
    for n in selected:
        r.mutants[n - 1].tested_with = snap
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
    _coverage(r, before.tests, before.snapshots, current)
    r.finish_build(before.mutants)
    # a long build's verdicts survive whatever goes wrong after it
    _ = _save(r, config, before, current, snap, Set[String]())
    collect_stats(r)
    for i in range(len(r.tests)):
        r.tests[i].snapshot = snap
    r.stats_done = True
    run_mutants(r, selected, config, before, current, snap)
    var fresh = Set[String]()
    for n in selected:
        fresh.add(r.mutants[n - 1].id)
    var state = _save(r, config, before, current, snap, fresh)
    log("done in " + format_seconds(seconds_since(t0)) + "s")
    if len(selectors) > 0:
        return _records(state, r, chosen)
    var all = List[MutantRecord]()
    for item in state.mutants.items():
        all.append(item.value.copy())
    return all^


def _records(state: State, r: Run, numbers: List[Int]) -> List[MutantRecord]:
    var out = List[MutantRecord]()
    for n in numbers:
        var id = r.mutants[n - 1].id
        var m = state.mutants.get(id)
        out.append(m.value().copy() if m else r.mutants[n - 1].copy())
    return out^


def _joined(words: List[String]) -> String:
    var out = String("")
    for i in range(len(words)):
        if i:
            out += " "
        out += words[i]
    return out^
