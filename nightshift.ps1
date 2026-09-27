<#
.SYNOPSIS
  Night Shift - an unattended Claude Code agent factory for any git project.

.DESCRIPTION
  Commands (run from inside a project, or pass -Project <path>):
    init        scaffold .nightshift/ + TASKS/BACKLOG/NOTES + agent permissions in a project
    dry-run     show what the next run would do; changes nothing
    run         run in THIS window until the deadline (what the scheduler calls)
    start       start a run in the background (own minimized window) and return
    stop        ask the current run to stop after its current step (-Force kills it now)
    status      running? what is it doing? what's next? schedule? latest report?
    schedule    register the nightly Windows scheduled task (-At 23:30)
    unschedule  remove it
    test        run the engine self-tests

  Deadline: -For 2h | -Until 07:00 | default: the project's stopAt.

.EXAMPLE
  nightshift init -Project D:\repos\my-app -Preset node
  nightshift start -For 2h
  nightshift status
  nightshift stop
  nightshift run -Once -Task 1.3
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('init', 'dry-run', 'run', 'start', 'stop', 'status', 'schedule', 'unschedule', 'test', 'help')]
    [string]$Command = 'help',
    [string]$Project = (Get-Location).Path,
    [string]$For,
    [string]$Until,
    [switch]$Once,
    [string]$Task,
    [string]$At = '23:30',
    [ValidateSet('generic', 'flutter', 'node', 'python')]
    [string]$Preset = 'generic',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$EngineDir = $PSScriptRoot
foreach ($lib in 'tasks', 'limits', 'gates', 'config', 'engine') { . (Join-Path $EngineDir "lib\$lib.ps1") }

function Get-Root {
    $root = Find-ProjectRoot $Project
    if (-not $root) { throw "No .nightshift/config.json found at or above '$Project'. Run: nightshift init -Project <path>" }
    return $root
}

function Get-RunDeadline($Config) {
    if ($For) { return (Get-Date).Add((ConvertTo-Duration $For)) }
    if ($Until) { return Get-Deadline $Until (Get-Date) }
    return Get-Deadline $Config.stopAt (Get-Date)
}

function Get-ScheduleName($Config) { return "Night Shift - $($Config.name)" }

function Write-Utf8([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

switch ($Command) {
    'help' { Get-Help $PSCommandPath -Detailed; exit 0 }

    'test' {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $EngineDir 'tests\run-tests.ps1')
        exit $LASTEXITCODE
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
            Write-Utf8 $cfgPath ($cfg | ConvertTo-Json -Depth 10)
            $created += '.nightshift/config.json'
        }
        foreach ($f in @(
                @{ src = 'rules.md'; dst = '.nightshift\rules.md' },
                @{ src = 'TASKS.md'; dst = 'TASKS.md' },
                @{ src = 'BACKLOG.md'; dst = 'BACKLOG.md' },
                @{ src = 'NOTES.md'; dst = 'NOTES.md' })) {
            $dst = Join-Path $root $f.dst
            if (-not (Test-Path $dst)) { Copy-Item (Join-Path $templates $f.src) $dst; $created += $f.dst }
        }

        $claudeMd = Join-Path $root 'CLAUDE.md'
        $section = [IO.File]::ReadAllText((Join-Path $templates 'claude-section.md'))
        if (-not (Test-Path $claudeMd)) { Write-Utf8 $claudeMd $section; $created += 'CLAUDE.md' }
        elseif (-not ([IO.File]::ReadAllText($claudeMd) -match 'Night-shift agents')) {
            [IO.File]::AppendAllText($claudeMd, "`n$section", (New-Object System.Text.UTF8Encoding($false))); $created += 'CLAUDE.md (section appended)'
        }

        $settingsPath = Join-Path $root '.claude\settings.json'
        if (-not (Test-Path $settingsPath)) {
            New-Item -ItemType Directory -Force -Path (Split-Path $settingsPath) | Out-Null
            $base = Get-Content (Join-Path $templates 'settings.base.json') -Raw | ConvertFrom-Json
            $base.permissions.allow = @($base.permissions.allow) + @($presetData.allow)
            $base.permissions.deny = @($base.permissions.deny) + @($presetData.deny)
            Write-Utf8 $settingsPath ($base | ConvertTo-Json -Depth 10)
            $created += '.claude/settings.json'
        } else {
            Write-Host "NOTE: .claude/settings.json exists - make sure it allows your toolchain commands and denies Edit(.nightshift/**) (see templates/settings.base.json)."
        }

        $gi = Join-Path $root '.gitignore'
        $giText = if (Test-Path $gi) { [IO.File]::ReadAllText($gi) } else { '' }
        if ($giText -notmatch '\.nightshift/state/') {
            [IO.File]::AppendAllText($gi, "`n# Night Shift runtime state`n.nightshift/state/`n.nightshift/STOP`n", (New-Object System.Text.UTF8Encoding($false)))
            $created += '.gitignore (entries)'
        }

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
        Write-Host "  1. Fill TASKS.md (and PLAN.md) with the work; tune .nightshift/config.json gates + .nightshift/rules.md."
        Write-Host "  2. Commit, then: git switch $baseBranch"
        Write-Host "  3. Trust the folder once: cd $root; claude  (accept, then /exit)"
        Write-Host '  4. nightshift dry-run   ->   nightshift start -For 1h   ->   nightshift schedule'
        exit 0
    }

    'dry-run' {
        $root = Get-Root
        $config = Read-ProjectConfig $root
        Initialize-Engine $root $EngineDir (Get-RunDeadline $config)
        $script:ForcedTask = $Task
        Write-Host "Project:   $($config.name)  ($root)"
        Write-Host "Deadline:  $($script:Deadline)"
        Write-Host "Trusted:   $(Test-WorkspaceTrusted)"
        Write-Host "Running:   $(if ($p = Get-RunningPid) { "yes (PID $p)" } else { 'no' })"
        $item = Select-NextItem
        if ($item) { Write-Host "Next:      [$($item.Kind)] $($item.Id) $($item.Text)" } else { Write-Host 'Next:      nothing to do' }
        Write-Host "Models:    $(($config.models | ConvertTo-Json -Compress))"
        Write-Host "Checks:    $((@($config.gates) | ForEach-Object { $_.name }) -join ', ')"
        exit 0
    }

    'run' {
        $root = Get-Root
        $config = Read-ProjectConfig $root
        Initialize-Engine $root $EngineDir (Get-RunDeadline $config)
        $code = Start-Run -Once:$Once -Task $Task
        exit ([int]($code | Select-Object -Last 1))
    }

    'start' {
        $root = Get-Root
        $config = Read-ProjectConfig $root
        Initialize-Engine $root $EngineDir (Get-RunDeadline $config)
        if ($p = Get-RunningPid) { Write-Host "Already running (PID $p). Use 'nightshift status' or 'nightshift stop'."; exit 0 }
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", 'run', '-Project', "`"$root`"")
        if ($For) { $argList += @('-For', $For) }
        if ($Until) { $argList += @('-Until', $Until) }
        if ($Once) { $argList += '-Once' }
        if ($Task) { $argList += @('-Task', $Task) }
        $proc = Start-Process powershell.exe -ArgumentList ($argList -join ' ') -WorkingDirectory $root -WindowStyle Minimized -PassThru
        Write-Host "Started $($config.name) night shift (PID $($proc.Id)) until $($script:Deadline)."
        Write-Host "Watch:  Get-Content '$root\.nightshift\state\run.log' -Tail 20 -Wait"
        Write-Host 'Status: nightshift status      Stop: nightshift stop'
        exit 0
    }

    'stop' {
        $root = Get-Root
        $config = Read-ProjectConfig $root
        Initialize-Engine $root $EngineDir (Get-Date)
        $p = Get-RunningPid
        if (-not $p) { Write-Host 'Not running.'; exit 0 }
        if ($Force) {
            & $env:ComSpec /d /c "taskkill /T /F /PID $p >nul 2>&1"
            Write-Host "Killed PID $p and its children. The next run commits the interrupted branch as WIP and continues."
        } else {
            Write-Utf8 $script:StopFile "stop requested $(Get-Date -Format s)"
            Write-Host "Stop requested. The run ends after its current step (an agent session can take up to $($config.agentTimeoutMinutes) min); use -Force to kill now."
        }
        exit 0
    }

    'status' {
        $root = Get-Root
        $config = Read-ProjectConfig $root
        Initialize-Engine $root $EngineDir (Get-Deadline $config.stopAt (Get-Date))
        $p = Get-RunningPid
        Write-Host "Project:  $($config.name)  ($root)"
        Write-Host "Running:  $(if ($p) { "yes (PID $p)$(if (Test-Path $script:StopFile) { ' - stop requested' })" } else { 'no' })"
        $tasks = Read-TaskList $script:TasksPath
        $count = { param($s) @($tasks | Where-Object { $_.Status -eq $s }).Count }
        Write-Host "Tasks:    $(& $count 'x') done, $(& $count ' ') open, $(& $count '!') failed, $(& $count '>') waiting on you"
        $next = Get-NextTask $tasks
        if ($next) { Write-Host "Next:     $($next.Id) $($next.Text)" }
        $sched = Get-ScheduledTask -TaskName (Get-ScheduleName $config) -ErrorAction SilentlyContinue
        if ($sched) {
            $info = $sched | Get-ScheduledTaskInfo
            Write-Host "Schedule: '$($sched.TaskName)' next $($info.NextRunTime), last $($info.LastRunTime) (result $($info.LastTaskResult))"
        } else { Write-Host 'Schedule: none (nightshift schedule -At 23:30)' }
        $report = Get-ChildItem $script:ReportsDir -Filter *.md -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
        if ($report) { Write-Host "Report:   $($report.FullName)" }
        if (Test-Path $script:LogFile) {
            Write-Host ''
            Write-Host 'Recent log:'
            Get-Content $script:LogFile -Tail 12 | ForEach-Object { Write-Host "  $_" }
        }
        exit 0
    }

    'schedule' {
        $root = Get-Root
        $config = Read-ProjectConfig $root
        $name = Get-ScheduleName $config
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File `"$PSCommandPath`" run -Project `"$root`"" `
            -WorkingDirectory $root
        $trigger = New-ScheduledTaskTrigger -Daily -At $At
        # Wake to run; not on battery; never two at once; no catch-up of missed runs (so it never starts mid-day).
        $settings = New-ScheduledTaskSettingsSet -WakeToRun -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 12)
        # Interactive = runs in your logged-on session (Claude Code login, Docker Desktop); lock the screen, don't sign out.
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
            -Description "Night Shift agent factory for $root" -Force | Out-Null
        Write-Host "Scheduled '$name' daily at $At (runs until $($config.stopAt))."
        exit 0
    }

    'unschedule' {
        $root = Get-Root
        $name = Get-ScheduleName (Read-ProjectConfig $root)
        if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $name -Confirm:$false
            Write-Host "Removed '$name'."
        } else { Write-Host "'$name' is not scheduled." }
        exit 0
    }
}
