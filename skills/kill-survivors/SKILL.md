---
description: Write tests that kill surviving despell mutants in a Mojo project. Use after `despell run`, or to close test gaps in Mojo code.
argument-hint: [mutant selector, e.g. mylib.math or mylib.math.clamp]
---

$ARGUMENTS

`despell guide` explains statuses, selectors and config if anything below is unclear.

1. If there are no results yet (or the source changed), run `despell run` (optionally with the selector above). Otherwise run `despell results` (with the selector, if given) to list the `survived` and `no_tests` mutants.
2. Run `despell show <id> <id> ...` for a batch of related mutants (e.g. one function). Each entry shows the diff, the function, and which tests already reach the code.
3. For each mutant, work out what observable behavior the change would alter: which input produces a different result?
4. Add a focused test to the right test file (usually one of the tests listed as reaching the function) that passes on the original code and fails with the mutant. Test files must stay runnable with `TestSuite.discover_tests`: top-level `def test_*() raises`.
5. Re-check just those mutants with `despell run <id> <id> ...`. This is fast: it rebuilds once and runs only the selected mutants. Confirm they are `killed`, and adjust the tests if not.

If a mutant is equivalent (no input can tell it apart from the original, e.g. `x < lo` -> `x <= lo` in a clamp that returns `lo` either way), don't write a meaningless test. Tell the user, and suggest `# pragma: no mutate` on that line if they want it silenced.

Finish with `despell results` and report what was killed, what was left as equivalent, and anything that looked like a real bug.
