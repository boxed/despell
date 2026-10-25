"""Orchestrates a mutation testing run.

Phases:
1. copy the project into ./mutants and write mutation schemata over the sources
2. build each test file into a binary; mutants the compiler rejects are dropped
   and the build is retried until it succeeds
3. run every test once with DESPELL_MUTANT=-1, which runs the original code but
   records which functions each test reaches (and checks the suite is green)
4. run each mutant against the tests that reach its function
"""

from __future__ import annotations

import bisect
import fnmatch
import hashlib
import json
import queue
import re
import shutil
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, dataclass, field
from pathlib import Path

from .mutation import GeneratedFile, analyze, generate
from .project import Config, MojoEnv, find_mojo
from .tokenizer import TokenizeError, tokenize

STATE_FILE = "despell.json"
WORK_DIR = ".despell"
STATS_MODE = "-1"
# version control, environments and caches: big, and no test reads them
NOT_COPIED = (
    "mutants", ".git", ".hg", ".jj", ".svn", ".pixi", ".venv", ".magic",
    "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".DS_Store",
)

KILLED = "killed"
SURVIVED = "survived"
NO_TESTS = "no_tests"
TIMEOUT = "timeout"
COMPILE_ERROR = "compile_error"
SKIPPED = "skipped"
NOT_CHECKED = "not_checked"

STATUS_ORDER = [SURVIVED, NO_TESTS, TIMEOUT, NOT_CHECKED, SKIPPED, COMPILE_ERROR, KILLED]
# Statuses an agent should act on
ACTIONABLE = {SURVIVED, NO_TESTS}


class RunError(Exception):
    pass


@dataclass
class MutantRecord:
    id: str
    number: int
    fid: int
    file: str  # path relative to project root
    line: int  # 1-based
    col: int  # 1-based
    end_col: int  # 1-based, exclusive
    function: str
    description: str
    original: str
    replacement: str
    fingerprint: str
    status: str = NOT_CHECKED
    killed_by: str | None = None
    detail: str | None = None
    # the statement holding the mutant, for coverage (None: use the function's)
    site: int | None = None


@dataclass
class TestRecord:
    id: str  # "<test file>::<test name>"
    file: str
    name: str | None  # None when the test file isn't a TestSuite
    binary: str = ""
    duration: float = 0.0
    functions: list[int] = field(default_factory=list)
    sites: list[int] = field(default_factory=list)


@dataclass
class SourceFile:
    rel: str
    module: str
    source: str
    functions: list
    first_fid: int
    first_mutant: int
    package: tuple[str, ...]  # the package the module is in, for relative imports


def log(msg: str):
    print(msg, flush=True)


def module_name(rel_to_root: Path) -> str:
    parts = list(rel_to_root.with_suffix("").parts)
    if parts and parts[-1] == "__init__":
        parts = parts[:-1]
    return ".".join(parts) or "__root__"


def _is_relative_to(p: Path, other: Path) -> bool:
    try:
        p.relative_to(other)
        return True
    except ValueError:
        return False


def discover_sources(config: Config) -> list[tuple[Path, Path]]:
    """Returns (path relative to project root, path relative to its include dir)."""
    root = config.root
    tests = (root / config.tests_dir).resolve()
    mutants = config.mutants_dir.resolve()
    result = []
    for base in config.paths_to_mutate:
        base_path = root / base
        candidates = [base_path] if base_path.is_file() else sorted(base_path.rglob("*.mojo"))
        for path in candidates:
            resolved = path.resolve()
            if _is_relative_to(resolved, tests) or _is_relative_to(resolved, mutants):
                continue
            if any(part.startswith(".") for part in path.relative_to(root).parts):
                continue
            rel = path.relative_to(root)
            if any(fnmatch.fnmatch(str(rel), pattern) for pattern in config.do_not_mutate):
                continue
            # module names are relative to the include dir that contains the file
            module_rel = rel
            for inc in config.include_dirs:
                if _is_relative_to(resolved, (root / inc).resolve()):
                    module_rel = resolved.relative_to((root / inc).resolve())
                    break
            result.append((rel, module_rel))
    return result


def discover_tests(config: Config) -> list[TestRecord]:
    tests_root = config.root / config.tests_dir
    records = []
    for path in sorted(tests_root.rglob("*.mojo")):
        if not path.name.startswith("test"):
            continue
        rel = str(path.relative_to(config.root))
        source = path.read_text()
        names = []
        try:
            for ll in tokenize(source).logical_lines:
                toks = ll.tokens
                if ll.indent == 0 and len(toks) > 1 and toks[0].text == "def" and toks[1].text.startswith("test_"):
                    names.append(toks[1].text)
        except TokenizeError:
            pass
        if names and "TestSuite" in source:
            records.extend(TestRecord(id=f"{rel}::{n}", file=rel, name=n) for n in names)
        else:
            records.append(TestRecord(id=rel, file=rel, name=None))
    return records


def _fingerprint(source_lines: list[str], f, description: str, line: int) -> str:
    body = "".join(source_lines[f.def_line : f.body_end + 1])
    return hashlib.sha256(f"{body}\0{description}\0{line}".encode()).hexdigest()[:16]


def _without_warnings(compiler_output: str) -> str:
    """Drop warning diagnostics (and their source excerpts) from compiler output."""
    kept: list[str] = []
    pending: list[str] = []  # "Included from" lines that precede a diagnostic
    keep = True
    for line in compiler_output.splitlines():
        if line.startswith(("Included from", "Imported from")):
            pending.append(line)
            continue
        m = re.match(r"^\S.*?:\d+:\d+: (error|warning|note):", line)
        if m:
            keep = m.group(1) != "warning"
        elif not line.startswith(" ") and line.strip():
            keep = True
        if keep:
            kept.extend(pending)
            kept.append(line)
        pending = []
    return "\n".join(kept)


def _first_error(compiler_output: str) -> str:
    for line in compiler_output.splitlines():
        if " error: " in line and not line.rstrip().endswith("failed to run the pass manager"):
            return line.split(" error: ", 1)[1].strip()
    return "build failed"


_RELATIVE_IMPORT = re.compile(r"^(\s*from\s+)(\.+)([\w.]*)(\s+import\b)", re.MULTILINE)


def absolutize_imports(text: str, package: tuple[str, ...]) -> str:
    """Rewrite `from .x import y` to `from pkg.x import y`, given the module's package."""

    def sub(m: re.Match) -> str:
        up = len(m.group(2)) - 1
        base = list(package[: len(package) - up] if up else package)
        target = ".".join(base + ([m.group(3)] if m.group(3) else []))
        return f"{m.group(1)}{target}{m.group(4)}" if target else m.group(0)

    return _RELATIVE_IMPORT.sub(sub, text)


@dataclass
class Exported:
    """A module with its functions marked `@export`, for the pre-check."""

    text: str
    inserted: list[int]  # lines of the inserted decorators, ascending
    by_line: dict[int, int]  # decorator line and def line -> function ordinal

    def original_line(self, line: int) -> int:
        """Line number in the text before the decorators were inserted."""
        return line - bisect.bisect_left(self.inserted, line)


def add_exports(text: str, skip: set[int]) -> Exported:
    """Mark every function `@export`, except the ordinals in `skip`.

    Mojo only instantiates what's reachable from `main` and exported
    functions, and stops at the first failure under each of them. Exporting
    every function makes each one its own root, so a single build reports an
    instantiation error for every function that has one. Functions are
    numbered by the order of their `def`s, leaving out despell's own, so the
    numbers match between the original and the generated module.
    """
    lines = text.splitlines(keepends=True)
    defs = []
    for ll in tokenize(text).logical_lines:
        t = ll.tokens
        if len(t) > 1 and t[0].text == "def" and not t[1].text.startswith("_despell"):
            defs.append(ll.first_line)
    out = []
    inserted = []
    by_line = {}
    prev = 0
    for ordinal, def_line in enumerate(defs):
        out += lines[prev:def_line]
        prev = def_line
        if ordinal in skip:
            continue
        indent = lines[def_line][: len(lines[def_line]) - len(lines[def_line].lstrip())]
        inserted.append(len(out))
        by_line[len(out)] = ordinal
        by_line[len(out) + 1] = ordinal
        out.append(f'{indent}@export("despell_x_{ordinal}")\n')
    out += lines[prev:]
    return Exported("".join(out), inserted, by_line)


class Run:
    def __init__(self, config: Config, *, workers: int):
        self.config = config
        self.workers = workers
        self.mdir = config.mutants_dir
        self.work = self.mdir / WORK_DIR
        self.mojo: MojoEnv | None = None
        self.files: list[SourceFile] = []
        self.mutants: dict[int, MutantRecord] = {}
        self.tests: list[TestRecord] = []
        self.n_functions = 0
        self.n_builds = 0
        self._slots: queue.Queue[int] = queue.Queue()
        for i in range(workers):
            self._slots.put(i)

    # ---- phase 1: generation -------------------------------------------------

    def prepare(self):
        cfg = self.config
        if self.mdir.exists():
            for child in self.mdir.iterdir():
                # an editor's environment in here is expensive to recreate,
                # and something else may be writing to it (Finder, say)
                if child.name in (STATE_FILE, WORK_DIR) or child.name in NOT_COPIED:
                    continue
                if child.is_dir():
                    shutil.rmtree(child, ignore_errors=True)
                else:
                    child.unlink(missing_ok=True)
        self.mdir.mkdir(exist_ok=True)
        # keep mutants/ out of git, unless the project already does: tests
        # that honor .gitignore (a file tree, say) would see an empty project
        try:
            already_ignored = subprocess.run(
                ["git", "check-ignore", "-q", "mutants/"], cwd=cfg.root, capture_output=True
            ).returncode == 0
        except FileNotFoundError:
            already_ignored = False
        if already_ignored:
            (self.mdir / ".gitignore").unlink(missing_ok=True)
        else:
            (self.mdir / ".gitignore").write_text("*\n")
        if self.work.exists():
            shutil.rmtree(self.work)
        (self.work / "bin").mkdir(parents=True)

        ignore = shutil.ignore_patterns(*NOT_COPIED)
        for p in [*cfg.paths_to_mutate, cfg.tests_dir, *cfg.also_copy]:
            src = cfg.root / p
            dst = self.mdir / p
            if not src.exists():
                raise RunError(f"path does not exist: {p}")
            if src.resolve() == cfg.root.resolve():
                for child in src.iterdir():
                    if child.name in NOT_COPIED:
                        continue
                    if child.is_dir():
                        shutil.copytree(child, self.mdir / child.name, ignore=ignore, dirs_exist_ok=True)
                    else:
                        shutil.copy2(child, self.mdir / child.name)
            elif src.is_dir():
                shutil.copytree(src, dst, ignore=ignore, dirs_exist_ok=True)
            else:
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, dst)

        fid = 0
        number = 1
        for rel, module_rel in discover_sources(cfg):
            source = (cfg.root / rel).read_text()
            try:
                functions = analyze(source)
            except TokenizeError as e:
                log(f"warning: skipping {rel}: {e}")
                continue
            if not functions:
                continue
            sf = SourceFile(
                str(rel), module_name(module_rel), source, functions, fid, number, tuple(module_rel.parent.parts)
            )
            self.files.append(sf)
            lines = source.splitlines(keepends=True)
            for f in functions:
                # a statement is known by its first mutant's number
                site_of: list[int | None] = []
                for site in f.sites:
                    key = number + len(site_of)
                    site_of += [key if site.hook else None] * len(site.mutations)
                for index, m in enumerate(f.mutations, start=1):
                    desc = m.describe()
                    self.mutants[number] = MutantRecord(
                        id=f"{sf.module}.{f.qualname}.{index}",
                        number=number,
                        fid=fid,
                        file=sf.rel,
                        line=m.line + 1,
                        col=m.col + 1,
                        end_col=m.end_col + 1,
                        function=f.qualname,
                        description=desc,
                        original=m.original,
                        replacement=m.replacement,
                        fingerprint=_fingerprint(lines, f, desc, m.line),
                        site=site_of[index - 1],
                    )
                    number += 1
                fid += 1
        self.n_functions = fid

    # ---- phase 2: build ------------------------------------------------------

    def write_schemata(
        self,
        enabled: set[int],
        disabled_functions: set[int],
        dispatch_only: set[int] = frozenset(),
        root: Path | None = None,
    ) -> dict[Path, GeneratedFile]:
        root = root or self.mdir
        generated = {}
        for sf in self.files:
            gen = self._generate(sf, enabled, disabled_functions, dispatch_only)
            path = root / sf.rel
            path.write_text(gen.text)
            generated[path.resolve()] = gen
        return generated

    def _generate(
        self, sf: SourceFile, enabled: set[int], disabled_functions: set[int], dispatch_only: set[int] = frozenset()
    ) -> GeneratedFile:
        return generate(
            sf.source,
            sf.functions,
            first_fid=sf.first_fid,
            first_mutant=sf.first_mutant,
            n_functions_total=self.n_functions,
            n_mutants_total=len(self.mutants) + 1,
            enabled=enabled,
            disabled_functions=disabled_functions,
            dispatch_only=dispatch_only,
            no_inline=True,
        )

    def _binary_for(self, test_file: str) -> Path:
        return self.work / "bin" / test_file.replace("/", "__").removesuffix(".mojo")

    def _build_one(self, test_file: str, emit: str, root: Path | None = None) -> tuple[str, int, str]:
        assert self.mojo
        # the schemata trigger lots of "unreachable code" warnings
        cmd = [*self.mojo.command, "build", "--disable-warnings"]
        for inc in self.config.include_dirs:
            cmd += ["-I", inc]
        output = self._binary_for(test_file) if root is None else root / "despell-check"
        if emit != "exe":
            # report every elaboration error, not just the first 20
            cmd += ["--emit", emit, "--elaboration-error-limit=0"]
            output = output.with_suffix(".ll")
        cmd += [*self.config.build_args, test_file, "-o", str(output)]
        proc = subprocess.run(cmd, cwd=root or self.mdir, env=self.mojo.env, capture_output=True, text=True)
        if emit != "exe":
            # only the errors are wanted, and the IR can be gigabytes
            output.unlink(missing_ok=True)
        return test_file, proc.returncode, proc.stdout + proc.stderr

    def _slot_build(
        self,
        enabled: set[int],
        disabled_functions: set[int],
        test_files: list[str],
        emit: str,
        dispatch_only: set[int] = frozenset(),
    ) -> str | None:
        """Build in a private copy of the project, so several can run at once.

        Returns the compiler output if the build fails.
        """
        slot = self._slots.get()
        try:
            root = self.work / "slots" / str(slot)
            if not root.exists():
                shutil.copytree(self.mdir, root, ignore=shutil.ignore_patterns(WORK_DIR, STATE_FILE))
            self.write_schemata(enabled, disabled_functions, dispatch_only, root=root)
            self.n_builds += 1
            for test_file in test_files:
                _, code, out = self._build_one(test_file, emit, root)
                if code != 0:
                    return out
            return None
        finally:
            self._slots.put(slot)

    def _build_all(
        self,
        enabled: set[int],
        disabled_functions: set[int],
        emit: str,
        dispatch_only: set[int] = frozenset(),
        test_files: list[str] | None = None,
    ):
        self.n_builds += 1
        generated = self.write_schemata(enabled, disabled_functions, dispatch_only)
        test_files = test_files or sorted({t.file for t in self.tests})
        with ThreadPoolExecutor(self.workers) as pool:
            results = list(pool.map(lambda f: self._build_one(f, emit), test_files))
        return generated, [(f, out) for f, code, out in results if code != 0]

    def build(self, previous: dict[str, MutantRecord], only: set[int] | None = None):
        """Build test binaries holding the `only` mutants (default: all of them).

        Mutants that don't compile are found while checking with `--emit llvm`,
        which stops before LLVM optimization and codegen (the bulk of a build)
        but still runs elaboration, where many mutants fail.
        """
        self.mojo = self.mojo or find_mojo(self.config)
        enabled = set(self.mutants) if only is None else set(only)
        disabled_functions: set[int] = set()
        # skip what failed to compile last time and hasn't changed since
        for n, m in self.mutants.items():
            old = previous.get(m.id)
            if old and old.fingerprint == m.fingerprint and old.status in (COMPILE_ERROR, SKIPPED):
                if old.status == SKIPPED:
                    disabled_functions.add(m.fid)
                enabled.discard(n)
                m.status = old.status
                m.detail = old.detail

        t0 = time.monotonic()
        self.n_builds = 0
        self._precheck(enabled, disabled_functions)
        t_pre = time.monotonic()
        self._converge(enabled, disabled_functions, "llvm")
        t1 = time.monotonic()
        _, failures = self._build_all(enabled, disabled_functions, "exe")
        if failures:
            # rare: rejected only by the LLVM backend
            self._converge(enabled, disabled_functions, "exe")
        rejected = sum(1 for m in self.mutants.values() if m.status in (COMPILE_ERROR, SKIPPED))
        log(
            f"built {len({t.file for t in self.tests})} test binaries in {time.monotonic() - t0:.1f}s "
            f"({self.n_builds} builds; checking mutants took {t1 - t0:.1f}s, "
            f"of which {t_pre - t0:.1f}s pre-checking modules; {rejected} rejected)"
        )

    def _precheck(self, enabled: set[int], disabled_functions: set[int]):
        """Find compile errors fast by checking each mutated module on its own.

        Mojo only type-checks function bodies that are referenced, except in
        the file being compiled, where it checks everything. So compiling each
        module as its own entry point checks all of its mutants while touching
        only what it imports, in parallel and much faster than the test builds.
        That needs relative imports made absolute. Imports come from the
        original project: a mutant that breaks an imported module would stop
        the build before it gets to instantiating anything. Errors that only show when
        generic code is instantiated (a `comptime assert` in the stdlib, say)
        need the functions instantiated, so every function is marked
        `@export` (see `add_exports`). Checking a module this way reports some
        errors normal builds never see (code nothing references, a type
        existing twice, a function that can't be exported), so the unmutated
        module is checked first: functions that can't be exported aren't, and
        statements that fail without mutants are left alone.
        """
        files = [sf for sf in self.files if any(gm in enabled for gm in self._numbers(sf))]
        if not files:
            return
        t0 = time.monotonic()
        check_dir = self.work / "check"
        check_dir.mkdir(exist_ok=True)
        # imports resolve against the original project, so each module is
        # checked with its own mutants and no one else's
        root = self.config.root
        project_files = {(root / sf.rel).resolve() for sf in self.files}

        def check(sf: SourceFile, text: str, suffix: str, skip: set[int]):
            """Returns the module with exports, and the error chains it gets."""
            assert self.mojo
            exported = add_exports(text, skip)
            path = check_dir / f"{sf.module}{suffix}.mojo"
            path.write_text(absolutize_imports(exported.text, sf.package))
            cmd = [*self.mojo.command, "build", "--disable-warnings", "--emit", "llvm", "--elaboration-error-limit=0"]
            for inc in self.config.include_dirs:
                cmd += ["-I", inc]
            cmd += [*self.config.build_args, str(path), "-o", str(path.with_suffix(".ll"))]
            proc = subprocess.run(cmd, cwd=root, env=self.mojo.env, capture_output=True, text=True)
            path.with_suffix(".ll").unlink(missing_ok=True)
            path = path.resolve()
            chains = []
            for m in self._DIAG_RE.finditer(proc.stdout + proc.stderr):
                if m.group(4) == "error":
                    chains.append([])
                if not chains:
                    continue
                frame_path = (root / m.group(1)).resolve()
                where = "here" if frame_path == path else "project" if frame_path in project_files else "other"
                chains[-1].append((where, int(m.group(2)) - 1, m.group(5)))
            return exported, chains

        def culprit(chain) -> int | None:
            """The line in the checked module to blame for an error, if any."""
            if chain[0][2].startswith("function instantiation failed"):
                # deepest frame in the project's code; if that's in another
                # module, the error is that module's to report
                for where, line, _ in reversed(chain):
                    if where == "here":
                        return line
                    if where == "project":
                        return None
                return None
            return chain[0][1] if chain[0][0] == "here" else None

        def check_baseline(sf: SourceFile) -> tuple[set[int], set[int]]:
            skip: set[int] = set()
            for _ in range(10):
                exported, chains = check(sf, sf.source, ".orig", skip)
                lines = {line for chain in chains if (line := culprit(chain)) is not None}
                failing_exports = {exported.by_line[line] for line in lines if line in exported.by_line}
                if not failing_exports:
                    break
                skip |= failing_exports
            return skip, {exported.original_line(line) for line in lines}

        with ThreadPoolExecutor(self.workers) as pool:
            baseline = dict(zip([sf.rel for sf in files], pool.map(check_baseline, files)))
        rejected = 0
        todo = files
        round_log = []
        for round_no in range(1, 100):
            if not todo:
                break
            t_round = time.monotonic()
            # Mojo reports one instantiation error per function, so a module
            # can take a round per bad mutant. When few modules are left,
            # their mutants are split over several checks to find more at once.
            parts = max(1, self.workers // len(todo))
            jobs = []
            for sf in todo:
                mine = [n for n in self._numbers(sf) if n in enabled]
                k = max(1, min(parts, len(mine)))
                for i in range(k):
                    jobs.append((sf, set(mine[i::k]), f".p{i}" if k > 1 else ""))

            def run_job(job):
                sf, subset, suffix = job
                gen = self._generate(sf, subset, disabled_functions)
                return gen, check(sf, gen.text, suffix, baseline[sf.rel][0])

            with ThreadPoolExecutor(self.workers) as pool:
                results = list(pool.map(run_job, jobs))
            found_in: dict[str, int] = {}
            for (sf, subset, _), (gen, (exported, chains)) in zip(jobs, results):
                found = 0
                for chain in chains:
                    line = culprit(chain)
                    if line is None:
                        continue
                    line = exported.original_line(line)
                    region = next(
                        (r for r in gen.regions if r.mutant is not None and r.start <= line <= r.end), None
                    )
                    if region is None or region.mutant not in enabled or region.mutant not in subset:
                        continue
                    # the statement fails without the mutant too: not the mutant's fault
                    if any(region.orig[0] <= b <= region.orig[1] for b in baseline[sf.rel][1]):
                        continue
                    instantiation = chain[0][2].startswith("function instantiation failed")
                    self._reject(region.mutant, chain[-1][2] if instantiation else chain[0][2], enabled)
                    found += 1
                found_in[sf.rel] = found_in.get(sf.rel, 0) + found
            # errors hidden behind the ones just found may surface now
            todo = [sf for sf in todo if found_in.get(sf.rel)]
            rejected += sum(found_in.values())
            round_log.append(
                f"round {round_no}: {len(jobs)} checks of {len(found_in)} modules in "
                f"{time.monotonic() - t_round:.1f}s: {sum(found_in.values())} rejected "
                + " ".join(f"{rel}={n}" for rel, n in found_in.items() if n)
            )
        (self.work / "logs").mkdir(exist_ok=True)
        (self.work / "logs" / "precheck.txt").write_text("\n".join(round_log) + "\n")
        log(
            f"pre-checked {len(files)} modules in {time.monotonic() - t0:.1f}s "
            f"({round_no - 1} rounds): {rejected} mutants don't compile"
        )

    def _numbers(self, sf: SourceFile) -> range:
        count = sum(len(f.mutations) for f in sf.functions)
        return range(sf.first_mutant, sf.first_mutant + count)

    def _converge(self, enabled: set[int], disabled_functions: set[int], emit: str, recheck: bool = True):
        """Remove mutants from `enabled` until the build passes.

        An error located in a mutant's own lines condemns that mutant. Vaguer
        errors (in a statement holding several mutants, reported for a whole
        function, or without a location) only make their mutants suspects:
        they're set aside, and once the rest builds, added back in groups to
        find the ones that really don't compile.
        """
        suspects: list[tuple[set[int], int | None, list[str]]] = []  # (mutants, whole function?, test files)
        # Taking mutants out never breaks a build that passed, so after the
        # first attempt only the test files that failed are built again.
        test_files = None
        for attempt in range(1, 1000):
            t0 = time.monotonic()
            generated, failures = self._build_all(enabled, disabled_functions, emit, test_files=test_files)
            if not failures:
                break
            test_files = [f for f, _ in failures]
            logs = self.work / "logs"
            logs.mkdir(exist_ok=True)
            for f, out in failures:
                (logs / f"attempt{attempt}-{emit}-{Path(f).stem}.txt").write_text(out)
            mutant_hits, site_hits, function_hits = self._attribute_errors(failures, generated)
            dropped = {n for n in mutant_hits if n in enabled}
            for n in dropped:
                self._reject(n, mutant_hits[n], enabled)
            set_aside = 0
            if not dropped:
                if site_hits:
                    groups = [(set(site) & enabled, None) for site in site_hits]
                    why = "errors in statements holding several mutants: " + "; ".join(
                        sorted({msg[:80] for msg in site_hits.values()})[:3]
                    )
                elif function_hits:
                    groups = [({n for n in enabled if self.mutants[n].fid == fid}, fid) for fid in function_hits]
                    why = f"errors pointing at {len(function_hits)} whole functions"
                else:
                    groups = [(set(enabled), None)]
                    why = "errors without a location: " + _first_error(failures[0][1])[:80]
                failing_files = [f for f, _ in failures]
                for group, fid in groups:
                    enabled -= group
                    set_aside += len(group)
                    if group:
                        suspects.append((group, fid, failing_files))
                if not set_aside:
                    f, out = failures[0]
                    raise RunError(f"building {f} fails without any mutants:\n{_without_warnings(out)}")
            log(
                f"build attempt {attempt} ({time.monotonic() - t0:.1f}s): {len(dropped)} mutants don't compile"
                + (f", set aside {set_aside} suspects ({why})" if set_aside else "")
            )
        else:
            raise RunError("gave up after too many build attempts")

        if suspects and recheck:
            self._check_suspects(suspects, enabled, disabled_functions, emit)
            # each was checked alone with one test file; check them all together
            self._converge(enabled, disabled_functions, emit, recheck=False)
        elif suspects:
            # set aside again after passing on their own: they only fail together
            for group, _, _ in suspects:
                for n in group:
                    self._reject(n, "doesn't compile together with other mutants", enabled)

    def _check_suspects(self, suspects, enabled: set[int], disabled_functions: set[int], emit: str):
        """Check set-aside mutants one at a time, in parallel.

        Each check builds a single mutant and nothing else, with only the test
        file whose build failed. That's a small program, and since nothing else
        is in it, a failure can only be that mutant's fault.
        """
        t0 = time.monotonic()
        before = self.n_builds
        n_suspects = sum(len(group) for group, _, _ in suspects)

        # first: can each implicated function hold the dispatch at all? (not if
        # it's evaluated at compile time, say)
        functions = [(fid, files) for _, fid, files in suspects if fid is not None]
        with ThreadPoolExecutor(self.workers) as pool:
            results = list(pool.map(
                lambda item: self._slot_build(set(), disabled_functions, item[1], emit, dispatch_only={item[0]}),
                functions,
            ))
        for (fid, _), out in zip(functions, results):
            if out is not None:
                disabled_functions.add(fid)
                for m in self.mutants.values():
                    if m.fid == fid:
                        enabled.discard(m.number)
                        m.status = SKIPPED
                        m.detail = f"function can't be mutated with schemata: {_first_error(out)}"

        singles = [
            (n, files)
            for group, _, files in suspects
            for n in sorted(group)
            if self.mutants[n].fid not in disabled_functions
        ]
        with ThreadPoolExecutor(self.workers) as pool:
            results = list(pool.map(lambda item: self._slot_build({item[0]}, disabled_functions, item[1], emit), singles))
        bad = 0
        for (n, _), out in zip(singles, results):
            if out is None:
                enabled.add(n)
            else:
                self._reject(n, _first_error(out), enabled)
                bad += 1
        log(
            f"checked {n_suspects} suspects one by one in {self.n_builds - before} builds "
            f"({time.monotonic() - t0:.1f}s): {bad} don't compile"
        )

    def _reject(self, n: int, detail: str, enabled: set[int]):
        enabled.discard(n)
        self.mutants[n].status = COMPILE_ERROR
        self.mutants[n].detail = detail

    _DIAG_RE = re.compile(r"^(?:Imported from .*\n)?(.+?\.mojo):(\d+):(\d+): (error|note): (.*)$", re.MULTILINE)

    # a function referencing an undefined symbol, in the linker's output:
    #     _pkg::mod::Struct::method(::String) in mojo_archive-a8b61e5.a
    _LINK_REF_RE = re.compile(r"^\s+_([\w:]+)\(.* in \S+\.a$", re.MULTILINE)

    def _attribute_errors(self, failures, generated):
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
        mutant_hits: dict[int, str] = {}
        site_hits: dict[tuple[int, ...], str] = {}
        function_hits: set[int] = set()

        def region_at(path: Path, line: int):
            if path not in generated:
                return None
            regions = [r for r in generated[path].regions if r.start <= line <= r.end]
            return min(regions, key=lambda r: (r.mutant is None, r.end - r.start)) if regions else None

        for _, out in failures:
            chains: list[list[tuple[str, Path, int, str]]] = []
            for m in self._DIAG_RE.finditer(out):
                kind, msg = m.group(4), m.group(5)
                if kind == "error":
                    chains.append([])
                if chains:
                    chains[-1].append((kind, (self.mdir / m.group(1)).resolve(), int(m.group(2)) - 1, msg))
            for chain in chains:
                error_msg = chain[0][3]
                if error_msg.startswith("function instantiation failed"):
                    candidates = list(reversed(chain))  # deepest first
                else:
                    # the error's own location; failing that, a note in our code
                    candidates = [chain[0]] + [
                        d for d in chain[1:] if not d[3].startswith(("call expansion failed", "function instantiation"))
                    ]
                for _, path, line, msg in candidates:
                    region = region_at(path, line)
                    if region is None:
                        continue
                    if region.mutant is not None:
                        mutant_hits.setdefault(region.mutant, error_msg)
                    elif region.site:
                        site_hits.setdefault(region.site, error_msg)
                    else:
                        function_hits.add(region.fid)
                    break
            fids = {m.id.rsplit(".", 1)[0]: m.fid for m in self.mutants.values()}
            for symbol in self._LINK_REF_RE.findall(out):
                fid = fids.get(symbol.replace("::", "."))
                if fid is not None:
                    function_hits.add(fid)
        return mutant_hits, site_hits, function_hits

    # ---- phase 3: stats ------------------------------------------------------

    def _run_test_binary(self, binary: Path, names: list[str] | None, env_extra: dict, timeout: float | None):
        assert self.mojo
        cmd = [str(binary)]
        if names:
            cmd += ["--only", *names]
        env = {**self.mojo.env, **env_extra}
        t0 = time.monotonic()
        try:
            proc = subprocess.run(cmd, cwd=self.mdir, env=env, capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            return None, time.monotonic() - t0, ""
        return proc.returncode, time.monotonic() - t0, proc.stdout + proc.stderr

    def collect_stats(self):
        def one(t: TestRecord):
            code, duration, out = self._run_test_binary(
                self._binary_for(t.file), [t.name] if t.name else None, {"DESPELL_MUTANT": STATS_MODE}, timeout=None
            )
            t.binary = str(self._binary_for(t.file).relative_to(self.mdir))
            t.duration = duration
            t.functions = sorted({int(x) for x in re.findall(r"^despell-hit (\d+)$", out, re.MULTILINE)})
            t.sites = sorted({int(x) for x in re.findall(r"^despell-site (\d+)$", out, re.MULTILINE)})
            return t, code, out

        t0 = time.monotonic()
        with ThreadPoolExecutor(self.workers) as pool:
            results = list(pool.map(one, self.tests))
        failing = [(t, out) for t, code, out in results if code != 0]
        if failing:
            msg = "\n\n".join(f"--- {t.id}\n{out.strip()}" for t, out in failing[:5])
            raise RunError(f"{len(failing)} tests fail without any mutation applied:\n{msg}")
        log(f"ran {len(self.tests)} tests on unmutated code ({time.monotonic() - t0:.1f}s)")
        if self.mutants and not any(t.functions for t in self.tests):
            log("warning: no test reached any mutated function; check include_dirs")

    # ---- phase 4: mutants ----------------------------------------------------

    def run_mutant(self, m: MutantRecord, tests_by_fid: dict[int, list[TestRecord]], tests_by_site=None):
        t0 = time.monotonic()
        runs: list[int] = []  # tests per process started
        try:
            # only the tests that run the mutant's statement can kill it
            tests = tests_by_fid.get(m.fid, []) if m.site is None else (tests_by_site or {}).get(m.site, [])
            self._run_mutant(m, tests, runs)
        finally:
            self.timings.append((m.id, m.status, len(runs), sum(runs), time.monotonic() - t0))

    def _run_mutant(self, m: MutantRecord, tests: list[TestRecord], runs: list[int]):
        if not tests:
            m.status = NO_TESTS
            m.killed_by = None
            m.detail = None
            return
        tests = sorted(tests, key=lambda t: t.duration)
        # One failing test is enough, but a TestSuite runs all the tests it's
        # given. Most mutants that get killed fail the first test they meet, so
        # the fastest test runs on its own, then the rest in batches that
        # double in size: a killed mutant stops early, and a survivor only
        # pays for a few more process starts (milliseconds each).
        batches: list[tuple[str, list[TestRecord]]] = [(tests[0].file, tests[:1])]
        by_binary: dict[str, list[TestRecord]] = {}
        for t in tests[1:]:
            by_binary.setdefault(t.file, []).append(t)
        for file, ts in sorted(by_binary.items(), key=lambda kv: sum(t.duration for t in kv[1])):
            size = 2
            while ts:
                batches.append((file, ts[:size]))
                ts = ts[size:]
                size *= 2
        for file, ts in batches:
            names = [t.name for t in ts] if ts[0].name else None
            budget = sum(t.duration for t in ts)
            timeout = max(self.config.timeout_floor, budget * self.config.timeout_multiplier)
            runs.append(len(ts))
            code, _, out = self._run_test_binary(
                self._binary_for(file), names, {"DESPELL_MUTANT": str(m.number)}, timeout
            )
            if code is None:
                m.status = TIMEOUT
                m.killed_by = file
                m.detail = f"no result after {timeout:.1f}s"
                return
            if code != 0:
                m.status = KILLED
                failed = re.findall(r"^\s*FAIL \[.*?\] (\S+)", out, re.MULTILINE)
                m.killed_by = f"{file}::{failed[0]}" if failed else file
                m.detail = None
                return
        m.status = SURVIVED
        m.killed_by = None
        m.detail = None

    def _write_timings(self):
        lines = ["id\tstatus\tprocesses\ttests\tseconds"]
        lines += [f"{i}\t{st}\t{p}\t{n}\t{sec:.3f}" for i, st, p, n, sec in list(self.timings)]
        (self.work / "logs").mkdir(exist_ok=True)
        (self.work / "logs" / "mutants.tsv").write_text("\n".join(lines) + "\n")

    def run_mutants(self, selected: list[MutantRecord], checkpoint=None):
        """Run the mutants; `checkpoint(ids)` is called now and then with the
        ids of the mutants done so far, to save them."""
        tests_by_fid: dict[int, list[TestRecord]] = {}
        tests_by_site: dict[int, list[TestRecord]] = {}
        for t in self.tests:
            for fid in t.functions:
                tests_by_fid.setdefault(fid, []).append(t)
            for site in t.sites:
                tests_by_site.setdefault(site, []).append(t)
        todo = [m for m in selected if m.status not in (COMPILE_ERROR, SKIPPED)]
        if not todo:
            return
        log(f"running {len(todo)} mutants with {self.workers} workers")
        self.timings: list[tuple[str, str, int, int, float]] = []
        t0 = time.monotonic()
        last_report = last_save = t0
        done = 0
        pool = ThreadPoolExecutor(self.workers)
        try:
            for _ in pool.map(lambda m: self.run_mutant(m, tests_by_fid, tests_by_site), todo):
                done += 1
                now = time.monotonic()
                if now - last_report > 10 and done < len(todo):
                    log(f"  {done}/{len(todo)} mutants done")
                    last_report = now
                if checkpoint and now - last_save > 60:
                    checkpoint({m.id for m in todo[:done]})
                    last_save = now
        except KeyboardInterrupt:
            # don't wait for the mutants still queued; keep what's done
            pool.shutdown(wait=False, cancel_futures=True)
            if checkpoint:
                checkpoint({m.id for m in todo[:done]})
            self._write_timings()
            log(f"interrupted after {done}/{len(todo)} mutants; `despell run` continues from there")
            raise
        pool.shutdown()
        self._write_timings()
        elapsed = time.monotonic() - t0
        log(f"ran {len(todo)} mutants ({elapsed:.1f}s, {len(todo) / max(elapsed, 1e-9):.0f}/s)")


# ---- state -------------------------------------------------------------------


def state_path(config: Config) -> Path:
    return config.mutants_dir / STATE_FILE


def load_state(config: Config) -> tuple[dict[str, MutantRecord], dict[str, TestRecord]]:
    path = state_path(config)
    if not path.exists():
        return {}, {}
    data = json.loads(path.read_text())
    mutants = {m["id"]: MutantRecord(**m) for m in data.get("mutants", [])}
    tests = {t["id"]: TestRecord(**t) for t in data.get("tests", [])}
    return mutants, tests


def load_tests_hash(config: Config) -> str | None:
    path = state_path(config)
    return json.loads(path.read_text()).get("tests_hash") if path.exists() else None


def load_test_hashes(config: Config) -> dict:
    path = state_path(config)
    return json.loads(path.read_text()).get("test_hashes", {}) if path.exists() else {}


def save_state(
    config: Config,
    mutants: list[MutantRecord],
    tests: list[TestRecord],
    tests_hash: str | None = None,
    test_hashes: dict | None = None,
):
    data = {
        "version": 1,
        "tests_hash": tests_hash,
        "test_hashes": test_hashes or {},
        "mutants": [asdict(m) for m in sorted(mutants, key=lambda m: m.number)],
        "tests": [asdict(t) for t in tests],
    }
    path = state_path(config)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=1))
    tmp.replace(path)


def matches(m: MutantRecord, selectors: list[str]) -> bool:
    for s in selectors:
        if fnmatch.fnmatchcase(m.id, s) or m.id.startswith(s + "."):
            return True
        if ":" in s:
            # file:line
            file, _, line = s.rpartition(":")
            if line.isdigit() and m.file == file and m.line == int(line):
                return True
        elif m.file == s:
            return True
    return False


def tests_fingerprint(config: Config) -> str:
    """A hash of everything in the tests directory: results from a run with
    other tests can't be trusted."""
    h = hashlib.sha256()
    tests_root = config.root / config.tests_dir
    for path in sorted(tests_root.rglob("*")):
        if path.is_file() and not any(part in NOT_COPIED for part in path.relative_to(tests_root).parts):
            h.update(str(path.relative_to(tests_root)).encode() + b"\0" + path.read_bytes() + b"\0")
    return h.hexdigest()[:16]


def test_file_hashes(config: Config, test_files: set[str]) -> dict[str, str]:
    """A hash per test file, and one ("*") for the rest of the tests
    directory (shared helpers, fixtures), which every test file may use."""
    tests_root = config.root / config.tests_dir
    rest = hashlib.sha256()
    hashes = {}
    for path in sorted(tests_root.rglob("*")):
        if not path.is_file() or any(part in NOT_COPIED for part in path.relative_to(tests_root).parts):
            continue
        rel = str(path.relative_to(config.root))
        if rel in test_files:
            hashes[rel] = hashlib.sha256(path.read_bytes()).hexdigest()[:16]
        else:
            rest.update(rel.encode() + b"\0" + path.read_bytes() + b"\0")
    hashes["*"] = rest.hexdigest()[:16]
    return hashes


def _needed_test_files(
    selected: list[MutantRecord], old_tests: dict[str, TestRecord], old_hashes: dict, hashes: dict
) -> set[str] | None:
    """The test files that can kill the selected mutants, or None for all.

    Those whose tests ran the mutants' code last time, and the ones changed
    since, which may now. Coverage is by mutant and function numbers, which
    only hold while the sources are the same.
    """
    if not old_tests or old_hashes.get("sources") != hashes["sources"] or old_hashes.get("*") != hashes["*"]:
        return None
    needed = {f for f, h in hashes.items() if f not in ("*", "sources") and old_hashes.get(f) != h}
    for t in old_tests.values():
        if t.file in needed:
            continue
        for m in selected:
            if (m.site in t.sites) if m.site is not None else (m.fid in t.functions):
                needed.add(t.file)
                break
    return needed


# a mutant with one of these from an earlier run, and the same code and tests,
# isn't run again
FINAL = {KILLED, SURVIVED, TIMEOUT, NO_TESTS}


def run(config: Config, *, selectors: list[str], workers: int) -> list[MutantRecord]:
    """Run the selected mutants, or, without selectors, the ones without a
    result yet. Returns the selected mutants, or all of them."""
    previous, old_tests = load_state(config)
    tests_hash = tests_fingerprint(config)
    tests_changed = previous and load_tests_hash(config) != tests_hash
    r = Run(config, workers=workers)
    t0 = time.monotonic()
    r.prepare()
    all_tests = discover_tests(config)
    if not all_tests:
        raise RunError(f"no test files found in {config.tests_dir}")
    r.tests = all_tests
    all_files = {t.file for t in all_tests}
    hashes = test_file_hashes(config, all_files)
    hashes["sources"] = hashlib.sha256("\0".join(sf.source for sf in r.files).encode()).hexdigest()[:16]
    log(
        f"generated {len(r.mutants)} mutants in {r.n_functions} functions "
        f"across {len(r.files)} files; {len(r.tests)} tests"
    )

    if selectors:
        selected = [m for m in r.mutants.values() if matches(m, selectors)]
        if not selected:
            raise RunError(f"no mutants match {' '.join(selectors)}")
    else:
        if tests_changed:
            log("the tests changed since the last run: running every mutant again")
            previous = {k: v for k, v in previous.items() if v.status not in FINAL}

        def has_result(m: MutantRecord) -> bool:
            old = previous.get(m.id)
            return bool(old and old.fingerprint == m.fingerprint and old.status in FINAL | {COMPILE_ERROR, SKIPPED})

        selected = [m for m in r.mutants.values() if not has_result(m)]
        resumed = len(r.mutants) - len(selected)
        if resumed:
            log(f"{resumed} mutants have results from an earlier run; running the other {len(selected)}")

    def save(fresh: set[str]):
        """Save, keeping earlier results for the unchanged mutants not in `fresh`."""
        mutants = []
        for m in r.mutants.values():
            old = previous.get(m.id)
            if m.id not in fresh and m.status not in (COMPILE_ERROR, SKIPPED) and old and old.fingerprint == m.fingerprint:
                m = MutantRecord(**{**asdict(m), "status": old.status, "killed_by": old.killed_by, "detail": old.detail})
            mutants.append(m)
        # tests that weren't run this time keep their coverage from before
        ran = {t.file for t in r.tests}
        kept = [t for t in old_tests.values() if t.file not in ran] if len(ran) < len(all_files) else []
        save_state(config, mutants, r.tests + kept, tests_hash, hashes)
        return mutants

    selected_ids = {m.id for m in selected}
    if not selected:
        log("nothing to run; pass mutant ids to run some again, or delete mutants/ to start over")
        return save(fresh=set())
    # only the selected mutants go into the build, and only the test files
    # that can kill them get built: that's what makes the write-a-test,
    # re-check loop fast
    partial = len(selected) < len(r.mutants)
    if partial:
        needed = _needed_test_files(selected, old_tests, load_test_hashes(config), hashes)
        if needed is not None:
            r.tests = [t for t in all_tests if t.file in needed]
            log(f"building the {len(needed)} of {len(all_files)} test files that can reach these mutants")
    r.build(previous, only={m.number for m in selected} if partial else None)
    # a long build's verdicts survive whatever goes wrong after it
    save(fresh=set())
    r.collect_stats()
    r.run_mutants(selected, checkpoint=lambda done: save(fresh=done))

    all_mutants = save(fresh=selected_ids)
    log(f"done in {time.monotonic() - t0:.1f}s")
    return [m for m in all_mutants if m.id in selected_ids] if selectors else all_mutants
