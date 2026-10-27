"""Orchestrates a mutation testing run.

Phases:
1. copy the project into ./mutants and write mutation schemata over the sources
2. build each test file into a binary; mutants the compiler rejects are dropped
   and the build is retried until it succeeds
3. run every test once with DESPELL_MUTANT=-1, which runs the original code but
   records which statements each test reaches (and checks the suite is green)
4. run each mutant against the tests that reach its statement
"""

from std.collections import Dict, Set
from std.os.path import isdir
from std.sys.info import CompilationTarget

from .fsutil import (
    copy_file, copy_tree, hash_bytes, hash_text, read_bytes, is_dir, is_file, join, list_dir, mkdirs, parent, path_exists, read_text,
    real_path, relative_to, remove_file, rmtree, walk_files, write_text, Hasher,
)
from .jsonio import Json, encode, parse
from .mutation import Function, GeneratedFile, Region, analyze, generate
from .project import Config, MojoEnv, find_mojo
from .state import (
    COMPILE_ERROR, KILLED, MAIN_LOCK, NO_TESTS, NOT_CHECKED, SIDE_DIR, SKIPPED, STATE_FILE, STATE_LOCK, SURVIVED,
    TIMEOUT, MutantRecord, Plan, State, StateLock, TestRecord, is_actionable, is_final, matches, merge_result,
    not_copied, plan, read_state, snapshot_id, test_file_hashes, write_state,
)
from .sysutil import Finished, ProcessPool, environment, executable_path, getpid, lock_file, monotonic_ns, run_command, seconds_since, unlock_file, with_env
from .textutil import (
    Diagnostic, absolutize_imports, first_error, first_failed_test, format_seconds, glob_match, join_words,
    link_references, numbers_after, parse_diagnostics, without_warnings,
)
from .tokenizer import tokenize

comptime WORK_DIR = ".despell"
comptime STATS_MODE = "-1"
comptime MANIFEST = "manifest.json"


def log(msg: String):
    print(msg, flush=True)


@fieldwise_init
struct SourceFile(Copyable, Movable):
    var rel: String
    var module: String
    var source: String
    var functions: List[Function]
    var first_fid: Int
    var first_mutant: Int
    var n_mutants: Int
    var package: List[String]  # the package the module is in, for relative imports


@fieldwise_init
struct SourcePath(Copyable, Movable):
    var rel: String  # relative to the project root
    var module_rel: String  # relative to the include dir holding it


def module_name(module_rel: String) -> String:
    var stem = String(module_rel[byte = 0 : module_rel.byte_length() - 5]) if module_rel.endswith(".mojo") else module_rel
    var parts = List[String]()
    for p in stem.split("/"):
        parts.append(String(p))
    if len(parts) > 0 and parts[len(parts) - 1] == "__init__":
        _ = parts.pop()
    return join_words(parts, ".") if len(parts) > 0 else String("__root__")


def _package_of(module_rel: String) -> List[String]:
    var parts = List[String]()
    for p in module_rel.split("/"):
        parts.append(String(p))
    _ = parts.pop()
    return parts^


def _normalize(path: String) -> String:
    """`a/./b` and `./a` as `a/b` and `a`."""
    var parts = List[String]()
    for p in path.split("/"):
        if String(p) != "." and String(p).byte_length():
            parts.append(String(p))
    var out = join_words(parts, "/")
    return "/" + out if path.startswith("/") else out


def _under(rel: String, dir: String) -> Bool:
    var d = _normalize(dir)
    return d.byte_length() == 0 or rel == d or rel.startswith(d + "/")


def discover_sources(config: Config) -> List[SourcePath]:
    var result = List[SourcePath]()
    for base in config.paths_to_mutate:
        var candidates = List[String]()
        if is_file(join(config.root, base)):
            candidates.append(_normalize(base))
        else:
            for f in walk_files(join(config.root, base), List[String]()):
                if f.endswith(".mojo"):
                    candidates.append(_normalize(join(base, f)))
        for rel in candidates:
            if _under(rel, config.tests_dir) or _under(rel, "mutants"):
                continue
            var hidden = False
            for part in rel.split("/"):
                if String(part).startswith("."):
                    hidden = True
            if hidden:
                continue
            var skip = False
            for pattern in config.do_not_mutate:
                if glob_match(pattern, rel):
                    skip = True
            if skip:
                continue
            # module names are relative to the include dir that contains the file
            var module_rel = rel
            for inc in config.include_dirs:
                if _under(rel, inc):
                    var d = _normalize(inc)
                    module_rel = String(rel[byte = d.byte_length() + 1 :]) if d.byte_length() else rel
                    break
            result.append(SourcePath(rel, module_rel))
    return result^


def discover_tests(config: Config) raises -> List[TestRecord]:
    var records = List[TestRecord]()
    for f in walk_files(join(config.root, config.tests_dir), List[String]()):
        var name = String(f[byte = f.rfind("/") + 1 :]) if "/" in f else f
        if not name.startswith("test") or not name.endswith(".mojo"):
            continue
        var rel = _normalize(join(config.tests_dir, f))
        var source = read_text(join(config.root, rel))
        var names = List[String]()
        try:
            for ll in tokenize(source).logical_lines:
                if ll.indent == 0 and len(ll.tokens) > 1 and ll.tokens[0].text == "def" and ll.tokens[1].text.startswith("test_"):
                    names.append(ll.tokens[1].text)
        except:
            pass
        if len(names) > 0 and "TestSuite" in source:
            for n in names:
                records.append(TestRecord(rel + "::" + n, rel, n))
        else:
            records.append(TestRecord(rel, rel, String("")))
    return records^


def _fingerprint(lines: List[String], f: Function, description: String, line: Int) -> String:
    var h = Hasher()
    for i in range(f.def_line, f.body_end + 1):
        h.update(lines[i])
    h.update(description)
    h.update(String(line))
    return h.hex()


# ---- the pre-check's exported modules --------------------------------------------


struct Exported(Movable):
    """A module with its functions marked `@export`, for the pre-check."""

    var text: String
    var inserted: List[Int]  # lines of the inserted decorators, ascending
    var by_line: Dict[Int, Int]  # decorator line and def line -> function ordinal

    def __init__(out self, var text: String, var inserted: List[Int], var by_line: Dict[Int, Int]):
        self.text = text^
        self.inserted = inserted^
        self.by_line = by_line^

    def original_line(self, line: Int) -> Int:
        """Line number in the text before the decorators were inserted."""
        var before = 0
        for i in self.inserted:
            if i < line:
                before += 1
        return line - before


def add_exports(text: String, skip: Set[Int]) raises -> Exported:
    """Mark every function `@export`, except the ordinals in `skip`.

    Mojo only instantiates what's reachable from `main` and exported
    functions, and stops at the first failure under each of them. Exporting
    every function makes each one its own root, so a single build reports an
    instantiation error for every function that has one. Functions are
    numbered by the order of their `def`s, leaving out despell's own, so the
    numbers match between the original and the generated module.
    """
    var src = tokenize(text)
    var defs = List[Int]()
    for ll in src.logical_lines:
        if len(ll.tokens) > 1 and ll.tokens[0].text == "def" and not ll.tokens[1].text.startswith("_despell"):
            defs.append(ll.first_line)
    var out = String("")
    var n_out = 0
    var inserted = List[Int]()
    var by_line = Dict[Int, Int]()
    var prev = 0
    for ordinal in range(len(defs)):
        var def_line = defs[ordinal]
        for i in range(prev, def_line):
            out += src.lines[i]
            n_out += 1
        prev = def_line
        if ordinal in skip:
            continue
        var line = src.lines[def_line]
        var indent = String(line[byte = 0 : line.byte_length() - String(line.lstrip()).byte_length()])
        inserted.append(n_out)
        by_line[n_out] = ordinal
        by_line[n_out + 1] = ordinal
        out += indent + '@export("despell_x_' + String(ordinal) + '")\n'
        n_out += 1
    for i in range(prev, len(src.lines)):
        out += src.lines[i]
    return Exported(out^, inserted^, by_line^)


# ---- running commands ----------------------------------------------------------


@fieldwise_init
struct Command(Copyable, Movable):
    var argv: List[String]
    var cwd: String
    var env: List[String]
    var timeout: Float64


def run_parallel(commands: List[Command], workers: Int) raises -> List[Finished]:
    """Run the commands, `workers` at a time; results in the same order."""
    var results = List[Optional[Finished]]()
    for _ in range(len(commands)):
        results.append(None)
    var pool = ProcessPool()
    var next = 0
    while next < len(commands) or len(pool) > 0:
        while next < len(commands) and len(pool) < workers:
            ref c = commands[next]
            pool.start(next, c.argv, c.cwd, c.env, c.timeout)
            next += 1
        var f = pool.wait_any()
        var tag = f.tag
        results[tag] = f^
    var out = List[Finished]()
    for i in range(len(results)):
        out.append(results[i].take())
    return out^


# ---- the run -------------------------------------------------------------------


@fieldwise_init
struct Failure(Copyable, Movable):
    var file: String
    var output: String
    var group: Int  # index into Built.groups


@fieldwise_init
struct _Group(Copyable, Movable):
    """Test files whose binaries hold the same mutants, and the copy of the
    project they're built in."""

    var root: String
    var files: List[String]
    var generated: List[GeneratedFile]


struct Built(Movable):
    var groups: List[_Group]
    var failures: List[Failure]

    def __init__(out self, var groups: List[_Group], var failures: List[Failure]):
        self.groups = groups^
        self.failures = failures^


def _set_key(s: Set[Int]) -> String:
    var ns = List[Int]()
    for n in s:
        ns.append(n)
    sort(ns)
    var h = Hasher()
    for n in ns:
        h.update(String(n))
    return h.hex()


def _sorted(s: Set[Int]) -> List[Int]:
    var ns = List[Int]()
    for n in s:
        ns.append(n)
    sort(ns)
    return ns^


@fieldwise_init
struct Suspects(Copyable, Movable):
    var group: List[Int]
    var fid: Int  # -1: not a whole function
    var files: List[String]


@fieldwise_init
struct _Frame(Copyable, Movable):
    var where: Int  # 0: the checked module, 1: another module of the project, 2: elsewhere
    var line: Int
    var message: String


# Lets a test signal only what's in its sandbox and its process group, which
# despell gives each test process (a macOS sandbox profile)
comptime SIGNAL_SANDBOX = (
    "(version 1)(allow default)(deny signal)(allow signal (target same-sandbox))(allow signal (target pgrp))"
)


struct Run(Movable):
    var config: Config
    var workers: Int
    var mdir: String  # where the project copy goes: mutants/, or a private one beside it
    var work: String
    var mojo: MojoEnv
    var have_mojo: Bool
    var files: List[SourceFile]
    var mutants: List[MutantRecord]  # mutant number n is mutants[n - 1]
    var tests: List[TestRecord]
    var n_functions: Int
    var n_builds: Int
    # test files each mutant is run against (absent: all that reach it)
    var allowed: Dict[Int, Set[String]]
    var stats_done: Bool
    # what each test file hashed to when this run started, and "*" for the
    # rest of the tests dir: what decides whether last run's binaries still do
    var test_hashes: Dict[String, String]
    # what's being built: the mutants, and functions that can't hold mutants
    var enabled: Set[Int]
    var disabled_functions: Set[Int]
    # per test file, the mutants its tests reach (absent: not known), which
    # are all its binary needs
    var file_sets: Dict[String, Set[Int]]
    var build_t0: Int
    var _generator: String  # a hash of despell itself
    var _pool: ProcessPool  # the test processes of the mutants running
    # what test commands run under (see `contain_tests`)
    var test_prefix: List[String]

    def __init__(out self, config: Config, workers: Int, tree: String):
        self.config = config.copy()
        self.workers = workers
        self.mdir = tree
        self.work = join(tree, WORK_DIR)
        self.mojo = MojoEnv(List[String](), List[String]())
        self.have_mojo = False
        self.files = List[SourceFile]()
        self.mutants = List[MutantRecord]()
        self.tests = List[TestRecord]()
        self.n_functions = 0
        self.n_builds = 0
        self.allowed = Dict[Int, Set[String]]()
        self.stats_done = False
        self.test_hashes = Dict[String, String]()
        self.enabled = Set[Int]()
        self.disabled_functions = Set[Int]()
        self.file_sets = Dict[String, Set[Int]]()
        self.build_t0 = 0
        self._generator = String("")
        self._pool = ProcessPool()
        self.test_prefix = List[String]()

    def mutant(mut self, n: Int) -> ref[self.mutants] MutantRecord:
        return self.mutants[n - 1]

    # ---- phase 1: generation -------------------------------------------------

    def contain_tests(mut self):
        """Keep the tests from signaling processes they didn't start. Code
        that stops its child processes is one mutant away from `kill(-1,
        SIGTERM)`, which on a desktop takes down every program the user has
        open (despell included)."""
        if not self.config.sandbox_tests:
            return
        comptime if CompilationTarget.is_macos():
            var prefix = List[String]()
            for a in ["/usr/bin/sandbox-exec", "-p", SIGNAL_SANDBOX]:
                prefix.append(String(a))
            try:
                var probe = prefix.copy()
                probe.append("/usr/bin/true")
                if run_command(probe, self.mdir, environment(), 30).code == 0:
                    self.test_prefix = prefix^
                    return
            except:
                pass
            log("warning: can't sandbox the tests (sandbox-exec failed), so a mutant could signal any of your processes")
        else:
            log("warning: tests aren't sandboxed on this platform, so a mutant could signal any of your processes")

    def prepare(mut self) raises:
        ref cfg = self.config
        var keep = not_copied()
        for name in [STATE_FILE, STATE_LOCK, MAIN_LOCK, SIDE_DIR, WORK_DIR]:
            keep.append(String(name))
        if is_dir(self.mdir):
            # an editor's environment in here is expensive to recreate, and
            # something else may be writing to it (Finder, say)
            for name in list_dir(self.mdir):
                if not (name in keep):
                    rmtree(join(self.mdir, name))
        mkdirs(self.mdir)
        # keep mutants/ out of git, unless the project already does: tests
        # that honor .gitignore (a file tree, say) would see an empty project
        var already_ignored = False
        try:
            var r = run_command([String("git"), String("check-ignore"), String("-q"), String("mutants/")], cfg.root, environment())
            already_ignored = r.code == 0
        except:
            pass
        if already_ignored:
            remove_file(join(self.mdir, ".gitignore"))
        else:
            write_text(join(self.mdir, ".gitignore"), "*\n")
        # the binaries stay: the next run may be able to use them
        for name in list_dir(self.work):
            if name != "bin":
                rmtree(join(self.work, name))
        mkdirs(join(self.work, "bin"))

        var root_real = real_path(cfg.root)
        var to_copy = cfg.paths_to_mutate.copy()
        to_copy.append(cfg.tests_dir)
        for p in cfg.also_copy:
            to_copy.append(p)
        var skip = not_copied()
        for p in to_copy:
            var src = join(cfg.root, p)
            if not path_exists(src):
                raise Error("path does not exist: " + p)
            if real_path(src) == root_real:
                for name in list_dir(src):
                    if name in skip:
                        continue
                    if isdir(join(src, name)):
                        copy_tree(join(src, name), join(self.mdir, name), skip)
                    else:
                        copy_file(join(src, name), join(self.mdir, name))
            elif isdir(src):
                copy_tree(src, join(self.mdir, p), skip)
            else:
                mkdirs(parent(join(self.mdir, p)))
                copy_file(src, join(self.mdir, p))

        var fid = 0
        var number = 1
        for sp in discover_sources(cfg):
            var source = read_text(join(cfg.root, sp.rel))
            var functions: List[Function]
            try:
                functions = analyze(source)
            except e:
                log("warning: skipping " + sp.rel + ": " + String(e))
                continue
            if len(functions) == 0:
                continue
            var lines = source.splitlines(keepends=True)
            var line_list = List[String]()
            for l in lines:
                line_list.append(String(l))
            var first_mutant = number
            var first_fid = fid
            var module = module_name(sp.module_rel)
            for f in functions:
                # a statement is known by its first mutant's number
                var site_of = List[Int]()
                for site in f.sites:
                    var key = number + len(site_of)
                    for _ in range(len(site.mutations)):
                        site_of.append(key if site.hook else -1)
                var index = 1
                for m in f.mutations():
                    var desc = m.describe()
                    self.mutants.append(MutantRecord(
                        module + "." + f.qualname + "." + String(index), number, fid, sp.rel, m.line + 1, m.col + 1,
                        m.end_col + 1, f.qualname, desc, m.original, m.replacement,
                        _fingerprint(line_list, f, desc, m.line), site_of[index - 1],
                    ))
                    number += 1
                    index += 1
                fid += 1
            self.files.append(
                SourceFile(sp.rel, module, source, functions^, first_fid, first_mutant, number - first_mutant, _package_of(sp.module_rel))
            )
        self.n_functions = fid

    # ---- phase 2: build ------------------------------------------------------

    def generate_file(
        self, sf: SourceFile, enabled: Set[Int], disabled_functions: Set[Int], dispatch_only: Set[Int] = Set[Int](),
        hooks: Bool = False,
    ) raises -> GeneratedFile:
        return generate(
            sf.source, sf.functions, sf.first_fid, sf.first_mutant, self.n_functions, len(self.mutants) + 1,
            Optional(enabled.copy()), disabled_functions, dispatch_only, True, hooks,
        )

    def write_schemata(
        self, enabled: Set[Int], disabled_functions: Set[Int], dispatch_only: Set[Int], root: String,
        hooks: Bool = False,
    ) raises -> List[GeneratedFile]:
        """Write the schemata of every source file under `root`; returned in
        the order of `self.files`. With `hooks`, every statement records
        coverage (see `generate`)."""
        var generated = List[GeneratedFile]()
        for sf in self.files:
            var gen = self.generate_file(sf, enabled, disabled_functions, dispatch_only, hooks)
            write_text(join(root, sf.rel), gen.text)
            generated.append(gen^)
        return generated^

    def binary_for(self, test_file: String) -> String:
        var name = test_file.replace("/", "__")
        var stem = String(name[byte = 0 : name.byte_length() - 5]) if name.endswith(".mojo") else name
        return join(join(self.work, "bin"), stem)

    def test_files(self) -> List[String]:
        var seen = Set[String]()
        var files = List[String]()
        for t in self.tests:
            if not (t.file in seen):
                seen.add(t.file)
                files.append(t.file)
        sort(files)
        return files^

    def build_command(self, test_file: String, emit: String, root: String, output_to: String = "") -> Command:
        """`mojo build` of `test_file` in `root` (`self.mdir` for the real
        binaries) to `output_to` (default: see `output_for`); with `emit`
        other than "exe", a check that writes no binary."""
        var cmd = self.mojo.command.copy()
        cmd.append("build")
        # the schemata trigger lots of "unreachable code" warnings
        cmd.append("--disable-warnings")
        for inc in self.config.include_dirs:
            cmd.append("-I")
            cmd.append(inc)
        var output = output_to if output_to.byte_length() else self.output_for(test_file, root)
        if emit != "exe":
            # report every elaboration error, not just the first 20
            cmd.append("--emit")
            cmd.append(emit)
            cmd.append("--elaboration-error-limit=0")
            output = output + ".ll"
        for a in self.config.build_args:
            cmd.append(a)
        cmd.append(test_file)
        cmd.append("-o")
        cmd.append(output)
        return Command(cmd^, root, self.mojo.env.copy(), 0)

    def output_for(self, test_file: String, root: String) -> String:
        """Where the build of `test_file` in `root` goes: the real binaries
        in `self.mdir`, a throwaway in a private copy."""
        if root == self.mdir:
            return self.binary_for(test_file)
        return join(root, ".despell-check-" + test_file.replace("/", "__"))

    def _drop_ir(self, emit: String, root: String, test_file: String):
        """The IR of a check is never read, and can be gigabytes."""
        if emit != "exe":
            remove_file(self.output_for(test_file, root) + ".ll")

    def holds(self, test_file: String, n: Int) -> Bool:
        """Whether the binary of `test_file` holds mutant `n`."""
        if not (n in self.enabled):
            return False
        if test_file in self.file_sets:
            try:
                return n in self.file_sets[test_file]
            except:
                return False
        return True

    def set_for(self, test_file: String, enabled: Set[Int]) -> Set[Int]:
        """The mutants of `enabled` the binary of `test_file` needs."""
        if not (test_file in self.file_sets):
            return enabled.copy()
        var out = Set[Int]()
        try:
            ref reached = self.file_sets[test_file]
            if len(reached) < len(enabled):
                for n in reached:
                    if n in enabled:
                        out.add(n)
            else:
                for n in enabled:
                    if n in reached:
                        out.add(n)
        except:
            pass
        return out^

    def build_all(
        mut self, enabled: Set[Int], disabled_functions: Set[Int], emit: String, test_files: List[String]
    ) raises -> Built:
        """Build the test files (default: all), each with the mutants its
        tests reach. Files that need the same mutants share a copy of the
        project to build in: `self.mdir` for the first, the others under
        work/trees."""
        self.n_builds += 1
        var files = test_files.copy() if len(test_files) > 0 else self.test_files()
        var keys = List[String]()
        var sets = List[Set[Int]]()
        var groups = List[_Group]()
        for f in files:
            var s = self.set_for(f, enabled)
            var key = _set_key(s)
            var g = -1
            for k in range(len(keys)):
                if keys[k] == key:
                    g = k
            if g < 0:
                g = len(keys)
                keys.append(key)
                sets.append(s^)
                var root = self.mdir if g == 0 else join(join(self.work, "trees"), String(g))
                groups.append(_Group(root, List[String](), List[GeneratedFile]()))
            groups[g].files.append(f)
        var commands = List[Command]()
        for g in range(len(groups)):
            var root = groups[g].root
            if root != self.mdir and not is_dir(root):
                var skip = not_copied()
                for name in [WORK_DIR, STATE_FILE, STATE_LOCK, MAIN_LOCK, SIDE_DIR]:
                    skip.append(String(name))
                copy_tree(self.mdir, root, skip)
            groups[g].generated = self.write_schemata(sets[g], disabled_functions, Set[Int](), root, True)
            for f in groups[g].files:
                var out = self.binary_for(f) if emit == "exe" else self.output_for(f, root)
                commands.append(self.build_command(f, emit, root, out))
        var results = run_parallel(commands, self.workers)
        var failures = List[Failure]()
        var c = 0
        for g in range(len(groups)):
            for f in groups[g].files:
                self._drop_ir(emit, groups[g].root, f)
                if results[c].code != 0:
                    failures.append(Failure(f, results[c].output, g))
                c += 1
        return Built(groups^, failures^)

    def find_mojo(mut self) raises:
        if not self.have_mojo:
            self.mojo = find_mojo(self.config)
            self.have_mojo = True

    def begin_build(mut self, previous: Dict[String, MutantRecord], only: Optional[Set[Int]]) raises:
        """Settle what to build: the `only` mutants (default: all of them),
        less what didn't compile last time and hasn't changed since."""
        self.find_mojo()
        self.build_t0 = monotonic_ns()
        self.n_builds = 0
        var enabled = Set[Int]()
        if only:
            enabled = only.value().copy()
        else:
            for m in self.mutants:
                enabled.add(m.number)
        var disabled_functions = Set[Int]()
        for i in range(len(self.mutants)):
            ref m = self.mutants[i]
            var old = previous.get(m.id)
            if old and old.value().fingerprint == m.fingerprint and (old.value().status == COMPILE_ERROR or old.value().status == SKIPPED):
                if old.value().status == SKIPPED:
                    disabled_functions.add(m.fid)
                enabled.discard(m.number)
                m.status = old.value().status
                m.detail = old.value().detail
        self.enabled = enabled^
        self.disabled_functions = disabled_functions^

    def coverage_build(mut self, files: List[String]) raises:
        """Build `files` with coverage hooks and no mutants, to learn what
        their tests reach before building them with mutants. Functions that
        can't hold the hooks are found on the way."""
        # binaries get overwritten from here on
        remove_file(join(join(self.work, "bin"), MANIFEST))
        var none = Set[Int]()
        var disabled = self.disabled_functions.copy()
        self.converge(none, disabled, "exe", False, files)
        self.disabled_functions = disabled^

    def finish_build(mut self, previous: Dict[String, MutantRecord]) raises:
        """Build the test binaries, each with the mutants its tests reach
        (all of them where that isn't known).

        Mutants that don't compile are found while checking with `--emit llvm`,
        which stops before LLVM optimization and codegen (the bulk of a build)
        but still runs elaboration, where many mutants fail.
        """
        var enabled = Set[Int]()
        var disabled_functions = self.disabled_functions.copy()
        for n in self.enabled:
            if self.mutants[n - 1].status != SKIPPED:
                enabled.add(n)

        var t0 = self.build_t0
        var manifest = join(join(self.work, "bin"), MANIFEST)
        if self._reuse(enabled, disabled_functions, manifest):
            self.enabled = enabled^
            log(
                "reusing the last build's test binaries (" + String(len(self.test_files())) + " test files): they hold "
                + "these mutants, and nothing they were built from has changed"
            )
            return
        # binaries get overwritten from here on
        remove_file(manifest)
        # the pre-check can only reject mutants: the ones that compiled in an
        # earlier build, unchanged since, don't need it
        var unknown = Set[Int]()
        for n in enabled:
            ref m = self.mutants[n - 1]
            var old = previous.get(m.id)
            if not (old and old.value().fingerprint == m.fingerprint and (old.value().compiles or is_final(old.value().status))):
                unknown.add(n)
        var t_pre0 = monotonic_ns()
        self.precheck(unknown, disabled_functions)
        var still = Set[Int]()
        for n in enabled:
            if self.mutants[n - 1].status != COMPILE_ERROR:
                self.mutants[n - 1].compiles = True
                still.add(n)
        enabled = still^
        var t_pre = seconds_since(t_pre0)
        # Mutants no test reaches are pre-checked (a compile error is worth
        # knowing before writing a test for one) but not built
        var everywhere = True
        for f in self.test_files():
            if not (f in self.file_sets):
                everywhere = False
        if everywhere:
            var reached = Set[Int]()
            for f in self.test_files():
                for n in self.set_for(f, enabled):
                    reached.add(n)
            enabled = reached^
        var t_check0 = monotonic_ns()
        self.converge(enabled, disabled_functions, "llvm", True)
        var t1 = seconds_since(t_check0) + t_pre
        var built = self.build_all(enabled, disabled_functions, "exe", List[String]())
        if len(built.failures) > 0:
            # rare: rejected only by the LLVM backend
            self.converge(enabled, disabled_functions, "exe", True)
        self.enabled = enabled^
        self.disabled_functions = disabled_functions^
        self._write_manifest(manifest)
        var rejected = 0
        for m in self.mutants:
            if m.status == COMPILE_ERROR or m.status == SKIPPED:
                rejected += 1
        log(
            "built " + String(len(self.test_files())) + " test binaries in " + format_seconds(seconds_since(t0))
            + "s (" + String(self.n_builds) + " builds; checking mutants took " + format_seconds(t1)
            + "s, of which " + format_seconds(t_pre) + "s pre-checking modules; " + String(rejected) + " rejected)"
        )

    def _build_key(mut self, disabled_functions: List[Int]) raises -> String:
        """A hash of what the binaries are built from, besides the test files
        and the mutants in them: despell itself, the code, shared test code,
        the build command."""
        if self._generator.byte_length() == 0:
            self._generator = hash_bytes(read_bytes(executable_path()))
        var h = Hasher()
        h.update(self._generator)
        h.update(self.test_hashes.get("sources", ""))
        h.update(self.test_hashes.get("*", ""))
        for a in self.build_command(String("-"), String("exe"), self.mdir).argv:
            h.update(a)
        for d in disabled_functions:
            h.update(String(d))
        return h.hex()

    def _write_manifest(mut self, path: String) raises:
        var disabled = _sorted(self.disabled_functions)
        var files = Json.object()
        for f in self.test_files():
            var entry = Json.object()
            entry.set("test", Json.of(self.test_hashes.get(f, "")))
            entry.set("enabled", Json.ints(_sorted(self.set_for(f, self.enabled))))
            files.set(f, entry^)
        var j = Json.object()
        j.set("key", Json.of(self._build_key(disabled)))
        j.set("disabled_functions", Json.ints(disabled))
        j.set("files", files^)
        write_text(path, encode(j))

    def _reuse(mut self, enabled: Set[Int], disabled_functions: Set[Int], path: String) -> Bool:
        """Whether the binaries of the last build can run the `enabled`
        mutants: each holds what its tests need, and neither despell, the
        code, the test files nor the build command have changed."""
        try:
            if not is_file(path):
                return False
            var j = parse(read_text(path))
            if self._build_key(j.int_list("disabled_functions")) != j.str_or("key", ""):
                return False
            var files = j.get("files")
            for f in self.test_files():
                if not files.has(f) or not is_file(self.binary_for(f)):
                    return False
                var entry = files.get(f)
                if entry.str_or("test", "") != self.test_hashes.get(f, "-"):
                    return False
                var held = Set[Int]()
                for n in entry.int_list("enabled"):
                    held.add(n)
                for n in self.set_for(f, enabled):
                    if not (n in held):
                        return False
            return True
        except:
            return False

    def disable_function(mut self, fid: Int, detail: String, mut enabled: Set[Int], mut disabled_functions: Set[Int]):
        disabled_functions.add(fid)
        for i in range(len(self.mutants)):
            if self.mutants[i].fid == fid:
                enabled.discard(self.mutants[i].number)
                self.mutants[i].status = SKIPPED
                self.mutants[i].detail = detail

    def reject(mut self, n: Int, detail: String, mut enabled: Set[Int]):
        enabled.discard(n)
        self.mutants[n - 1].status = COMPILE_ERROR
        self.mutants[n - 1].detail = detail

    def numbers(self, sf: SourceFile) -> List[Int]:
        var out = List[Int]()
        for n in range(sf.first_mutant, sf.first_mutant + sf.n_mutants):
            out.append(n)
        return out^

    # ---- the pre-check -------------------------------------------------------

    def _check_command(self, path: String) -> Command:
        var cmd = self.mojo.command.copy()
        for a in ["build", "--disable-warnings", "--emit", "llvm", "--elaboration-error-limit=0"]:
            cmd.append(String(a))
        for inc in self.config.include_dirs:
            cmd.append("-I")
            cmd.append(inc)
        for a in self.config.build_args:
            cmd.append(a)
        cmd.append(path)
        cmd.append("-o")
        cmd.append(path + ".ll")
        # imports resolve against the original project, so each module is
        # checked with its own mutants and no one else's
        return Command(cmd^, self.config.root, self.mojo.env.copy(), 0)

    def _chains(self, output: String, checked: String) -> List[List[_Frame]]:
        """The error chains in a check's output: each error and its notes,
        with where each frame is."""
        var project_files = Set[String]()
        for sf in self.files:
            project_files.add(join(self.config.root, sf.rel))
        var chains = List[List[_Frame]]()
        for d in parse_diagnostics(output):
            if d.is_error:
                chains.append(List[_Frame]())
            if len(chains) == 0:
                continue
            var path = d.path if d.path.startswith("/") else join(self.config.root, d.path)
            var where = 0 if path == checked else (1 if path in project_files else 2)
            chains[len(chains) - 1].append(_Frame(where, d.line, d.message))
        return chains^

    def precheck(mut self, mut enabled: Set[Int], disabled_functions: Set[Int]) raises:
        """Find compile errors fast by checking each mutated module on its own.

        Mojo only type-checks function bodies that are referenced, except in
        the file being compiled, where it checks everything. So compiling each
        module as its own entry point checks all of its mutants while touching
        only what it imports, in parallel and much faster than the test builds.
        That needs relative imports made absolute. Imports come from the
        original project: a mutant that breaks an imported module would stop
        the build before it gets to instantiating anything. Errors that only
        show when generic code is instantiated (a `comptime assert` in the
        stdlib, say) need the functions instantiated, so every function is
        marked `@export` (see `add_exports`). Checking a module this way
        reports some errors normal builds never see (code nothing references,
        a type existing twice, a function that can't be exported), so the
        unmutated module is checked first: functions that can't be exported
        aren't, and statements that fail without mutants are left alone.
        """
        var todo = List[Int]()  # indices into self.files
        for i in range(len(self.files)):
            for n in self.numbers(self.files[i]):
                if n in enabled:
                    todo.append(i)
                    break
        if len(todo) == 0:
            return
        var t0 = monotonic_ns()
        var check_dir = join(self.work, "check")
        mkdirs(check_dir)

        # the unmutated modules: which exports fail, and which lines
        var skips = Dict[Int, Set[Int]]()
        var baseline = Dict[Int, Set[Int]]()
        var pending = todo.copy()
        for _ in range(10):
            if len(pending) == 0:
                break
            var commands = List[Command]()
            var exported = List[Exported]()
            var paths = List[String]()
            for i in pending:
                ref sf = self.files[i]
                var ex = add_exports(sf.source, skips.get(i, Set[Int]()))
                var path = join(check_dir, sf.module + ".orig.mojo")
                write_text(path, absolutize_imports(ex.text, sf.package))
                commands.append(self._check_command(path))
                exported.append(ex^)
                paths.append(path)
            var results = run_parallel(commands, self.workers)
            var again = List[Int]()
            for k in range(len(pending)):
                remove_file(paths[k] + ".ll")
                var i = pending[k]
                var lines = Set[Int]()
                var failing = Set[Int]()
                for chain in self._chains(results[k].output, paths[k]):
                    var line = _culprit(chain)
                    if line >= 0:
                        lines.add(exported[k].original_line(line))
                        if line in exported[k].by_line:
                            failing.add(exported[k].by_line[line])
                baseline[i] = lines^
                if len(failing) > 0:
                    var skip = skips.get(i, Set[Int]())
                    for f in failing:
                        skip.add(f)
                    skips[i] = skip^
                    again.append(i)
            pending = again^

        var rejected = 0
        var round_no = 0
        var round_log = String("")
        while len(todo) > 0 and round_no < 100:
            round_no += 1
            var t_round = monotonic_ns()
            # Mojo reports one instantiation error per function, so a module
            # can take a round per bad mutant. When few modules are left,
            # their mutants are split over several checks to find more at once.
            var parts = max(1, self.workers // len(todo))
            var job_files = List[Int]()
            var job_subsets = List[Set[Int]]()
            var job_paths = List[String]()
            var job_generated = List[GeneratedFile]()
            var job_exported = List[Exported]()
            var commands = List[Command]()
            for i in todo:
                var mine = List[Int]()
                for n in self.numbers(self.files[i]):
                    if n in enabled:
                        mine.append(n)
                var k = max(1, min(parts, len(mine)))
                for j in range(k):
                    var subset = Set[Int]()
                    var idx = j
                    while idx < len(mine):
                        subset.add(mine[idx])
                        idx += k
                    ref sf = self.files[i]
                    var gen = self.generate_file(sf, subset, disabled_functions)
                    var ex = add_exports(gen.text, skips.get(i, Set[Int]()))
                    var suffix = ".p" + String(j) if k > 1 else String("")
                    var path = join(check_dir, sf.module + suffix + ".mojo")
                    write_text(path, absolutize_imports(ex.text, sf.package))
                    commands.append(self._check_command(path))
                    job_files.append(i)
                    job_subsets.append(subset^)
                    job_paths.append(path)
                    job_generated.append(gen^)
                    job_exported.append(ex^)
            var results = run_parallel(commands, self.workers)
            var found_in = Dict[Int, Int]()
            for k in range(len(commands)):
                remove_file(job_paths[k] + ".ll")
                var i = job_files[k]
                var found = 0
                for chain in self._chains(results[k].output, job_paths[k]):
                    var line = _culprit(chain)
                    if line < 0:
                        continue
                    line = job_exported[k].original_line(line)
                    var mutant = -1
                    var orig_start = -1
                    var orig_end = -1
                    for r in job_generated[k].regions:
                        if r.mutant >= 0 and r.start <= line and line <= r.end:
                            mutant = r.mutant
                            orig_start = r.orig_start
                            orig_end = r.orig_end
                            break
                    if mutant < 0 or not (mutant in enabled) or not (mutant in job_subsets[k]):
                        continue
                    # the statement fails without the mutant too: not the mutant's fault
                    var in_baseline = False
                    for b in baseline.get(i, Set[Int]()):
                        if orig_start <= b and b <= orig_end:
                            in_baseline = True
                    if in_baseline:
                        continue
                    var instantiation = chain[0].message.startswith("function instantiation failed")
                    self.reject(mutant, chain[len(chain) - 1].message if instantiation else chain[0].message, enabled)
                    found += 1
                found_in[i] = found_in.get(i, 0) + found
            # errors hidden behind the ones just found may surface now
            var next_todo = List[Int]()
            var n_found = 0
            var who = String("")
            for i in todo:
                var f = found_in.get(i, 0)
                if f > 0:
                    next_todo.append(i)
                    n_found += f
                    who += " " + self.files[i].rel + "=" + String(f)
            todo = next_todo^
            rejected += n_found
            round_log += (
                "round " + String(round_no) + ": " + String(len(commands)) + " checks in "
                + format_seconds(seconds_since(t_round)) + "s: " + String(n_found) + " rejected" + who + "\n"
            )
        mkdirs(join(self.work, "logs"))
        write_text(join(join(self.work, "logs"), "precheck.txt"), round_log)
        log(
            "pre-checked " + String(len(skips) if len(skips) > len(baseline) else len(baseline)) + " modules in "
            + format_seconds(seconds_since(t0)) + "s (" + String(round_no) + " rounds): " + String(rejected)
            + " mutants don't compile"
        )

    # ---- build attempts ------------------------------------------------------

    def converge(
        mut self, mut enabled: Set[Int], mut disabled_functions: Set[Int], emit: String, recheck: Bool,
        files: List[String] = List[String](),
    ) raises:
        """Remove mutants from `enabled` until the build passes.

        An error located in a mutant's own lines condemns that mutant. Vaguer
        errors (in a statement holding several mutants, reported for a whole
        function, or without a location) only make their mutants suspects:
        they're set aside, and once the rest builds, checked one by one.
        """
        var suspects = List[Suspects]()
        # Taking mutants out never breaks a build that passed, so after the
        # first attempt only the test files that failed are built again.
        var test_files = files.copy()
        var attempt = 0
        while True:
            attempt += 1
            if attempt > 1000:
                raise Error("gave up after too many build attempts")
            var t0 = monotonic_ns()
            var built = self.build_all(enabled, disabled_functions, emit, test_files)
            if len(built.failures) == 0:
                break
            test_files = List[String]()
            var logs = join(self.work, "logs")
            mkdirs(logs)
            for f in built.failures:
                test_files.append(f.file)
                var stem = f.file[byte = f.file.rfind("/") + 1 :]
                write_text(join(logs, "attempt" + String(attempt) + "-" + emit + "-" + String(stem) + ".txt"), f.output)
            var hits = self.attribute_errors(built)
            var dropped = 0
            for item in hits.mutants.items():
                if item.key in enabled:
                    self.reject(item.key, item.value, enabled)
                    dropped += 1
            var set_aside = 0
            var n_disabled = 0
            var why = String("")
            if dropped == 0:
                var groups = List[Suspects]()
                if len(hits.sites) > 0:
                    var messages = List[String]()
                    for k in range(len(hits.sites)):
                        var group = List[Int]()
                        for n in hits.sites[k]:
                            if n in enabled:
                                group.append(n)
                        groups.append(Suspects(group^, -1, test_files.copy()))
                        if len(messages) < 3:
                            messages.append(String(hits.site_messages[k][byte = 0 : min(80, hits.site_messages[k].byte_length())]))
                    why = "errors in statements holding several mutants: " + join_words(messages, "; ")
                elif len(hits.functions) > 0:
                    for fid in hits.functions:
                        var group = List[Int]()
                        for n in enabled:
                            if self.mutants[n - 1].fid == fid:
                                group.append(n)
                        if len(group) == 0:
                            # nothing of it is in the build but coverage hooks
                            self.disable_function(fid, "function can't hold despell's coverage hooks", enabled, disabled_functions)
                            n_disabled += 1
                            continue
                        groups.append(Suspects(group^, fid, test_files.copy()))
                    why = "errors pointing at " + String(len(hits.functions)) + " whole functions"
                else:
                    var group = List[Int]()
                    for n in enabled:
                        group.append(n)
                    groups.append(Suspects(group^, -1, test_files.copy()))
                    var e = first_error(built.failures[0].output)
                    why = "errors without a location: " + String(e[byte = 0 : min(80, e.byte_length())])
                for g in groups:
                    for n in g.group:
                        enabled.discard(n)
                    set_aside += len(g.group)
                    if len(g.group) > 0:
                        suspects.append(g.copy())
                if set_aside == 0 and n_disabled == 0:
                    raise Error(
                        "building " + built.failures[0].file + " fails without any mutants:\n"
                        + without_warnings(built.failures[0].output)
                    )
            log(
                "build attempt " + String(attempt) + " (" + format_seconds(seconds_since(t0)) + "s): "
                + String(dropped) + " mutants don't compile"
                + (", " + String(n_disabled) + " functions can't hold coverage hooks" if n_disabled else String(""))
                + (", set aside " + String(set_aside) + " suspects (" + why + ")" if set_aside else String(""))
            )
        if len(suspects) > 0 and recheck:
            self.check_suspects(suspects, enabled, disabled_functions, emit)
            # each was checked alone with one test file; check them all together
            self.converge(enabled, disabled_functions, emit, False)
        elif len(suspects) > 0:
            # set aside again after passing on their own: they only fail together
            for s in suspects:
                for n in s.group:
                    self.reject(n, "doesn't compile together with other mutants", enabled)

    def _slot_builds(
        mut self, items: List[Set[Int]], dispatch_only: List[Set[Int]], files: List[List[String]], disabled_functions: Set[Int], emit: String
    ) raises -> List[String]:
        """Build each item (its enabled mutants, functions to dispatch, test
        files) in a private copy of the project, `workers` at a time. Returns
        the compiler output of each failed build, "" for each success."""
        var results = List[String]()
        var start = 0
        while start < len(items):
            var end = min(start + self.workers, len(items))
            var commands = List[Command]()
            var owners = List[Int]()
            for k in range(start, end):
                var slot = join(join(self.work, "slots"), String(k - start))
                if not is_dir(slot):
                    var skip = not_copied()
                    skip.append(String(WORK_DIR))
                    skip.append(String(STATE_FILE))
                    skip.append(String(SIDE_DIR))
                    copy_tree(self.mdir, slot, skip)
                _ = self.write_schemata(items[k], disabled_functions, dispatch_only[k], slot)
                self.n_builds += 1
                for f in files[k]:
                    commands.append(self.build_command(f, emit, slot))
                    owners.append(k)
            # every test file at once: a later one failing is as good as the first
            var outs = run_parallel(commands, self.workers)
            for k in range(start, end):
                var failed = String("")
                for c in range(len(commands)):
                    if owners[c] == k and outs[c].code != 0 and failed.byte_length() == 0:
                        failed = outs[c].output if outs[c].output.byte_length() else String("build failed")
                results.append(failed)
            for c in range(len(commands)):
                var slot = join(join(self.work, "slots"), String(owners[c] - start))
                self._drop_ir(emit, slot, commands[c].argv[len(commands[c].argv) - 3])
            start = end
        return results^

    def check_suspects(mut self, suspects: List[Suspects], mut enabled: Set[Int], mut disabled_functions: Set[Int], emit: String) raises:
        """Check set-aside mutants one at a time.

        Each check builds a single mutant and nothing else, with only the test
        file whose build failed. That's a small program, and since nothing
        else is in it, a failure can only be that mutant's fault.
        """
        var t0 = monotonic_ns()
        var before = self.n_builds
        var n_suspects = 0
        for s in suspects:
            n_suspects += len(s.group)

        # first: can each implicated function hold the dispatch at all? (not if
        # it's evaluated at compile time, say)
        var fids = List[Int]()
        var items = List[Set[Int]]()
        var dispatch = List[Set[Int]]()
        var files = List[List[String]]()
        for s in suspects:
            if s.fid >= 0:
                fids.append(s.fid)
                items.append(Set[Int]())
                var d = Set[Int]()
                d.add(s.fid)
                dispatch.append(d^)
                files.append(s.files.copy())
        var outs = self._slot_builds(items, dispatch, files, disabled_functions, emit)
        for k in range(len(fids)):
            if outs[k].byte_length():
                self.disable_function(fids[k], "function can't be mutated with schemata: " + first_error(outs[k]), enabled, disabled_functions)

        var singles = List[Int]()
        items = List[Set[Int]]()
        dispatch = List[Set[Int]]()
        files = List[List[String]]()
        for s in suspects:
            var group = s.group.copy()
            sort(group)
            for n in group:
                if not (self.mutants[n - 1].fid in disabled_functions):
                    singles.append(n)
                    var one = Set[Int]()
                    one.add(n)
                    items.append(one^)
                    dispatch.append(Set[Int]())
                    files.append(s.files.copy())
        outs = self._slot_builds(items, dispatch, files, disabled_functions, emit)
        var bad = 0
        for k in range(len(singles)):
            if outs[k].byte_length() == 0:
                enabled.add(singles[k])
            else:
                self.reject(singles[k], first_error(outs[k]), enabled)
                bad += 1
        log(
            "checked " + String(n_suspects) + " suspects one by one in " + String(self.n_builds - before)
            + " builds (" + format_seconds(seconds_since(t0)) + "s): " + String(bad) + " don't compile"
        )

    def attribute_errors(self, built: Built) -> Hits:
        """Map compiler errors to mutants, statements and functions.

        An error is followed by notes. For "function instantiation failed" the
        notes are the chain of instantiations from `main` down to where it
        failed, so the deepest one in our code is the culprit: a mutant's line
        when the failure is in code it calls (a SIMD width of 33, say), or the
        `def` of the function holding the bad mutant. The "call expansion
        failed" notes on the way point at callers, which aren't to blame.
        Linker errors have no location, but name the functions referencing
        a missing symbol.
        """
        var hits = Hits()
        var fids = Dict[String, Int]()
        for m in self.mutants:
            fids[String(m.id[byte = 0 : m.id.rfind(".")])] = m.fid
        var seen_sites = Set[String]()
        for f in built.failures:
            ref group = built.groups[f.group]
            var root = group.root
            var file_index = Dict[String, Int]()
            for i in range(len(self.files)):
                file_index[join(root, self.files[i].rel)] = i
            var chains = List[List[Diagnostic]]()
            for d in parse_diagnostics(f.output):
                if d.is_error:
                    chains.append(List[Diagnostic]())
                if len(chains) > 0:
                    chains[len(chains) - 1].append(d.copy())
            for chain in chains:
                var error_msg = chain[0].message
                var candidates = List[Diagnostic]()
                if error_msg.startswith("function instantiation failed"):
                    for k in range(len(chain) - 1, -1, -1):  # deepest first
                        candidates.append(chain[k].copy())
                else:
                    # the error's own location; failing that, a note in our code
                    candidates.append(chain[0].copy())
                    for k in range(1, len(chain)):
                        if not chain[k].message.startswith("call expansion failed") and not chain[k].message.startswith("function instantiation"):
                            candidates.append(chain[k].copy())
                for d in candidates:
                    var path = d.path if d.path.startswith("/") else join(root, d.path)
                    if not (path in file_index):
                        continue
                    ref regions = group.generated[file_index.get(path, 0)].regions
                    var best = -1
                    for r in range(len(regions)):
                        if regions[r].start <= d.line and d.line <= regions[r].end:
                            if best < 0 or (regions[r].mutant >= 0 and regions[best].mutant < 0) or (
                                (regions[r].mutant >= 0) == (regions[best].mutant >= 0)
                                and regions[r].end - regions[r].start < regions[best].end - regions[best].start
                            ):
                                best = r
                    if best < 0:
                        continue
                    ref region = regions[best]
                    if region.mutant >= 0:
                        if not (region.mutant in hits.mutants):
                            hits.mutants[region.mutant] = error_msg
                    elif len(region.site) > 0:
                        var key = String("")
                        for n in region.site:
                            key += String(n) + ","
                        if not (key in seen_sites):
                            seen_sites.add(key)
                            hits.sites.append(region.site.copy())
                            hits.site_messages.append(error_msg)
                    else:
                        hits.functions.add(region.fid)
                    break
            for symbol in link_references(f.output):
                var name = symbol.replace("::", ".")
                if name in fids:
                    hits.functions.add(fids.get(name, -1))
        return hits^


struct Hits(Movable):
    var mutants: Dict[Int, String]
    var sites: List[List[Int]]
    var site_messages: List[String]
    var functions: Set[Int]

    def __init__(out self):
        self.mutants = Dict[Int, String]()
        self.sites = List[List[Int]]()
        self.site_messages = List[String]()
        self.functions = Set[Int]()


def _culprit(chain: List[_Frame]) -> Int:
    """The line in the checked module to blame for an error, or -1."""
    if chain[0].message.startswith("function instantiation failed"):
        # deepest frame in the project's code; if that's in another module,
        # the error is that module's to report
        for k in range(len(chain) - 1, -1, -1):
            if chain[k].where == 0:
                return chain[k].line
            if chain[k].where == 1:
                return -1
        return -1
    return chain[0].line if chain[0].where == 0 else -1
