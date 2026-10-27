# despell

Mutation testing for [Mojo](https://mojolang.org), in the spirit of
[mutmut](https://github.com/boxed/mutmut), built to be driven by coding agents.

```
$ despell run
generated 78 mutants in 25 functions across 2 files; 15 tests
build attempt 1: 3 mutants don't compile, rebuilding
build attempt 2: 1 mutants don't compile, rebuilding
build attempt 3: 0 mutants don't compile, 1 functions can't be mutated, rebuilding
built 2 test binaries (0.7s)
ran 15 tests on unmutated code (0.2s)
running 72 mutants with 4 workers
ran 72 mutants (2.0s, 35/s)
done in 6.0s

78 mutants: 26 survived, 2 no_tests, 1 timeout, 3 skipped, 3 compile_error, 43 killed, score 62.7%

To act on:
  survived      mylib.mathx.clamp.1      src/mylib/mathx.mojo:10:10  `<` -> `<=`
  ...
Next: `despell show <id>` to see a mutant's diff and the tests that reach it.
```

## Usage

```
despell run [selector ...]       generate mutants, build, test (all, or just the selected ones; --force)
despell results [selector ...]   list survivors and untested mutants (--all, --status, --json)
despell show <selector> ...      diff, location, status and the tests that reach the code (--json)
despell guide                    workflow, statuses and config, written for agents
```

A selector is a mutant id (`mylib.mathx.clamp.1`), a function or module
prefix (`mylib.mathx.clamp`, `mylib.mathx`), a glob, a source file, or
`file:line`.

The loop an agent runs (`despell guide` spells it out for them):

1. Start `despell run` in the background. It prints each survivor as soon as
   it's found, and saves results as it goes.
2. `despell show` the survivors of a function, and write tests that kill them
   in a new, small test file.
3. `despell run <those ids>` to confirm they're killed. This can run while
   the long run is still going (it works on its own copy of the project), and
   it only builds test files that are new or changed since the mutants were
   checked, so a small new file means a re-check in seconds.

There's a ready-made Claude Code skill for this in `skills/kill-survivors/`.

Silence an equivalent mutant with `# pragma: no mutate` on its line, or on the
`def` line for the whole function.

## Project layout and config

By default despell mutates `src/`, builds every `tests/**/test*.mojo` with
`-I src`, and runs the tests with `TestSuite` (`--only <test>`) so each mutant
only runs the tests that reach it. Override in `despell.toml` (or
`[tool.despell]` in `pixi.toml`/`pyproject.toml`):

```toml
paths_to_mutate = ["src"]
tests_dir = "tests"
include_dirs = ["src"]   # -I paths for mojo build, relative to the project
also_copy = []           # extra files the build needs
do_not_mutate = []       # globs of source files to leave alone
build_args = []          # extra `mojo build` arguments
mojo = "mojo"            # otherwise: $DESPELL_MOJO, PATH, then the nearest pixi env
timeout_multiplier = 10.0
timeout_floor = 2.0
sandbox_tests = true     # keep tests from signaling processes they didn't start
```

Results live in `mutants/despell.json`, saved as the run goes. Each result
remembers the test files it was obtained with, so a plain `despell run` only
runs what could have changed: mutants without a result (an interrupted run
continues where it stopped), changed code, killed mutants whose killing test
file changed (against that file first, and every other test that reaches them
only if it no longer kills them), and survivors against new or changed test
files. A change to
shared test code re-runs everything. `despell run --force <selector>` re-runs
the selected mutants whatever their results. Delete `mutants/` to start over.

despell copies the project into `mutants/` (minus version control,
environments and caches) and runs the tests there. It puts a `.gitignore`
in `mutants/` unless the project already ignores it; add `mutants/` to
your own `.gitignore` if your tests look at `.gitignore` files.

## How it works

**Mutation schemata.** Mojo is compiled, so compiling once per mutant would be
far too slow. Instead, all mutants are compiled into the same binary, and each
statement holding mutations switches on the active mutant. Only that statement
is duplicated, never the whole function, so the generated code grows linearly
with the number of mutants (about 3-5x the source):

```mojo
def clamp(x: Int, lo: Int, hi: Int) -> Int:
    var despell_m_ = _despell_active(1)
    if despell_m_ == 2:
        if x <= lo:
            return lo
    else:
        if x < lo:
            return lo
    ...
```

How a statement switches depends on what it is:

- Most statements are duplicated behind an `if`/`elif` chain. For a compound
  statement (`if`/`elif`/`else`, loops, `with`) the whole statement is
  duplicated, with its nested mutations dispatched only in the original copy,
  since just one mutant is active at a time.
- `var x = e` can't be duplicated (each copy would declare its own `x`), so `e`
  becomes a chain of ternaries, one mutant per line: `(a - b) if despell_m_ ==
  7 else (a + b)`. `elif` conditions are handled the same way.
- `var x: T = e` becomes `var x: T` followed by a duplicated `x = e`, so `e`
  keeps `T` as context for literals.
- `comptime` code isn't mutated.

The active mutant comes from `DESPELL_MUTANT`, read once into a process global
(`_Global` from the stdlib, since Mojo has no module-level `var`), in one of
the runtime's few indexed slots when that's free: a check costs about 1 ns,
against 5 ns for a lookup by name, which made hot code (small functions called
billions of times) run several times slower. Functions that return a value end
with an `abort()`, because a mutated `while True` no longer tells the compiler
the end is unreachable.

**The compiler as a filter.** Many mutants don't type-check (`String - String`,
pointer arithmetic turned into `Pointer + Pointer`). A full AST wouldn't help:
these are type errors, and Mojo has no AST stage anyway. Its parser type-checks
while it emits MLIR. So despell builds with `--emit llvm`, which skips LLVM
optimization and codegen (most of a build's time), and maps each error back to
what produced it:

- An error located in one mutant's lines rejects that mutant (`compile_error`).
- Vaguer errors (in a statement holding several mutants, reported for a whole
  function, or without any location, like a SIMD width changed from 32 to 33)
  only make their mutants suspects. They're set aside until the rest builds,
  then added back in shrinking groups until the culprits are pinned down. A
  mutant is only rejected for an error it causes on top of a build that
  passes.
- If a function can't hold the dispatch at all, for example because it's
  evaluated at compile time, its mutants are `skipped`.

Rejected mutants and skipped functions are remembered between runs, and
`despell run <ids>` only builds the selected mutants, so re-checks are quick.

**Coverage.** Every statement holding mutations starts with a hook, whether
its mutants are in the build or not. Running each test on its own with
`DESPELL_MUTANT=-1` runs the original code and records which statements each
test reaches. It also checks the suite is green before mutating anything.

**One binary per test file, holding only what its tests reach.** Compile time
grows with the schemata, and every test binary compiles everything its test
file imports. A test file's tests usually execute only a fraction of the code
the compiler can reach from it, so each binary only gets the mutants its tests
reach. For a big build without up-to-date coverage, the test files are built
without mutants first to measure it. Mutants no test reaches are still
pre-checked, so they come out `compile_error` or `no_tests`, but never built.
Test files that need the same mutants share a copy of the project to build
in; the others get their own.

**Running mutants.** Each mutant runs only the tests that reach its statement,
grouped per test binary, in parallel worker processes, with a timeout derived
from the measured test durations. Without `-j N`, the number of workers starts
at half the cores and follows the CPU the tests use: tests that mostly wait (on
I/O, the network, a mutant's timeout) get more workers, until the cores are
busy or the machine is loaded with other work.

**Equivalent mutants.** Some mutants can't be killed because they don't
change anything: a dead store (`var i = 0` -> `var i = 1` where `i` is set
again before it's read), `<` -> `<=` in a `max`, a branch that's never taken.
After a run, each surviving (or untested) mutant's function is compiled with
optimization, once unmutated and once with the mutant, as exported copies in
the same module; when the two come out as exactly the same machine code, the
mutant is `equivalent`: not listed to act on, and not counted in the score.
Labels, data and the source line numbers that end up in the code are
compared so that anything not accounted for counts as different, never the
same. It finds a few percent of survivors (2-6% on turbokod), at a few
seconds per module, once per mutant while its function doesn't change.
Constructors, parametric and nested functions can't be checked this way.

**The sandbox.** Code that stops its child processes is one mutant away from
`kill(-1, SIGTERM)` (`if alive and pid > 0` -> `if alive or pid > 0`, with
`pid == -1`), which signals every process the user has: on a desktop, that's
every open program. On macOS, tests run under `sandbox-exec` with a profile
that only lets them signal their own process group (despell gives each test
process one) and what they start. A test suite that signals other processes
on purpose, say a liveness check with `kill(pid, 0)` on another test process
(which gets EPERM there, not ESRCH), fails before any mutant runs, and despell
says why. On Linux, tests aren't sandboxed yet.

**Memory.** A mutant can also make a test allocate without end. despell
records how much memory each test uses unmutated, and stops a mutant's tests
when they use more than 4 times that and over 1 GB more (`killed`). It also
runs fewer mutants at once when the machine runs low on memory.

### Why exec and not fork

mutmut forks because starting Python and importing a test suite is expensive.
A compiled Mojo test binary starts in about 6 ms, so despell just executes it
once per (mutant, test file). Forking inside a running Mojo program isn't safe
anyway: the runtime has already started libdispatch threads, and a forked child
crashes on exit on macOS. Compile time dominates the run, and schemata already
solve that.

## Installing

despell is written in Mojo. Build it with [pixi](https://pixi.sh) and put the
binary on your `PATH`:

```
pixi run build        # writes build/despell
```

## Developing

```
pixi run test         # builds, then runs every tests/test_*.mojo
```

```
pixi run check-lexer  # despell's tokenizer against Mojo's own lexer
```

despell's tokenizer is its own (there's no Mojo parser to use: the compiler
type-checks as it parses, into MLIR), but `check-lexer` holds it to the
compiler's: it builds `Mojo/lib/MojoParser/Lexer.cpp` from Modular's open
source compiler (Apache 2.0, pinned in `tools/lexer_oracle/COMMIT`, fetched,
not vendored) with stand-ins for the rest of the compiler, and compares the
tokens of the Mojo stdlib, the compiler's parser tests and despell's own
sources (and any paths given) with despell's. It needs Homebrew's `llvm@22`
(or `LLVM_CONFIG`). Bump `COMMIT` to check against a newer Mojo.

`tests/test_e2e.mojo` runs the built binary on a copy of
`e2e_projects/simple` and compares every mutant's status with
`tests/e2e_expected.txt`.
