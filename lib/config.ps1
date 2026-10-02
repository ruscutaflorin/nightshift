# Project configuration: discovery, defaults, merging, durations. Pure where possible (testable).

$script:DefaultConfigJson = @'
{
  "name": "",
  "baseBranch": "develop",
  "branchPrefix": "ns/",
  "workers": 2,
  "worktree": { "root": "", "setup": [], "copy": [] },
  "parallel": { "phases": "sequential", "planner": true },
  "schedule": { "activeHours": [], "resumeAt": "", "idleMinutes": 30 },
  "pr": { "mode": "auto", "mergeMethod": "merge", "requireChecks": "auto" },
  "models": { "builder": "sonnet", "escalate": "opus", "reviewer": "sonnet", "product": "opus", "resolver": "opus", "planner": "sonnet" },
  "maxAttempts": 3,
  "escalateAfter": 2,
  "agentTimeoutMinutes": 45,
  "gateTimeoutMinutes": 20,
  "polishCap": 4,
  "product": { "autoApprove": true, "maxRoundsPerDay": 6, "maxProposals": 5, "maxAutoApprovePerRound": 3, "cooldownHours": 4, "focus": [] },
  "resolver": { "enabled": true, "maxPerItem": 2, "maxBudgetUsd": 8, "healthAfterFailures": 3 },
  "notify": { "toast": true, "ntfyUrl": "" },
  "limitFallbackSleepMinutes": 30,
  "batch": { "maxTasks": 3, "maxTextLength": 240 },
  "review": { "smallDiffLines": 300, "smallModel": "haiku" },
  "notesMaxLines": 60,
  "ruleSections": "(?i)\\brules\\b",
  "agentMaxBudgetUsd": 4,
  "files": { "tasks": "TASKS.md", "backlog": "BACKLOG.md", "notes": "NOTES.md", "plan": "PLAN.md", "rules": ".nightshift/rules.md" },
  "gates": [],
  "services": {},
  "protectedPaths": {},
  "reviewExclude": [":(exclude)*.lock", ":(exclude)package-lock.json", ":(exclude)**/*.png", ":(exclude)**/*.jpg"]
}
'@

# Deep-merge two PSCustomObjects: objects merge key by key, everything else (arrays, scalars) is replaced.
function Merge-Config($Base, $Override) {
    if ($null -eq $Override) { return $Base }
    if ($null -eq $Base -or -not ($Base -is [pscustomobject]) -or -not ($Override -is [pscustomobject])) { return $Override }
    $result = [pscustomobject]@{}
    foreach ($p in $Base.PSObject.Properties) { $result | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
    foreach ($p in $Override.PSObject.Properties) {
        if ($result.PSObject.Properties[$p.Name]) {
            $result.($p.Name) = Merge-Config $result.($p.Name) $p.Value
        } else {
            $result | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value
        }
    }
    return $result
}

# Walk up from $Start to the first directory containing .nightshift/config.json.
function Find-ProjectRoot([string]$Start) {
    $dir = (Resolve-Path $Start).Path
    while ($dir) {
        if (Test-Path (Join-Path $dir '.nightshift\config.json')) { return $dir }
        $parent = Split-Path $dir -Parent
        if ($parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

function Read-ProjectConfig([string]$Root) {
    $defaults = $script:DefaultConfigJson | ConvertFrom-Json
    $project = Get-Content (Join-Path $Root '.nightshift\config.json') -Raw | ConvertFrom-Json
    $config = Merge-Config $defaults $project
    if (-not $config.name) { $config.name = Split-Path $Root -Leaf }
    # Older keys still honored.
    if ($project.PSObject.Properties['maxProposalsPerNight'] -and -not ($project.product -and $project.product.PSObject.Properties['maxProposals'])) {
        $config.product.maxProposals = $project.maxProposalsPerNight
    }
    if ($project.unblock -and $project.unblock.enabled -eq $false -and -not $project.resolver) { $config.resolver.enabled = $false }
    if (-not $config.models.resolver) { $config.models | Add-Member -NotePropertyName resolver -NotePropertyValue 'opus' -Force }
    return $config
}

# Denies every building agent (builder, fixer, polish, product) gets on top of the project's agent
# settings: engine-owned files, and the git/gh commands only the supervisor runs.
$script:EngineAgentDeny = @(
    'Edit(.nightshift/**)', 'Edit(/.nightshift/**)', 'Write(.nightshift/**)', 'Write(/.nightshift/**)',
    'Edit(.claude/**)', 'Edit(/.claude/**)', 'Write(.claude/**)', 'Write(/.claude/**)',
    'Edit(CLAUDE.md)', 'Edit(/CLAUDE.md)', 'Write(CLAUDE.md)', 'Write(/CLAUDE.md)',
    'Bash(git push:*)', 'Bash(git reset:*)', 'Bash(git rebase:*)', 'Bash(git merge:*)', 'Bash(git switch:*)',
    'Bash(git checkout:*)', 'Bash(git branch:*)', 'Bash(git stash:*)', 'Bash(git clean:*)', 'Bash(git remote:*)',
    'Bash(git worktree:*)', 'Bash(git tag:*)', 'Bash(git config:*)', 'Bash(git update-ref:*)', 'Bash(gh:*)'
)

# What the resolver may never do even with permission checks bypassed (lib/guard.ps1 enforces the rest).
$script:ResolverDeny = @(
    'Bash(git push --force:*)', 'Bash(git push -f:*)', 'Bash(git push --force-with-lease:*)', 'Bash(git reset --hard:*)',
    'Bash(git filter-branch:*)', 'Bash(git filter-repo:*)', 'Bash(gh repo delete:*)', 'Bash(gh repo create:*)',
    'Read(~/.ssh/**)', 'Edit(~/.ssh/**)', 'Read(~/.claude.json)', 'Edit(~/.claude.json)', 'Edit(~/.claude/**)', 'Write(~/.claude/**)'
)

# Added to your interactive sessions' project settings so Claude Code stops asking you to run
# commands with `!` or edit README / rules / settings files yourself.
$script:HumanAllow = @('Read', 'Edit', 'Write', 'Glob', 'Grep', 'WebSearch', 'WebFetch', 'PowerShell', 'Bash(git:*)', 'Bash(gh pr:*)', 'Bash(gh run:*)', 'Bash(nightshift:*)')
$script:HumanDeny = @('Bash(git push --force:*)', 'Bash(git push -f:*)', 'Bash(git push origin main:*)', 'Bash(git reset --hard:*)')

# The settings a building agent runs under: the project's agent policy (.nightshift/agent-settings.json,
# or the old shared .claude/settings.json) plus the engine's denies and the tasks file.
function New-AgentSettings($ProjectSettings, [string]$TasksFile) {
    $allow = @(); $deny = @()
    if ($ProjectSettings -and $ProjectSettings.permissions) {
        $allow = @($ProjectSettings.permissions.allow | Where-Object { $_ })
        $deny = @($ProjectSettings.permissions.deny | Where-Object { $_ })
    }
    $deny += $script:EngineAgentDeny
    if ($TasksFile) {
        $t = $TasksFile -replace '\\', '/'
        $deny += @("Edit($t)", "Edit(/$t)", "Write($t)", "Write(/$t)")
    }
    return [pscustomobject]@{ permissions = [pscustomobject]@{ allow = @($allow | Select-Object -Unique); deny = @($deny | Select-Object -Unique) } }
}

# The resolver's settings: hard denies plus the guard hook on every shell and file tool.
function New-ResolverSettings([string]$HookCommand) {
    return [pscustomobject]@{
        permissions = [pscustomobject]@{ deny = $script:ResolverDeny }
        hooks       = [pscustomobject]@{
            PreToolUse = @([pscustomobject]@{
                    matcher = 'Bash|PowerShell|Read|Edit|Write|MultiEdit|NotebookEdit'
                    hooks   = @([pscustomobject]@{ type = 'command'; command = $HookCommand; timeout = 60 })
                })
        }
    }
}

# Your interactive sessions' version of a project's .claude/settings.json: the agent-only denies
# ($AgentOnlyDeny) removed, the human allowlist (+ $ExtraAllow, e.g. the preset's toolchain) added,
# acceptEdits as the default mode unless one is set. Everything else in the file is kept.
function ConvertTo-HumanSettings($Settings, [string[]]$AgentOnlyDeny, [string[]]$ExtraAllow) {
    $obj = if ($Settings) { $Settings | ConvertTo-Json -Depth 20 | ConvertFrom-Json } else { [pscustomobject]@{} }
    if (-not $obj.PSObject.Properties['permissions'] -or -not $obj.permissions) {
        $obj | Add-Member -NotePropertyName permissions -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $p = $obj.permissions
    $drop = @($AgentOnlyDeny) + $script:EngineAgentDeny + @('PowerShell', 'WebFetch')
    $deny = @(@($p.deny | Where-Object { $_ -and ($drop -notcontains $_) }) + $script:HumanDeny | Select-Object -Unique)
    $allow = @(@($p.allow | Where-Object { $_ }) + $script:HumanAllow + @($ExtraAllow | Where-Object { $_ }) | Select-Object -Unique)
    $p | Add-Member -NotePropertyName allow -NotePropertyValue $allow -Force
    $p | Add-Member -NotePropertyName deny -NotePropertyValue $deny -Force
    if (-not $p.PSObject.Properties['defaultMode']) { $p | Add-Member -NotePropertyName defaultMode -NotePropertyValue 'acceptEdits' }
    return $obj
}

# Protected paths = engine-owned paths (never editable by agents) + the project's own map.
function Get-ProtectedMap($Config) {
    $map = [pscustomobject]@{}
    foreach ($p in @('.nightshift/', '.claude/', 'CLAUDE.md', $Config.files.tasks)) {
        $map | Add-Member -NotePropertyName $p -NotePropertyValue @() -Force
    }
    foreach ($p in $Config.protectedPaths.PSObject.Properties) {
        $map | Add-Member -NotePropertyName $p.Name -NotePropertyValue @($p.Value) -Force
    }
    return $map
}

# "2h", "90m", "1h30m", "45" (minutes) -> TimeSpan. Throws on garbage.
function ConvertTo-Duration([string]$Text) {
    $t = $Text.Trim().ToLowerInvariant()
    if ($t -match '^\d+$') { return [TimeSpan]::FromMinutes([int]$t) }
    if ($t -match '^(?:(\d+)h)?\s*(?:(\d+)m)?$' -and ($Matches[1] -or $Matches[2])) {
        $h = if ($Matches[1]) { [int]$Matches[1] } else { 0 }
        $m = if ($Matches[2]) { [int]$Matches[2] } else { 0 }
        return New-Object TimeSpan($h, $m, 0)
    }
    throw "Can't parse duration '$Text' (use e.g. 2h, 90m, 1h30m)"
}
