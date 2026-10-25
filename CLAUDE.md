# despell

Mutation testing for Mojo, written in Python. See README.md for the design.

- `uv run pytest` runs everything; `tests/test_e2e.py` needs Mojo from `pixi install` (root pixi.toml).
- `src/despell/tokenizer.py`: hand-rolled Mojo tokenizer (no AST anywhere).
- `src/despell/mutation.py`: operators, function discovery, statement-level schemata generation (sites: dup/wrap/decl).
- `src/despell/runner.py`: copy to mutants/, build loop (converge with `--emit llvm`, vindicate suspects, final exe build), stats run, mutant runs, state.
- `src/despell/cli.py`: commands; output is meant to be read by agents.
- `e2e_projects/simple`: Mojo project used by the e2e test. If you change it, regenerate EXPECTED in tests/test_e2e.py.
- Mojo 1.2: `fn` is gone (use `def`), no module-level `var`, std imports are `from std.x import y`.
- Mojo's compile cache hides real build times; set `MODULAR_CACHE_DIR` to an empty dir when benchmarking.
