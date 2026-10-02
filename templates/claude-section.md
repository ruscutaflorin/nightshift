## Night Shift agents (headless `claude -p` sessions run by Night Shift)

- Work order lives in `TASKS.md`; ideas in `BACKLOG.md`; learnings in `NOTES.md`; project rules in `.nightshift/rules.md`.
- Building agents (builder, fixer, polish, product) do exactly the task they were given, then stop. They commit on the current branch and never switch branches, merge, rebase, reset or push: the supervisor lands each item through its own PR.
- Building agents never edit `TASKS.md`, `CLAUDE.md`, `.nightshift/`, `.claude/` or other protected paths; the supervisor reverts such changes. Only the resolver (and you) change those: agent permissions are in `.nightshift/agent-settings.json`.
- Never delete, skip or weaken tests; the supervisor rejects a drop in passing tests.
- Never run interactive or long-running commands (dev servers, emulators, watchers).
- If something outside the task blocks you (a permission, a missing service or tool, an open decision), change nothing and end with `BLOCKED: <exactly what is missing>`: the resolver clears it and the task is retried. Otherwise end with `DONE: <summary>`.
