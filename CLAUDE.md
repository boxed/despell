# despell

Mutation testing for Mojo, written in Mojo (1.2). See README.md for the design.

- `pixi run build` builds `build/despell`; `pixi run test` builds, then runs every `tests/test_*.mojo` (`mojo run -I src`).
- `src/despell/tokenizer.mojo`: hand-rolled Mojo tokenizer (no AST anywhere).
- `src/despell/mutation.mojo`: operators, function discovery, statement-level schemata generation (sites: dup/wrap/decl).
- `src/despell/runner.mojo`: copy to mutants/, build loop (converge with `--emit llvm`, vindicate suspects, final exe build), pre-check.
- `src/despell/session.mojo`: a whole run: planning, stats run, mutant runs, saving state.
- `src/despell/state.mojo`: the state file, locks, and deciding what a test change can affect.
- `src/despell/cli.mojo`: commands; output is meant to be read by agents.
- `sysutil.mojo` (processes, signals, locks), `fsutil.mojo`, `jsonio.mojo`, `toml.mojo`, `textutil.mojo`: the stdlib gaps.
- `e2e_projects/simple`: Mojo project used by the e2e test. If you change it, regenerate `tests/e2e_expected.txt`.
- Mojo 1.2: `fn` is gone (use `def`), no module-level `var`, std imports are `from std.x import y`, no `len(String)` (use `byte_length()`), slices are `s[byte=a:b]`.
- State files get big (25 MB on a 50k-mutant project) and are re-read every save: keep parsing and encoding linear (`test_a_large_state_saves_and_loads_quickly` guards this).
- Mojo's compile cache hides real build times; set `MODULAR_CACHE_DIR` to an empty dir when benchmarking. It doesn't share work between test files.
- Each test binary only holds the mutants its tests reach (`Run.file_sets`); big builds without up-to-date coverage build without mutants first to measure it. `DESPELL_COVERAGE_FIRST=<n>` sets the size from which that happens (the e2e test uses 0).
- The generated runtime header (`RUNTIME_HEADER`) keeps its state in the runtime's indexed global slot 2 (there are only 3, and nothing reserves them), with a magic number, falling back to a lookup by name if something else holds it: lookups by name made hot code several times slower. Every `def` in it must be named `_despell...` (the pre-check exports all other functions), so no methods.
- Coverage is saved by function and statement numbers, which shift when the code changes. Snapshots also store each function number's `<file>::<name>` (`FUNCTIONS`), so after an edit a re-check of selected mutants still builds only the test files whose tests reached their functions (`_reaches_by_name`). The state's `numbered` names the snapshot the mutants' numbers and lines are from: `show` only matches coverage measured on that code by number, older coverage by function name (`State.tests_reaching`).
- A mutant's fingerprint hashes its function's text, its description and its line; a result stands while the fingerprint does. `Run.adopt_moved` keeps the results of functions that only moved (same text, other lines).
- `equivalence.mojo`: after a run, survivors whose function compiles (optimized, `--emit asm`) to the same code as the unmutated copy become `equivalent`. Comparison must stay sound: when in doubt, copies differ. `EQ_VERSION` is stored per mutant (`eq_checked`): bump it when the comparison changes, so mutants get compared again.
- Mojo's `String.splitlines` also splits on tabs and other control characters: use `textutil.split_lines`.
- Test processes don't inherit despell's locks (`POSIX_SPAWN_CLOEXEC_DEFAULT`); a run kills orphaned test processes under `mutants/` (side copies too), and once it holds the main lock, any left running its test binaries (`kill_strays`).
- `tools/lexer_oracle`: `pixi run check-lexer` compares `tokenizer.mojo` with Mojo's own `Lexer.cpp` (built from Modular's source at `COMMIT`) on ~1500 files. Run it after changing the tokenizer; a difference is a tokenizer bug (string handling follows `Lexer.cpp`: `skipStringBody`, `skipTStringBody`, `findTStringInterpolationEnd`).
