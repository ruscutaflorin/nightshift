<#
.SYNOPSIS
  Night Shift - an always-on Claude Code agent factory for any git project.

.DESCRIPTION
  Commands (run inside a project, or pass -Project <path>):
    start       start the daemon in the background (own minimized window) and return
    run         run the daemon in THIS window
    status      what is running, what's next, what waits on you
    logs        recent log lines (-Slot w1, -Follow)
    ask "..."   have the resolver do something in the repo for you (docs, rules, settings, tasks...)
    retry       reopen a failed task (-Task 3.4)
    resolve     send failed tasks to the resolver now (-Task 3.4)
    pause       finish what's running, start nothing new (the daemon stays up)
    resume      undo pause / stop, and start the daemon if it isn't running
    stop        stop the daemon after its current steps (-Force kills it now); stays stopped until start/resume
    dry-run     show what would run next; changes nothing
    schedule    keep it running: start at logon and restart within 10 min if it dies (-At 22:00 also resumes daily)
    unschedule  remove that
    init        scaffold Night Shift in a project (-Preset generic|flutter|node|python)
    upgrade     move an older project to this version (agent settings, worktrees, reports)
    install     put nightshift on your PATH
    test        run the engine self-tests

  Runs until stopped. -For 2h | -Until 07:00 give one run a deadline.

.EXAMPLE
  nightshift init -Project D:\repos\my-app -Preset node
  nightshift start
  nightshift ask "Document the new env vars in README.md"
  nightshift status
  nightshift run -Once -Task 1.3
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('init', 'upgrade', 'install', 'dry-run', 'run', 'start', 'ensure', 'stop', 'pause', 'resume', 'status', 'logs',
        'ask', 'retry', 'resolve', 'unblock', 'schedule', 'unschedule', 'test', 'help', 'worker')]
    [string]$Command = 'status',
    [Parameter(Position = 1)]
    [string]$Text,
    [string]$Project = (Get-Location).Path,
    [string]$For,
    [string]$Until,
    [switch]$Once,
    [string]$Task,
    [string]$At,
    [ValidateSet('generic', 'flutter', 'node', 'python')]
    [string]$Preset = 'generic',
    [switch]$Force,
    [switch]$Resume,
    [switch]$Wait,
    [switch]$Follow,
    [string]$Slot
)

$ErrorActionPreference = 'Stop'
$EngineDir = Split-Path $PSScriptRoot -Parent
foreach ($lib in 'tasks', 'limits', 'gates', 'config', 'guard', 'engine', 'worker', 'daemon') { . (Join-Path $PSScriptRoot "$lib.ps1") }
$CliPath = $PSCommandPath

function Get-Root {
    $root = Find-ProjectRoot $Project
    if (-not $root) { throw "No .nightshift/config.json found at or above '$Project'. Run: nightshift init -Project <path>" }
    return $root
}

function Get-RunDeadline {
    if ($For) { return (Get-Date).Add((ConvertTo-Duration $For)) }
    if ($Until) { return Get-Deadline $Until (Get-Date) }
    return [datetime]::MaxValue
}

function Get-ScheduleName { return "Night Shift - $($script:Config.name)" }

function Write-Utf8([string]$Path, [string]$Content) {
    [IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

# Engine + config from the integrated base (the integrate worktree) when it exists.
function Open-Project([datetime]$Deadline = [datetime]::MaxValue) {
    $root = Get-Root
    Initialize-Engine $root $EngineDir $Deadline
    $int = Get-SlotPath 'integrate'
    if (Test-Path (Join-Path $int '.git')) { Import-ProjectConfig $int; Set-WorkDir $int }
    $script:Running = @{}; $script:Pending = New-Object System.Collections.ArrayList; $script:AwaitingPr = $null
    $script:MergeQueue = New-Object System.Collections.ArrayList
    $script:NoBatch = New-Object System.Collections.ArrayList; $script:Overlay = Read-StateMap 'queue.json'
    return $root
}

function Start-Background([string]$Root, [switch]$KeepPause) {
    if (-not $KeepPause) { Remove-Item $script:PauseFile -ErrorAction SilentlyContinue }
    if ($p = Get-RunningPid) { Write-Host "Already running (PID $p). nightshift status / nightshift stop"; return }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$CliPath`"", 'run', '-Project', "`"$Root`"")
    if ($For) { $argList += @('-For', $For) }
    if ($Until) { $argList += @('-Until', $Until) }
    if ($Once) { $argList += '-Once' }
    if ($Task) { $argList += @('-Task', $Task) }
    $proc = Start-Process powershell.exe -ArgumentList ($argList -join ' ') -WorkingDirectory $Root -WindowStyle Minimized -PassThru
    Write-Host "Started Night Shift for $($script:Config.name) (PID $($proc.Id)), $(if ($For -or $Until) { "until $(Get-RunDeadline)" } else { 'until stopped' })."
    Write-Host 'Status: nightshift status    Log: nightshift logs -Follow    Stop: nightshift stop'
}

function New-InboxRequest([hashtable]$Request) {
    $id = if ($Request.id) { $Request.id } else { "req-$(Get-Stamp)-$(Get-Random -Maximum 999)" }
    $Request.id = $id
    Write-JsonFile (Join-Path $script:InboxDir "$(Get-Stamp)-$id.json") ([pscustomobject]$Request)
    return $id
}

# Gates whose names look like dependency installs become the worktree setup commands.
function Get-SetupFromGates($Gates) {
    return @(@($Gates) | Where-Object { $_ -and $_.name -match '(?i)install|pub-get|deps|bootstrap|restore' } | ForEach-Object { $_.run })
}

function Write-ClaudeSection([string]$Root) {
    $claudeMd = Join-Path $Root 'CLAUDE.md'
    $section = [IO.File]::ReadAllText((Join-Path $EngineDir 'templates\claude-section.md')).TrimEnd() + "`n"
    if (-not (Test-Path $claudeMd)) { Write-Utf8 $claudeMd $section; return 'CLAUDE.md' }
    $text = [IO.File]::ReadAllText($claudeMd)
    $pattern = '(?ms)^## Night[- ][Ss]hift agents.*?(?=^## |\z)'
    if ($text -match $pattern) {
        $new = [regex]::Replace($text, $pattern, ($section.TrimEnd() + "`n`n").Replace('$', '$$'), 1).TrimEnd() + "`n"
        if ($new -ne $text) { Write-Utf8 $claudeMd $new; return 'CLAUDE.md (Night Shift section updated)' }
        return ''
    }
    Write-Utf8 $claudeMd ($text.TrimEnd() + "`n`n" + $section)
    return 'CLAUDE.md (section appended)'
}

function Add-Lines([string]$Path, [string[]]$Lines, [string]$Header) {
    $text = if (Test-Path $Path) { [IO.File]::ReadAllText($Path) } else { '' }
    $missing = @($Lines | Where-Object { $text -notmatch "(?m)^$([regex]::Escape($_))\s*$" })
    if (-not $missing) { return $false }
    $add = $(if ($text -and -not $text.EndsWith("`n")) { "`n" } else { '' }) + "`n$Header`n" + ($missing -join "`n") + "`n"
    [IO.File]::AppendAllText($Path, $add, (New-Object System.Text.UTF8Encoding($false)))
    return $true
}

function Register-Watchdog([string]$Root) {
    $name = Get-ScheduleName
    $user = "$env:USERDOMAIN\$env:USERNAME"
    # Interactive = runs in your logged-on session (Claude Code login, Docker Desktop); lock the screen, don't sign out.
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -WakeToRun -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable
    $ensure = New-ScheduledTaskAction -Execute 'powershell.exe' -WorkingDirectory $Root `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$CliPath`" ensure -Project `"$Root`""
    $triggers = @(
        (New-ScheduledTaskTrigger -AtLogOn -User $user),
        (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 10))
    )
    Register-ScheduledTask -TaskName $name -Action $ensure -Trigger $triggers -Settings $settings -Principal $principal `
        -Description "Night Shift watchdog for $Root" -Force | Out-Null
    $resumeName = "$name (resume)"
    if ($At) {
        $resume = New-ScheduledTaskAction -Execute 'powershell.exe' -WorkingDirectory $Root `
            -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$CliPath`" ensure -Resume -Project `"$Root`""
        Register-ScheduledTask -TaskName $resumeName -Action $resume -Trigger (New-ScheduledTaskTrigger -Daily -At $At) -Settings $settings -Principal $principal `
            -Description "Night Shift: resume daily for $Root" -Force | Out-Null
    }
    return $name
}

switch ($Command) {
    'help' { Get-Help $PSCommandPath -Detailed; exit 0 }

    'test' {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $EngineDir 'tests\run-tests.ps1')
        exit $LASTEXITCODE
    }

    'install' {
        $path = [Environment]::GetEnvironmentVariable('Path', 'User')
        $parts = @($path -split ';' | Where-Object { $_ })
        if ($parts | Where-Object { $_.TrimEnd('\') -ieq $EngineDir.TrimEnd('\') }) { Write-Host "Already on your PATH: $EngineDir" }
        else {
            [Environment]::SetEnvironmentVariable('Path', (($parts + $EngineDir) -join ';'), 'User')
            Write-Host "Added $EngineDir to your user PATH. Open a new terminal, then: nightshift help"
        }
        exit 0
    }

    'worker' {
        $root = Get-Root
        Initialize-Engine $root $EngineDir ([datetime]::MaxValue)
        Invoke-WorkerProcess $Slot
        exit 0
    }

    'init' {
        $root = (Resolve-Path $Project).Path
        $templates = Join-Path $EngineDir 'templates'
        $presetData = Get-Content (Join-Path $templates "presets\$Preset.json") -Raw | ConvertFrom-Json
        $ns = Join-Path $root '.nightshift'
        New-Item -ItemType Directory -Force -Path $ns | Out-Null
        $created = @()

        $cfgPath = Join-Path $ns 'config.json'
        if (-not (Test-Path $cfgPath)) {
            $cfg = $presetData.config
            $cfg | Add-Member -NotePropertyName name -NotePropertyValue (Split-Path $root -Leaf) -Force
            $setup = Get-SetupFromGates $cfg.gates
            if ($setup) { $cfg | Add-Member -NotePropertyName worktree -NotePropertyValue ([pscustomobject]@{ setup = $setup; copy = @() }) -Force }
            Write-Utf8 $cfgPath ($cfg | ConvertTo-Json -Depth 10)
            $created += '.nightshift/config.json'
        }
        $agentPath = Join-Path $ns 'agent-settings.json'
        if (-not (Test-Path $agentPath)) {
            $base = Get-Content (Join-Path $templates 'agent-settings.base.json') -Raw | ConvertFrom-Json
            $base.permissions.allow = @($base.permissions.allow) + @($presetData.allow)
            $base.permissions.deny = @($base.permissions.deny) + @($presetData.deny)
            Write-Utf8 $agentPath ($base | ConvertTo-Json -Depth 10)
            $created += '.nightshift/agent-settings.json'
        }
        foreach ($f in @(
                @{ src = 'rules.md'; dst = '.nightshift\rules.md' },
                @{ src = 'TASKS.md'; dst = 'TASKS.md' },
                @{ src = 'BACKLOG.md'; dst = 'BACKLOG.md' },
                @{ src = 'NOTES.md'; dst = 'NOTES.md' })) {
            $dst = Join-Path $root $f.dst
            if (-not (Test-Path $dst)) { Copy-Item (Join-Path $templates $f.src) $dst; $created += $f.dst }
        }
        $c = Write-ClaudeSection $root
        if ($c) { $created += $c }

        $settingsPath = Join-Path $root '.claude\settings.json'
        $current = if (Test-Path $settingsPath) { Get-Content $settingsPath -Raw | ConvertFrom-Json } else { $null }
        New-Item -ItemType Directory -Force -Path (Split-Path $settingsPath) | Out-Null
        $agentDeny = @((Get-Content (Join-Path $templates 'agent-settings.base.json') -Raw | ConvertFrom-Json).permissions.deny) + @($presetData.deny)
        Write-Utf8 $settingsPath ((ConvertTo-HumanSettings $current $agentDeny @($presetData.allow)) | ConvertTo-Json -Depth 20)
        $created += '.claude/settings.json (your interactive sessions)'

        if (Add-Lines (Join-Path $root '.gitignore') @('.nightshift/state/', '.nightshift/STOP', '.nightshift/reports/') '# Night Shift runtime state') { $created += '.gitignore (entries)' }
        if (Add-Lines (Join-Path $root '.gitattributes') @('NOTES.md merge=union') '# Night Shift: parallel agents append notes') { $created += '.gitattributes (NOTES.md merge=union)' }

        Push-Location $root
        try {
            if (-not (Test-Path '.git')) { & git init -q -b main; $created += 'git repo (main)' }
            $baseBranch = (Get-Content $cfgPath -Raw | ConvertFrom-Json).baseBranch
            if (-not $baseBranch) { $baseBranch = 'develop' }
            & git rev-parse --verify -q HEAD *> $null
            if ($LASTEXITCODE -ne 0) { & git add -A; & git commit -q -m 'chore: initialize night shift' }
            & git rev-parse --verify -q $baseBranch *> $null
            if ($LASTEXITCODE -ne 0) { & git branch $baseBranch; $created += "branch $baseBranch" }
        } finally { Pop-Location }

        Write-Host "Initialized Night Shift in $root ($Preset preset)."
        $created | ForEach-Object { Write-Host "  + $_" }
        Write-Host ''
        Write-Host 'Next:'
        Write-Host '  1. Fill TASKS.md (and PLAN.md); tune .nightshift/config.json (checks, worktree.setup) and .nightshift/rules.md.'
        Write-Host "  2. Commit it to $baseBranch (Night Shift reads config and tasks from that branch)."
        Write-Host '  3. nightshift dry-run   ->   nightshift start   ->   nightshift schedule'
        exit 0
    }

    'upgrade' {
        $root = Get-Root
        $templates = Join-Path $EngineDir 'templates'
        $ns = Join-Path $root '.nightshift'
        $changed = @(); $paths = @()

        $cfgPath = Join-Path $ns 'config.json'
        $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
        $cfgChanged = $false
        if ($cfg.PSObject.Properties['stopAt']) { $cfg.PSObject.Properties.Remove('stopAt'); $cfgChanged = $true; $changed += 'config: removed stopAt (runs until stopped; use schedule.activeHours to limit hours)' }
        if (-not $cfg.PSObject.Properties['branchPrefix']) { $cfg | Add-Member -NotePropertyName branchPrefix -NotePropertyValue 'night/'; $cfgChanged = $true; $changed += 'config: branchPrefix night/ (keeps existing branches resumable)' }
        if (-not $cfg.PSObject.Properties['worktree']) {
            $setup = Get-SetupFromGates $cfg.gates
            $cfg | Add-Member -NotePropertyName worktree -NotePropertyValue ([pscustomobject]@{ setup = $setup; copy = @() })
            $cfgChanged = $true; $changed += "config: worktree.setup = $(if ($setup) { $setup -join ' ; ' } else { '(none)' })"
        }
        if ($cfgChanged) { Write-Utf8 $cfgPath ($cfg | ConvertTo-Json -Depth 20); $paths += '.nightshift/config.json' }

        $settingsPath = Join-Path $root '.claude\settings.json'
        $current = if (Test-Path $settingsPath) { Get-Content $settingsPath -Raw | ConvertFrom-Json } else { $null }
        $agentPath = Join-Path $ns 'agent-settings.json'
        if (-not (Test-Path $agentPath)) {
            $policy = if ($current -and $current.permissions) { [pscustomobject]@{ permissions = [pscustomobject]@{ allow = @($current.permissions.allow); deny = @($current.permissions.deny) } } }
            else { Get-Content (Join-Path $templates 'agent-settings.base.json') -Raw | ConvertFrom-Json }
            Write-Utf8 $agentPath ($policy | ConvertTo-Json -Depth 10)
            $paths += '.nightshift/agent-settings.json'; $changed += 'agent permissions moved to .nightshift/agent-settings.json'
        }
        $agentDeny = @((Get-Content $agentPath -Raw | ConvertFrom-Json).permissions.deny) + @((Get-Content (Join-Path $templates 'agent-settings.base.json') -Raw | ConvertFrom-Json).permissions.deny)
        $human = ConvertTo-HumanSettings $current $agentDeny @()
        $humanJson = $human | ConvertTo-Json -Depth 20
        if (-not $current -or ($current | ConvertTo-Json -Depth 20) -ne $humanJson) {
            New-Item -ItemType Directory -Force -Path (Split-Path $settingsPath) | Out-Null
            Write-Utf8 $settingsPath $humanJson
            $paths += '.claude/settings.json'; $changed += '.claude/settings.json is now for your interactive sessions (agent-only denies removed, acceptEdits, broad allowlist)'
        }
        $c = Write-ClaudeSection $root
        if ($c) { $paths += 'CLAUDE.md'; $changed += $c }
        if (Add-Lines (Join-Path $root '.gitignore') @('.nightshift/state/', '.nightshift/STOP', '.nightshift/reports/') '# Night Shift runtime state') { $paths += '.gitignore'; $changed += '.gitignore: reports are local now' }
        if (Add-Lines (Join-Path $root '.gitattributes') @('NOTES.md merge=union') '# Night Shift: parallel agents append notes') { $paths += '.gitattributes'; $changed += '.gitattributes: NOTES.md merge=union' }

        Push-Location $root
        try {
            $untrack = @(& git ls-files -- '.nightshift/reports').Count -gt 0
            if ($untrack) { $changed += 'reports untracked (kept on disk)' }
            $base = $cfg.baseBranch; if (-not $base) { $base = 'develop' }
            $branch = (& git branch --show-current).Trim()
            Write-Host "Upgraded $root"
            $changed | ForEach-Object { Write-Host "  * $_" }
            if (-not $paths -and -not $untrack) { Write-Host '  (already up to date)' }
            elseif ($branch -eq $base) {
                # Commit exactly these files through a temporary index: whatever you have staged or
                # changed elsewhere stays as it is.
                $tmpIndex = Join-Path ([IO.Path]::GetTempPath()) "nightshift-index-$PID"
                $env:GIT_INDEX_FILE = $tmpIndex
                try {
                    & git read-tree HEAD
                    if ($paths) { & git add -- @($paths) }
                    if ($untrack) { & git rm -r -q --cached --ignore-unmatch -- '.nightshift/reports' | Out-Null }
                    $tree = (& git write-tree).Trim()
                } finally { Remove-Item Env:\GIT_INDEX_FILE; Remove-Item $tmpIndex -ErrorAction SilentlyContinue }
                $commit = (& git commit-tree $tree -p HEAD -m 'chore: upgrade night shift').Trim()
                & git update-ref -m 'nightshift upgrade' HEAD $commit
                & git reset -q -- @($paths + $(if ($untrack) { '.nightshift/reports' }))
                Write-Host "Committed to $base (only these files; your other changes are untouched)."
            } else {
                Write-Host ''
                Write-Host "Commit these to $base (Night Shift reads config from there): $(@($paths + $(if ($untrack) { 'git rm -r --cached .nightshift/reports' })) -join ', ')"
            }
        } finally { Pop-Location }
        Initialize-Engine $root $EngineDir ([datetime]::MaxValue)
        if (Get-ScheduledTask -TaskName (Get-ScheduleName) -ErrorAction SilentlyContinue) { Register-Watchdog $root | Out-Null; Write-Host 'Watchdog schedule updated.' }
        exit 0
    }

    'dry-run' {
        $root = Open-Project (Get-RunDeadline)
        $script:ForcedTask = $Task; $script:ForcedTaskUsed = $false
        $hasOrigin = Test-Git 'remote get-url origin' $root
        $int = Get-SlotPath 'integrate'
        if (Test-Path (Join-Path $int '.git')) {
            $script:PrMode = [bool]((Read-JsonFile (Join-Path $script:StateDir 'daemon.json')).mode -eq 'pr')
            $script:BaseRef = if ($script:PrMode) { "origin/$($script:Base)" } else { Get-IntegrationBranch }
        }
        Write-Host "Project:   $($script:Config.name)  ($root)"
        Write-Host "Deadline:  $(if ($script:Deadline -lt [datetime]::MaxValue) { $script:Deadline } else { 'none (runs until stopped)' })"
        Write-Host "Running:   $(if ($p = Get-RunningPid) { "yes (PID $p)" } else { 'no' })$(if (Test-Path $script:PauseFile) { ' - paused' })"
        Write-Host "Lands via: $(if ([string]$script:Config.pr.mode -eq 'off' -or -not $hasOrigin) { "local merges into $($script:Base)" } else { "a PR per item into $($script:Base) (when gh is logged in)" })"
        Write-Host "Worktrees: $(Get-WorktreeRoot)  (workers: $($script:Config.workers); setup: $(if (@($script:Config.worktree.setup).Count) { @($script:Config.worktree.setup) -join ' ; ' } else { 'none' }))"
        Write-Host "Hours:     $(if (@($script:Config.schedule.activeHours).Count) { @($script:Config.schedule.activeHours) -join ', ' } else { 'any time' })$(if ($script:Config.schedule.resumeAt) { "; after a usage limit, resume at $($script:Config.schedule.resumeAt)" })"
        $jobs = Select-WorkJobs ([int]$script:Config.workers)
        if ($jobs) { foreach ($j in $jobs) { Write-Host "Next:      [$($j.Kind) / $($j.Lane)] $($j.Id) $($j.Text)" } } else { Write-Host 'Next:      nothing to do' }
        Write-Host "Models:    $(($script:Config.models | ConvertTo-Json -Compress))"
        Write-Host "Checks:    $((@($script:Config.gates) | ForEach-Object { $_.name }) -join ', ')"
        $fileTasks = Read-TaskList $script:TasksPath
        $failed = @($fileTasks | Where-Object { $_.Status -eq '!' } | ForEach-Object { $_.Id }) + @($script:Overlay.Keys | Where-Object { $script:Overlay[$_].state -in @('failed', 'blocked') })
        if ($failed) { Write-Host "Resolver:  will look at $(($failed | Select-Object -Unique) -join ', ') first" }
        exit 0
    }

    'run' {
        $root = Get-Root
        Initialize-Engine $root $EngineDir (Get-RunDeadline)
        Remove-Item $script:PauseFile -ErrorAction SilentlyContinue
        $code = Start-Daemon -Once:$Once -Task $Task
        exit ([int]($code | Select-Object -Last 1))
    }

    'start' {
        $root = Get-Root
        Initialize-Engine $root $EngineDir (Get-RunDeadline)
        Start-Background $root
        exit 0
    }

    'ensure' {
        $root = Get-Root
        Initialize-Engine $root $EngineDir ([datetime]::MaxValue)
        if ($Resume) { Remove-Item $script:PauseFile -ErrorAction SilentlyContinue }
        if ((Test-Path $script:PauseFile) -or (Get-RunningPid)) { exit 0 }
        Start-Background $root -KeepPause
        exit 0
    }

    'stop' {
        $root = Get-Root
        Initialize-Engine $root $EngineDir ([datetime]::MaxValue)
        Write-Utf8 $script:PauseFile "stopped $(Get-Date -Format s)"
        $p = Get-RunningPid
        if (-not $p) { Write-Host 'Not running. (It stays stopped until nightshift start / resume.)'; exit 0 }
        if ($Force) {
            & $env:ComSpec /d /c "taskkill /T /F /PID $p >nul 2>&1"
            Remove-Item $script:LockFile -ErrorAction SilentlyContinue
            Write-Host "Killed PID $p and its workers. Their branches are resumed next time."
        } else {
            Write-Utf8 $script:StopFile "stop requested $(Get-Date -Format s)"
            Write-Host "Stop requested: workers finish their current step (an agent session can take up to $($script:Config.agentTimeoutMinutes) min). -Force kills now."
        }
        exit 0
    }

    'pause' {
        $root = Get-Root
        Initialize-Engine $root $EngineDir ([datetime]::MaxValue)
        Write-Utf8 $script:PauseFile "paused $(Get-Date -Format s)"
        Write-Host 'Paused: running items finish, nothing new starts. nightshift resume to continue.'
        exit 0
    }

    'resume' {
        $root = Get-Root
        Initialize-Engine $root $EngineDir ([datetime]::MaxValue)
        Remove-Item $script:PauseFile -ErrorAction SilentlyContinue
        if (Get-RunningPid) { Write-Host 'Resumed.' } else { Start-Background $root }
        exit 0
    }

    { $_ -in @('ask', 'retry', 'resolve', 'unblock') } {
        $root = Open-Project
        $running = Get-RunningPid
        switch ($Command) {
            'ask' {
                if (-not $Text) { throw 'Say what you want: nightshift ask "update README with the new setup steps"' }
                $id = New-InboxRequest @{ type = 'ask'; text = $Text; id = "ask-$(Get-Stamp)" }
                Write-Host "Queued $id for the resolver."
            }
            'retry' {
                if (-not $Task) { throw 'Which task? nightshift retry -Task 3.4' }
                if ($running) { New-InboxRequest @{ type = 'retry'; item = $Task } | Out-Null }
                else {
                    $o = $script:Overlay[$Task]
                    if ($o) { $o.state = 'open'; $o.passes = 0; $script:Overlay[$Task] = $o; Write-StateMap 'queue.json' $script:Overlay }
                    else {
                        $line = Get-ItemLine $Task
                        if ($line -and $line.Status -eq '!') { $script:Overlay[$Task] = [pscustomobject]@{ state = 'open'; text = $line.Text; passes = 0 }; Write-StateMap 'queue.json' $script:Overlay }
                    }
                }
                Write-Host "Reopened $Task."
                exit 0
            }
            default { New-InboxRequest @{ type = 'resolve'; item = $Task } | Out-Null; Write-Host "Sent $(if ($Task) { $Task } else { 'failed items' }) to the resolver." }
        }
        if ($running) {
            if ($Command -eq 'ask' -and $Wait) {
                $done = Join-Path $script:InboxDir "done\$id.json"
                while (-not (Test-Path $done)) { Start-Sleep -Seconds 15 }
                $r = Read-JsonFile $done
                Write-Host "Done: $($r.diagnosis)"; @($r.did) | ForEach-Object { Write-Host "  - $_" }
                if ($r.human) { Write-Host "Needs you: $($r.human)" }
            } else { Write-Host 'The running daemon picks it up within a minute (nightshift logs -Follow).' }
            exit 0
        }
        Write-Host 'No daemon running: handling it now in this window.'
        Initialize-Engine $root $EngineDir ([datetime]::MaxValue)
        $code = Start-Daemon -UrgentOnly
        if ($Command -eq 'ask') {
            $r = Read-JsonFile (Join-Path $script:InboxDir "done\$id.json")
            if ($r) { Write-Host "Done: $($r.diagnosis)"; @($r.did) | ForEach-Object { Write-Host "  - $_" }; if ($r.human) { Write-Host "Needs you: $($r.human)" } }
        }
        exit ([int]($code | Select-Object -Last 1))
    }

    'status' {
        $root = Open-Project
        $p = Get-RunningPid
        $d = Read-JsonFile (Join-Path $script:StateDir 'daemon.json')
        Write-Host "Project:  $($script:Config.name)  ($root)"
        $state = if ($p) { "running (PID $p)" } else { 'not running' }
        if (Test-Path $script:StopFile) { $state += ' - stopping' }
        if (Test-Path $script:PauseFile) { $state += ' - paused (nightshift resume)' }
        Write-Host "Daemon:   $state$(if ($p -and $d -and $d.note) { " - $($d.note)" })"
        if ($d -and $d.mode) { Write-Host "Lands via: $(if ($d.mode -eq 'pr') { "PRs into $($script:Base)" } else { "local merges into $($d.baseRef)" })" }
        $limit = Read-LimitState
        if ($limit -and (Get-Date) -lt [datetime]$limit.until) { Write-Host "Limit:    usage limit; waiting until $([datetime]$limit.until)" }
        foreach ($f in @(Get-ChildItem $script:SlotsDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $s = Read-JsonFile $f.FullName
            if (-not $s -or -not (Get-Process -Id $s.pid -ErrorAction SilentlyContinue)) { continue }
            $mins = [int]((Get-Date) - [datetime]$s.since).TotalMinutes
            Write-Host ("  {0,-9} {1} {2} - {3} ({4} min)" -f $s.slot, $s.kind, $s.id, $s.step, $mins)
        }
        if ($d -and @($d.pending).Count) { Write-Host "Merging:  $(@($d.pending) -join ', ')" }
        if ($d -and $d.awaitingPr) { Write-Host "PR:       waiting for checks: $($d.awaitingPr)" }
        if ($d -and @($d.resolverQueue).Count) { Write-Host "Resolver: queued $(@($d.resolverQueue) -join ', ')" }
        $tasks = Merge-TaskOverlay (Read-TaskList $script:TasksPath) $script:Overlay
        $count = { param($s) @($tasks | Where-Object { $_.Status -eq $s }).Count }
        Write-Host "Tasks:    $(& $count 'x') done, $(& $count ' ') open, $(& $count '!') failed, $(& $count '>') waiting on you"
        if (-not $p) {
            $jobs = Select-WorkJobs ([int]$script:Config.workers)
            if ($jobs) { Write-Host "Next:     $(($jobs | ForEach-Object { "$($_.Id) $($_.Text)" }) -join ' | ')" }
        }
        $human = @($script:Overlay.Keys | Where-Object { $script:Overlay[$_].state -eq 'human' })
        if ($human) { Write-Host 'Needs you:'; foreach ($h in $human) { Write-Host "  - $h $($script:Overlay[$h].ask)" } }
        $failed = @($script:Overlay.Keys | Where-Object { $script:Overlay[$_].state -in @('failed', 'blocked') })
        if ($failed) { Write-Host "Failed:   $($failed -join ', ') (nightshift retry -Task <id>, or nightshift resolve)" }
        $sched = Get-ScheduledTask -TaskName (Get-ScheduleName) -ErrorAction SilentlyContinue
        Write-Host "Watchdog: $(if ($sched) { "on ('$($sched.TaskName)')" } else { 'off (nightshift schedule)' })"
        $report = Get-ChildItem $script:ReportsDir -Filter *.md -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
        if ($report) { Write-Host "Report:   $($report.FullName)" }
        if (Test-Path $script:LogFile) {
            Write-Host ''
            Write-Host 'Recent log:'
            Get-Content $script:LogFile -Tail 12 | ForEach-Object { Write-Host "  $_" }
        }
        exit 0
    }

    'logs' {
        $root = Get-Root
        Initialize-Engine $root $EngineDir ([datetime]::MaxValue)
        if (-not (Test-Path $script:LogFile)) { Write-Host 'No log yet.'; exit 0 }
        $filter = if ($Slot) { [regex]::Escape("[$Slot] ") } else { '' }
        if ($Follow) { Get-Content $script:LogFile -Tail 40 -Wait | Where-Object { -not $filter -or $_ -match $filter } }
        else { Get-Content $script:LogFile -Tail 400 | Where-Object { -not $filter -or $_ -match $filter } | Select-Object -Last 40 }
        exit 0
    }

    'schedule' {
        $root = Get-Root
        Initialize-Engine $root $EngineDir ([datetime]::MaxValue)
        $name = Register-Watchdog $root
        Write-Host "Scheduled '$name': starts Night Shift at logon and restarts it within 10 minutes if it stops (unless you stopped or paused it)."
        if ($At) { Write-Host "Also resumes it every day at $At ('$name (resume)')." }
        exit 0
    }

    'unschedule' {
        $root = Get-Root
        Initialize-Engine $root $EngineDir ([datetime]::MaxValue)
        $removed = @()
        foreach ($n in @((Get-ScheduleName), "$(Get-ScheduleName) (resume)")) {
            if (Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $n -Confirm:$false; $removed += $n }
        }
        if ($removed) { Write-Host "Removed $($removed -join ', ')." } else { Write-Host 'Nothing scheduled.' }
        exit 0
    }
}
