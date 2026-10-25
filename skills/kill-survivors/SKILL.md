---
description: Write tests that kill surviving despell mutants in a Mojo project. Use after `despell run`, or to close test gaps in Mojo code.
argument-hint: [mutant selector, e.g. mylib.math or mylib.math.clamp]
---

$ARGUMENTS

`despell guide` has the full workflow, statuses, selectors and config; read it first if you haven't.

1. Get survivors:
   - If a `despell run` is already going (or has finished), use `despell results` (with the selector above, if given) to list the `survived` and `no_tests` mutants found so far.
   - Otherwise start `despell run` (with the selector, if given) in the background with its output going to a file. It prints each survivor as it's found, so start working as soon as the first ones show up instead of waiting for it to finish.
2. Take the mutants of one function at a time: `despell show <id> <id> ...` shows each diff, its location, and the tests that already run that line.
3. For each mutant, work out what observable behavior the change would alter: which input gives a different result?
4. Write a focused test that passes on the original code and fails with the mutant. Put it in a new test file for the module under test (e.g. `tests/test_<module>_mutants.mojo`), importing only what it needs: re-checks only build new and changed test files, and a small file builds in seconds where a big one takes much longer. The file needs top-level `def test_*() raises` functions and a `main` that calls `TestSuite.discover_tests[__functions_in_module()]().run()`.
5. Re-check those mutants with `despell run <id> <id> ...` (or the function's prefix). This is fine while a long `despell run` is still going. Confirm they're `killed`, and fix the tests if not.
6. Go back to 2 for the next function.

If a mutant is equivalent (no input can tell it apart from the original, e.g. `x < lo` -> `x <= lo` in a clamp that returns `lo` either way), don't write a meaningless test. Tell the user, and suggest `# pragma: no mutate` on that line if they want it silenced.

Finish with `despell results` and report what was killed, what was left as equivalent, and anything that looked like a real bug.
