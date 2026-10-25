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
despell run [selector ...]       generate mutants, build, test (all, or just the selected ones)
despell results [selector ...]   list survivors and untested mutants (--all, --status, --json)
despell show <selector> ...      diff, location, status and the tests that reach the code (--json)
despell guide                    workflow, statuses and config, written for agents
```

A selector is a mutant id (`mylib.mathx.clamp.1`), a function or module
prefix (`mylib.mathx.clamp`, `mylib.mathx`), a glob, a source file, or
`file:line`.

The loop an agent runs: `despell run`, `despell show` a few survivors, write
tests, `despell run <those ids>` to confirm they're killed. There's a
ready-made Claude Code skill for this in `skills/kill-survivors/`.

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
```

Results live in `mutants/despell.json`. Delete `mutants/` to start over.

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
(`_Global` from the stdlib, since Mojo has no module-level `var`). A check
costs about 5 ns. Functions that return a value end with an `abort()`, because
a mutated `while True` no longer tells the compiler the end is unreachable.

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

**Coverage.** A first pass runs each test on its own with `DESPELL_MUTANT=-1`.
That runs the original code and records which functions each test reaches.
It also checks the suite is green before mutating anything.

**Running mutants.** Each mutant runs only the tests that reach its function,
grouped per test binary, in parallel worker processes, with a timeout derived
from the measured test durations.

### Why exec and not fork

mutmut forks because starting Python and importing a test suite is expensive.
A compiled Mojo test binary starts in about 6 ms, so despell just executes it
once per (mutant, test file). Forking inside a running Mojo program isn't safe
anyway: the runtime has already started libdispatch threads, and a forked child
crashes on exit on macOS. Compile time dominates the run, and schemata already
solve that.

## Developing

```
pixi install          # Mojo, for the end-to-end tests
uv run pytest
```
