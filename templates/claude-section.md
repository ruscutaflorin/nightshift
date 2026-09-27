## Night-shift agents (headless `claude -p` sessions run by Night Shift)

- Work order lives in `TASKS.md`; ideas in `BACKLOG.md`; learnings in `NOTES.md`; project rules in `.nightshift/rules.md`.
- Do exactly the task you were given, then stop. Commit on the current branch; never switch branches, merge, rebase, reset or push.
- Never edit `TASKS.md`, `CLAUDE.md`, `.nightshift/`, `.claude/` or other protected paths — the supervisor rejects such diffs.
- Never delete, skip or weaken tests; the supervisor rejects a drop in passing tests.
- Never run interactive or long-running commands (dev servers, emulators, watchers).
- If a prerequisite is missing, change nothing and end with `BLOCKED: <reason>`; otherwise end with `DONE: <summary>`.
