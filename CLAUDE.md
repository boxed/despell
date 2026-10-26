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
