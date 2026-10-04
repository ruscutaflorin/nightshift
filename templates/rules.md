- Follow the conventions in `CLAUDE.md`.
- Add project-specific rules here (architecture boundaries, commands to use, things never to do). The night-shift agents receive this file in every prompt.

## Testing policy

- **Authoring gate**: before adding a test, answer: (1) what observable behavior or contract it
  protects, (2) what credible regression makes it fail, (3) why existing coverage doesn't already
  catch that (one owner per contract, at the strongest boundary: the public API or route, a pure
  function, or what the user sees; extend a table-driven case rather than adding a
  near-duplicate), (4) whether it needs a production seam no production caller uses (if so, test
  at the real boundary instead). No answer, no test.
- **Junk patterns** fail the gate: assertion-free probes, copied inventories/catalogues/export
  lists, source or string greps, re-asserting what a mock was told to return, expected values
  computed by the code under test, replaying a shared helper's logic in every caller's suite,
  negative tests that pass for an unrelated reason (e.g. a 401 when validation is the claim), and
  names that promise more than the test checks.
- Bug regression tests must fail on the pre-fix code and pass after the fix; one regression at the
  owner boundary is enough.
- "Missing tests" alone is not a reason to add one: untested behavior gets a test only when it
  passes the gate.
- **Deleting or consolidating tests** is allowed only in a `TASKS.md` task tagged `[test-audit]`.
  Each removed or merged test gets a one-line evidence note (what it detected, which stronger test
  still covers it) in the commit body. Every other task never deletes, skips or weakens tests.
