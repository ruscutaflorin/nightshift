# Night Shift

An unattended **agent factory** for any git project: while you sleep, headless Claude Code
sessions work through your `TASKS.md` one task at a time. Every change is checked by your
own tests and reviewed by a second agent before it lands on `develop`. It stays inside your
Claude subscription by sleeping through usage limits, and `main` only moves when you promote it.

```
nightshift run / start / scheduled task
  until the deadline or a stop request:
    next item: TASKS.md [ ] -> BACKLOG.md "status: approved" -> product agent (once) -> polish (<= 4)
    branch night/<id> from develop
    BUILDER (sonnet) -> CHECKS -> REVIEWER (sonnet, read-only) -> merge --no-ff into develop, tick [x]
                          | failed / changes requested
                          +-> FIXER (opus) with the exact failure, up to maxAttempts
                          +-> still failing: mark [!] + reason, keep the branch, skip the rest of that phase
    usage limit -> sleep until the reset (or end the run if that's after the deadline)
```

## Install

```powershell
git clone <this repo> D:\repos\personal\night-shift      # or wherever
# optional: put the folder on your PATH so `nightshift` works everywhere
[Environment]::SetEnvironmentVariable('Path', $env:Path + ';D:\repos\personal\night-shift', 'User')
```

Requirements: Windows + Windows PowerShell 5.1, git, Claude Code CLI logged in with your subscription.

## Add it to a project

```powershell
nightshift init -Project D:\repos\my-app -Preset node     # generic | flutter | node | python
```

`init` creates (without overwriting anything that exists):

| File | Purpose |
|---|---|
| `.nightshift/config.json` | checks, services, models, deadlines, protected paths |
| `.nightshift/rules.md` | project rules injected into every agent prompt |
| `TASKS.md` | the ordered work (`- [ ] 1.2 text`) |
| `BACKLOG.md` | ideas; you approve them by setting `status: approved` |
| `NOTES.md` | learnings agents hand to each other |
| `CLAUDE.md` section | rules for headless agents |
| `.claude/settings.json` | the permission allowlist headless agents run under |
| `.gitignore` entries, git repo, `develop` branch | |

Then:
1. Write the tasks. Tune the checks in `config.json`.
2. **Trust the folder once:** `cd <project>; claude`, accept the trust prompt, then `/exit`. Claude Code ignores a project's allowlist until you do.
3. `nightshift dry-run`, then `nightshift start -For 1h`, then `nightshift schedule`.

## Commands

Run these inside the project, or add `-Project <path>`:

| Command | What it does |
|---|---|
| `nightshift dry-run` | What would run next, the deadline, whether the folder is trusted and whether a run is active. Changes nothing. |
| `nightshift start [-For 2h \| -Until 07:00] [-Once] [-Task 3.4]` | Starts a run in its own minimized window and returns immediately. |
| `nightshift run [...same flags]` | Runs in this window. This is what the scheduler calls. |
| `nightshift status` | Running or not, task counts, next task, schedule, latest report, recent log. |
| `nightshift stop [-Force]` | Stops after the current step. `-Force` kills it now; the next run saves the interrupted work as WIP. |
| `nightshift schedule [-At 23:30]` / `unschedule` | Registers or removes the daily Windows scheduled task "Night Shift - \<name\>". |
| `nightshift test` | Engine self-tests. They also run at the start of every run. |

The deadline is `-For` (a duration), `-Until` (a clock time) or the project's `stopAt`, in that order of priority.

## `.nightshift/config.json`

Everything is optional; defaults live in `lib/config.ps1`.

```jsonc
{
  "name": "chromora",                      // used for the schedule name
  "baseBranch": "develop",                 // agents branch from / merge into this
  "stopAt": "07:00",
  "models": { "builder": "sonnet", "escalate": "opus", "reviewer": "sonnet", "product": "opus" },
  "maxAttempts": 2, "agentTimeoutMinutes": 45, "gateTimeoutMinutes": 20,
  "polishCap": 4, "maxProposalsPerNight": 5,
  "batch": { "maxTasks": 3, "maxTextLength": 240 },           // consecutive short tasks of one phase share a session
  "review": { "smallDiffLines": 150, "smallModel": "haiku" },  // diffs up to N changed lines get the cheap reviewer
  "notesMaxLines": 60,                                         // report warns when NOTES.md grows past this
  "files": { "tasks": "TASKS.md", "backlog": "BACKLOG.md", "notes": "NOTES.md", "plan": "PLAN.md", "rules": ".nightshift/rules.md" },

  "gates": [                               // run in order after every attempt, by the supervisor itself
    { "name": "format",  "run": "dart format .", "autoFix": true },           // never fails; changes get committed
    { "name": "analyze", "run": "flutter analyze", "when": { "fileExists": "pubspec.yaml" } },
    { "name": "test",    "run": "flutter test", "countTests": true },         // rejects a drop in passing tests
    { "name": "coverage","run": "dart run tool/coverage_check.dart", "when": { "taskDone": "3.19" } },
    { "name": "db-test", "run": "npx supabase test db", "when": { "changed": "supabase/*" }, "services": ["supabase"] }
  ],
  // when: fileExists (all must exist) · changed (any changed path matches a wildcard) · taskDone (task is [x])
  // countTests + testCountPattern: regex whose group 1 = passing tests (default: dart/flutter summary)

  "services": {                            // started on demand, once per run
    "supabase": {
      "docker": true,                      // start Docker Desktop if needed
      "check": "npx --yes supabase status",
      "start": "npx --yes supabase start",
      "when": { "fileExists": "supabase/config.toml" },
      "forPhases": ["13", "14"],           // also start before the builder for these phases...
      "forTextMatch": "supabase"           // ...or tasks mentioning this
    }
  },

  "protectedPaths": {                      // prefix/ or exact file -> task ids allowed to edit it
    "test/architecture/": ["1.12"]         // (.nightshift/, .claude/, CLAUDE.md, TASKS.md are always protected)
  },
  "reviewExclude": [":(exclude)*.g.dart"]  // git pathspecs kept out of the reviewer's diff
}
```

**Prompts:** the defaults are in `prompts/`. To override one for a single project, copy it to
`<project>/.nightshift/prompts/<name>.md`. Placeholders you can use: `{{TASK}} {{FEEDBACK}}
{{VERIFY}} {{PROTECTED}} {{PROJECT_RULES}} {{TASKS_FILE}} {{BACKLOG_FILE}} {{NOTES_FILE}}
{{PLAN_FILE}} {{BASE}}`.

## Safety model

- Headless sessions run `claude -p --setting-sources project,local --strict-mcp-config`. Only the
  project's `.claude/settings.json` applies, not your user hooks, plugins or MCP servers. That
  allowlist is the whole permission story, and `init` writes a conservative one: no push, reset,
  switch, curl, PowerShell or WebFetch.
- The supervisor doesn't trust the agent: it runs the checks itself, and it rejects any diff that
  touches protected paths or lowers the passing-test count.
- The reviewer can only read (Read, Grep, Glob).
- Everything is local: nothing is pushed. Every session's prompt and JSON output is kept in
  `.nightshift/state/sessions/`.
- The PC stays awake during a run, and the scheduled task wakes it, runs only on AC power and
  never overlaps itself.

## Files a run produces

- `.nightshift/reports/<date>.md`, committed to `develop`: what merged, failed or was blocked,
  usage-limit sleeps, what's waiting on you, and new proposals.
- `.nightshift/state/` (gitignored): `run.log`, `sessions/`, `test-baseline.json`, `run.lock`.

## Layout

```
nightshift.ps1 / nightshift.cmd   CLI
lib/engine.ps1                    supervisor loop
lib/tasks.ps1 limits.ps1 gates.ps1 config.ps1   pure helpers (tested)
prompts/                          builder, fixer, reviewer, product, polish
templates/                        init scaffolding + presets
tests/run-tests.ps1               self-tests
```
