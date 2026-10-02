# Night Shift

An always-on **agent factory** for any git project. Headless Claude Code sessions work through
your `TASKS.md` and approved backlog, several at a time, around the clock, within your Claude
subscription:

- Every change is checked by your own tests and reviewed by a second agent.
- Each change lands on `develop` through its own pull request, merged automatically.
- When something blocks, a **resolver** with full permissions clears it.
- When the work runs out, a product agent proposes and approves more.

`main` only moves when you promote it.

```
nightshift start            (or: the watchdog starts it at logon and restarts it if it dies)
  daemon, until you stop it:
    pick work for free workers (2 by default), one per lane:
      TASKS.md phases (in order; "(parallel)" / "(after N)" phases get their own lane)
      -> approved BACKLOG.md items -> product round (new backlog, auto-approved) -> polish
    worker, in its own git worktree (outside your checkout):
      BUILDER -> CHECKS -> REVIEWER -> ready         (fixer on failure, escalate model last)
    integrator, one at a time: merge the new base in (re-check if it moved), tick the task,
      push + PR + merge  (or a local merge when there's no GitHub remote)
      conflict with the newer base -> MERGER reconciles both sides, re-checks, integrates
    blocked / failed -> RESOLVER (bypass permissions + guard): fixes permissions, config, rules,
      services, splits or rewrites tasks -> retry;  only "needs you" things go to you
    usage limit -> every worker waits for the reset (or for schedule.resumeAt), then carries on
    nothing to do -> sleeps, checks again every idleMinutes
```

## Install

```powershell
git clone <this repo> D:\repos\personal\night-shift
D:\repos\personal\night-shift\nightshift.cmd install     # puts it on your user PATH; open a new terminal
```

`nightshift` is a `.cmd` (the engine is `lib\cli.ps1`), so it runs from any PowerShell or cmd window
whatever your execution policy is.

Requirements: Windows + Windows PowerShell 5.1, git, the Claude Code CLI logged in with your
subscription, and the GitHub CLI (`gh auth login`) for the PR flow.

## Add it to a project

```powershell
nightshift init -Project D:\repos\my-app -Preset node     # generic | flutter | node | python
```

`init` creates (without overwriting anything that exists):

| File | Purpose |
|---|---|
| `.nightshift/config.json` | checks, worktree setup, services, models, workers, PR flow |
| `.nightshift/agent-settings.json` | the allowlist building agents run under (only theirs) |
| `.nightshift/rules.md` | project rules injected into every agent prompt |
| `TASKS.md` | the ordered work (`- [ ] 1.2 text`) |
| `BACKLOG.md` | ideas; `status: approved` ones get built |
| `NOTES.md` | learnings agents hand to each other (`merge=union`, so parallel appends never conflict) |
| `CLAUDE.md` section | rules for headless agents |
| `.claude/settings.json` | **your** interactive sessions: acceptEdits plus a broad allowlist, so Claude Code stops asking you to run things with `!` or edit README / rules / settings yourself |
| `.gitignore` entries, git repo, `develop` branch | |

Then commit it to `develop` (Night Shift reads config and tasks from there), then run
`nightshift dry-run`, `nightshift start` and `nightshift schedule`.

Already using an older Night Shift in a project? Run `nightshift upgrade` there. It:
- moves the agents' allowlist to `.nightshift/agent-settings.json`;
- relaxes `.claude/settings.json` for you;
- drops `stopAt` and adds `worktree.setup`;
- makes reports local;
- commits only those files to `develop`.

## Commands

Run these inside the project, or add `-Project <path>`:

| Command | What it does |
|---|---|
| `nightshift start [-For 2h \| -Until 07:00] [-Once] [-Task 3.4]` | Starts the daemon in its own minimized window and returns. Runs until stopped unless given a deadline. |
| `nightshift run [...]` | The same, in this window. |
| `nightshift status` (or just `nightshift`) | Daemon state, each worker's item and step, merges in flight, usage limit, what waits on you, the next items. |
| `nightshift logs [-Slot w1] [-Follow]` | The log, optionally one worker's. |
| `nightshift ask "..." [-Wait]` | Hands a request to the resolver: docs, rules, settings, CLAUDE.md, new tasks, local setup. It lands through checks + PR like any change. Without a running daemon it's done right away in this window. |
| `nightshift retry -Task 3.4` | Reopens a failed task. |
| `nightshift resolve [-Task 3.4]` | Sends failed tasks to the resolver now (`unblock` is an alias). |
| `nightshift pause` / `resume` | Pause: running items finish, nothing new starts. Resume also starts the daemon if needed. |
| `nightshift stop [-Force]` | Ends the daemon after the workers' current steps (`-Force`: now; their branches resume next time). It stays stopped (the watchdog won't restart it) until `start` / `resume`. |
| `nightshift schedule [-At 22:00]` / `unschedule` | Watchdog scheduled task: starts Night Shift at logon and every 10 minutes if it isn't running (and you didn't stop or pause it). `-At` also resumes it every day at that time. |
| `nightshift dry-run` | What would run next, mode, worktrees, hours. Changes nothing. |
| `nightshift test` | Engine self-tests (they also run when the daemon starts). |

## Usage limits and hours

A worker that hits the subscription's usage limit writes the reset time to `state/limit.json`; every
worker waits for it, and the daemon starts nothing new.
- **Reset time unknown:** it sleeps `limitFallbackSleepMinutes`, then checks with a one-line haiku session before spending a real one.
- **`schedule.resumeAt: "22:00"`:** after a limit it resumes at that hour instead of right at the reset.
- **`schedule.activeHours: ["22:00-07:00"]`:** new work only starts inside those windows. Empty means any time.

## `.nightshift/config.json`

Everything is optional; defaults live in `lib/config.ps1`.

```jsonc
{
  "name": "chromora",
  "baseBranch": "develop",                 // PRs go into this; main is yours
  "branchPrefix": "ns/",
  "workers": 2,                            // parallel builder sessions (the resolver has its own slot)
  "worktree": {
    "root": "",                            // default: <project>.nightshift next to the project
    "setup": ["flutter pub get"],          // per-worktree installs; re-run when a lockfile changes
    "copy": [".env"]                       // untracked files each worktree needs
  },
  "parallel": { "phases": "sequential", "planner": true },  // planner: parallel lanes from task dependencies
  "schedule": { "activeHours": [], "resumeAt": "", "idleMinutes": 30 },
  "pr": { "mode": "auto", "mergeMethod": "merge", "requireChecks": "auto" },
  //   auto: PRs when there's an origin remote and gh is logged in, local merges otherwise; on | off
  //   requireChecks auto: if the repo requires status checks, enable auto-merge and wait for them
  "models": { "builder": "sonnet", "escalate": "opus", "reviewer": "sonnet", "product": "opus", "resolver": "opus", "planner": "sonnet" },
  "maxAttempts": 3, "escalateAfter": 2,
  "agentTimeoutMinutes": 45, "gateTimeoutMinutes": 20,
  "agentMaxBudgetUsd": 4,                  // per-session cap (--max-budget-usd); 0 disables
  "product": { "autoApprove": true, "maxRoundsPerDay": 6, "maxProposals": 5, "maxAutoApprovePerRound": 3, "cooldownHours": 4, "focus": [] },
  "polishCap": 4,                          // per day
  "resolver": { "enabled": true, "maxPerItem": 2, "maxBudgetUsd": 8, "healthAfterFailures": 3 },
  "notify": { "toast": true, "ntfyUrl": "" },  // when something needs you
  "batch": { "maxTasks": 3, "maxTextLength": 240 },
  "review": { "smallDiffLines": 300, "smallModel": "haiku" },
  "notesMaxLines": 60,
  "ruleSections": "(?i)\\brules\\b",
  "files": { "tasks": "TASKS.md", "backlog": "BACKLOG.md", "notes": "NOTES.md", "plan": "PLAN.md", "rules": ".nightshift/rules.md" },

  "gates": [                               // run in order after every attempt, by the supervisor itself
    { "name": "format",  "run": "dart format .", "autoFix": true },
    { "name": "test",    "run": "flutter test", "countTests": true },         // rejects a drop in passing tests
    { "name": "db-test", "run": "npx supabase test db", "when": { "changed": "supabase/*" }, "services": ["supabase"], "exclusive": true }
  ],
  // when: fileExists · changed · taskDone.  exclusive: one worker at a time (shared ports, databases)

  "services": {
    "supabase": { "docker": true, "check": "npx --yes supabase status", "start": "npx --yes supabase start",
                  "when": { "fileExists": "supabase/config.toml" }, "forPhases": ["13"], "forTextMatch": "supabase", "exclusive": true }
  },
  "protectedPaths": { "test/architecture/": ["1.12"] },  // + .nightshift/, .claude/, CLAUDE.md, TASKS.md always
  "reviewExclude": [":(exclude)*.g.dart"]
}
```

**Lanes.** Tasks in `TASKS.md` stay in file order by default, and a failed task holds back the
rest of its phase. Each approved backlog item is its own lane. A lane stays busy until its item is
integrated, so the next task always builds on the previous one.

Which phases can run side by side is worked out by a read-only **planner** session (`models.planner`).
It runs whenever two or more phases have open work and the tasks change (not when tasks get ticked).
A phase B waits for phase A when B needs what A builds, when they'd edit the same files, or when B
depends on a decision A makes; when unsure, it waits. Its plan shows up as `[plan]` in the report.

Your own tags override it: mark a phase heading `(parallel)` to run it alongside the others, or
`(after 3)` to run it once phase 3 is done. Set `parallel.planner: false` to use only your tags, or
`parallel.phases: "parallel"` to run every phase in its own lane.

**Conflicts.** When a finished branch conflicts with a base that moved meanwhile, the work isn't
thrown away. A **merger** session gets the half-done merge and reconciles both sides: it reads both
histories, keeps both intents and invents nothing. Then the checks run again and it is integrated.
Only if that fails is the item rebuilt on the new base.

## The resolver

Building agents run under a tight allowlist (`.nightshift/agent-settings.json` plus engine denies on
`.nightshift/`, `.claude/`, `CLAUDE.md`, the tasks file and every branch-moving git command). When
one ends `BLOCKED`, or fails all its attempts, the **resolver** gets the failure and the end of
the last session. It runs `claude --dangerously-skip-permissions` in its own worktree and can:

- allow the command the agents needed;
- add a service (e.g. a local Postgres in Docker), setup commands or files to copy;
- fix the rules or `CLAUDE.md`;
- split, rewrite or add prerequisite tasks;
- install tools;
- clean temp folders.

Its repo changes go through the same checks and PR. It then says `retry` (the task is reopened,
with a note for the next builder), or asks you one precise thing (`[needs you]` in status and the
report, plus a Windows toast). Everything else keeps running meanwhile. It also runs when:
- several items in a row fail the same check (is the base broken?);
- the daemon keeps crashing the same way;
- your `develop` conflicts with the integration branch;
- you `nightshift ask` for something.

**Its limits.** A PreToolUse guard hook (`lib/guard.ps1`) and deny rules block:
- force-pushes, pushes to `main` / `master` / the base branch, and deleting branches;
- `git reset --hard` and history rewrites;
- credentials (`~/.ssh`, `~/.claude*`, keys);
- writing or deleting outside the project and its worktrees;
- destructive machine commands.

After every session the supervisor checks that `main`, the base and the integration branch only
moved forward. If not, it restores the local refs and pauses until you look.

## Safety model

- Headless sessions use only the project's settings source (your user-level hooks and plugins
  don't apply) plus `--settings` with the role's policy; deny rules there win.
- The supervisor doesn't trust the agents:
  - It runs the checks itself.
  - It reverts changes to protected paths.
  - It rejects a drop in the passing-test count.
  - It re-runs the checks when the base moved before merging.
- Workers never merge or push; only the integrator does, one item at a time.
- Your checkout is never switched or touched. Local `develop` is fast-forwarded only when that
  can't affect uncommitted work.
- Every session's prompt and JSON output is kept in `.nightshift/state/sessions/`.
- A session whose result is complete but whose process doesn't exit (a child process holding it
  open) is ended after a minute, rather than eating the whole `agentTimeoutMinutes`.
- The PC stays awake while the daemon runs.

## Files a run produces

- `.nightshift/reports/<date>.md` (local, gitignored): what merged (with PR links), failed, was
  resolved, needs you, usage-limit waits, proposals.
- `.nightshift/state/` (gitignored):
  - `run.log`, `sessions/`
  - `queue.json` (failed / needs-you state per item), `unblock-hints.json`, `daily.json`, `limit.json`, `phase-plan.json`
  - `daemon.json`, `slots/`, `jobs/`, `results/`, `inbox/`, `settings/`
- `<project>.nightshift/` next to the project: the worktrees (`w1`, `w2`, `integrate`, `resolver`).

## Layout

```
nightshift.cmd           entry point (put this folder on PATH)
lib/cli.ps1              commands
lib/daemon.ps1           scheduler, integration (PRs / local merges), queue state, resolver queue
lib/worker.ps1           one job in one worktree: build/check/review/fix, product, resolver, merge, plan
lib/engine.ps1           shared core: git, agents, usage limits, services, checks, review
lib/guard.ps1            the resolver's PreToolUse guard
lib/tasks.ps1 limits.ps1 gates.ps1 config.ps1   pure helpers (tested)
prompts/                 builder, fixer, reviewer, product, polish, resolver, merger, planner
templates/               init scaffolding + presets
tests/run-tests.ps1      self-tests
```
