# The night-shift supervisor. Dot-sourced by nightshift.ps1; call Initialize-Engine first.
# Everything project-specific comes from .nightshift/config.json (see README).

function Initialize-Engine([string]$Root, [string]$EngineDir, [datetime]$Deadline) {
    $script:Repo = $Root
    $script:EngineDir = $EngineDir
    $script:Config = Read-ProjectConfig $Root
    $script:Protected = Get-ProtectedMap $script:Config
    $script:Ns = Join-Path $Root '.nightshift'
    $script:StateDir = Join-Path $script:Ns 'state'
    $script:SessionsDir = Join-Path $script:StateDir 'sessions'
    $script:ReportsDir = Join-Path $script:Ns 'reports'
    New-Item -ItemType Directory -Force -Path $script:SessionsDir, $script:ReportsDir | Out-Null

    $script:Base = $script:Config.baseBranch
    $script:TasksPath = Join-Path $Root $script:Config.files.tasks
    $script:BacklogPath = Join-Path $Root $script:Config.files.backlog
    $script:StopFile = Join-Path $script:Ns 'STOP'
    $script:LockFile = Join-Path $script:StateDir 'run.lock'
    $script:LogFile = Join-Path $script:StateDir 'run.log'
    $script:BaselineFile = Join-Path $script:StateDir 'test-baseline.json'
    $script:NightDate = Get-Date -Format 'yyyy-MM-dd'
    # Written to state/ during the run (task branches must not see .nightshift/ changes),
    # appended to reports/<date>.md on the base branch at the end.
    $script:ReportPath = Join-Path $script:StateDir "report-$(Get-Date -Format 'yyyyMMdd-HHmmss').md"
    $script:FinalReportPath = Join-Path $script:ReportsDir "$($script:NightDate).md"
    $script:Utf8 = New-Object System.Text.UTF8Encoding($false)

    $script:Deadline = $Deadline
    $script:Stats = @{ Merged = 0; Failed = 0; Blocked = 0; LimitSleeps = 0; Cost = 0.0 }
    $script:ProductRan = $false
    $script:PolishCount = 0
    $script:PolishDone = New-Object System.Collections.ArrayList
    $script:PolishExhausted = $false
    $script:ReadyServices = @{}
    $script:ForcedTask = $null
    $script:ForcedTaskUsed = $false
    $script:NoBatch = New-Object System.Collections.ArrayList   # ids whose batch failed: retry one at a time

    Set-Location $Root
    [Environment]::CurrentDirectory = $Root
}

# ---------------------------------------------------------------- utilities

function Write-Log([string]$Message) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"
    Write-Host $line
    [IO.File]::AppendAllText($script:LogFile, $line + "`r`n", $script:Utf8)
}

function Add-Report([string]$Line) {
    [IO.File]::AppendAllText($script:ReportPath, $Line + "`n", $script:Utf8)
}

function Stop-Night([string]$Reason) { throw "STOP_NIGHT: $Reason" }

function Get-Stamp { return (Get-Date -Format 'yyyyMMdd-HHmmss') }

function Get-Tail([string]$Path, [int]$Lines = 80) {
    if (-not (Test-Path $Path)) { return '' }
    return ((Get-Content $Path -Tail $Lines -Encoding UTF8) -join "`n")
}

# Runs a command line through cmd.exe with redirected output and a hard timeout.
# Returns the exit code, or -1 on timeout (the whole process tree is killed).
function Invoke-Logged([string]$CommandLine, [string]$OutFile, [string]$ErrFile, [string]$InFile, [int]$TimeoutMinutes) {
    $cmd = $CommandLine
    if ($InFile) { $cmd += " < `"$InFile`"" }
    $cmd += " > `"$OutFile`""
    if ($ErrFile) { $cmd += " 2> `"$ErrFile`"" } else { $cmd += ' 2>&1' }
    $p = Start-Process -FilePath $env:ComSpec -ArgumentList "/d /s /c `"$cmd`"" -WorkingDirectory $script:Repo -NoNewWindow -PassThru
    $null = $p.Handle
    if (-not $p.WaitForExit($TimeoutMinutes * 60000)) {
        & $env:ComSpec /d /c "taskkill /T /F /PID $($p.Id) >nul 2>&1"
        return -1
    }
    $p.WaitForExit()
    return $p.ExitCode
}

function Invoke-Git([string]$ArgLine, [switch]$AllowFail) {
    $out = & $env:ComSpec /d /s /c "`"git -c core.safecrlf=false $ArgLine 2>&1`""
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $AllowFail) { throw "git $ArgLine failed ($code): $($out -join "`n")" }
    return @($out | Where-Object { $_ -ne $null })
}

function Test-TreeDirty { return [bool](Invoke-Git 'status --porcelain' | Where-Object { $_.Trim() }) }

function Get-CurrentBranch { return ((Invoke-Git 'branch --show-current') -join '').Trim() }

# Commit everything (or the given paths). Returns $true if a commit was made.
function New-Commit([string]$Message, [string[]]$Paths) {
    $msgFile = Join-Path $script:StateDir 'commit-msg.txt'
    [IO.File]::WriteAllText($msgFile, $Message, $script:Utf8)
    if ($Paths) { foreach ($p in $Paths) { Invoke-Git "add -- `"$p`"" | Out-Null } }
    else { Invoke-Git 'add -A' | Out-Null }
    $staged = Invoke-Git 'diff --cached --name-only' | Where-Object { $_.Trim() }
    if (-not $staged) { return $false }
    Invoke-Git "commit -q --no-verify -F `"$msgFile`"" | Out-Null
    return $true
}

function Wait-Until([datetime]$Until) {
    while ((Get-Date) -lt $Until) {
        if (Test-Path $script:StopFile) { Stop-Night 'STOP file found while sleeping' }
        Start-Sleep -Seconds 60
    }
}

# ---------------------------------------------------------------- prompts & agents

function Get-ProjectRules {
    $path = Join-Path $script:Repo $script:Config.files.rules
    if (Test-Path $path) { return [IO.File]::ReadAllText($path).Trim() }
    return '(none)'
}

function Get-VerifyText {
    $lines = foreach ($g in $script:Config.gates) {
        $cond = if ($g.when) { " (when $(($g.when | ConvertTo-Json -Compress)))" } else { '' }
        "- ``$($g.run)``$cond"
    }
    if (-not $lines) { return '- (no automated checks configured)' }
    return ($lines -join "`n")
}

function Get-ProtectedText($Item) {
    $names = foreach ($p in $script:Protected.PSObject.Properties) {
        if (-not (@($p.Value) | Where-Object { $Item.Ids -contains $_ })) { "``$($p.Name)``" }
    }
    return ($names -join ', ')
}

# Work item for one task or a batch of consecutive small tasks.
function New-TaskItem([object[]]$Tasks, [string]$Kind = 'task') {
    $ids = @($Tasks | ForEach-Object { $_.Id })
    if ($ids.Count -eq 1) {
        $taskText = "$($Tasks[0].Id) $($Tasks[0].Text)"
        $text = $Tasks[0].Text
    } else {
        $list = ($Tasks | ForEach-Object { "- $($_.Id) $($_.Text)" }) -join "`n"
        $taskText = "These $($ids.Count) consecutive small tasks, done together in this one session (make one commit per task, each message naming its id):`n$list"
        $text = ($Tasks | ForEach-Object { $_.Text }) -join ' | '
    }
    return [pscustomobject]@{ Kind = $Kind; Id = ($ids -join '+'); Ids = $ids; Text = $text; TaskText = $taskText; Phase = $Tasks[0].Phase }
}

function Expand-Template([string]$Name, [hashtable]$Values) {
    $override = Join-Path $script:Ns "prompts\$Name.md"
    $path = if (Test-Path $override) { $override } else { Join-Path $script:EngineDir "prompts\$Name.md" }
    $text = [IO.File]::ReadAllText($path)
    $common = @{
        TASKS_FILE    = $script:Config.files.tasks
        BACKLOG_FILE  = $script:Config.files.backlog
        NOTES_FILE    = $script:Config.files.notes
        PLAN_FILE     = $script:Config.files.plan
        BASE          = $script:Base
        VERIFY        = Get-VerifyText
        PROJECT_RULES = Get-ProjectRules
        PHASE_CONTEXT = '(not applicable)'
    }
    foreach ($k in $common.Keys) { if (-not $Values.ContainsKey($k)) { $Values[$k] = $common[$k] } }
    foreach ($k in $Values.Keys) { $text = $text.Replace("{{$k}}", [string]$Values[$k]) }
    return $text
}

function Invoke-Agent([string]$Role, [string]$Prompt, [string]$Model, [switch]$ReadOnly) {
    $base = Join-Path $script:SessionsDir "$(Get-Stamp)-$Role"
    $in = "$base.prompt.md"; $out = "$base.out.json"; $err = "$base.err.log"
    [IO.File]::WriteAllText($in, $Prompt, $script:Utf8)

    # Project settings only: user-level hooks (e.g. command-rewriting hooks, fact-forcing gates)
    # and plugins would defeat the project allowlist; no MCP servers keeps sessions lean.
    $cli = "claude -p --output-format json --model $Model --setting-sources project,local --strict-mcp-config"
    if ($ReadOnly) {
        $cli += ' --permission-mode default --allowedTools "Read" "Grep" "Glob" --disallowedTools "Edit" "Write" "Bash" "PowerShell" "NotebookEdit"'
    } else {
        $cli += ' --permission-mode acceptEdits'
    }
    Write-Log "agent $Role ($Model) -> $base"
    $code = Invoke-Logged $cli $out $err $in $script:Config.agentTimeoutMinutes

    $raw = if (Test-Path $out) { [IO.File]::ReadAllText($out) } else { '' }
    $errText = if (Test-Path $err) { [IO.File]::ReadAllText($err) } else { '' }
    $result = $raw; $isError = ($code -ne 0); $cost = 0.0
    try {
        $json = $raw | ConvertFrom-Json
        $result = [string]$json.result
        if ($json.is_error) { $isError = $true }
        if ($json.total_cost_usd) { $cost = [double]$json.total_cost_usd }
    } catch { }
    if ($errText -match 'has not been trusted') {
        Stop-Night "Claude Code ignores the project allowlist: workspace not trusted. Run 'claude' once in $($script:Repo) and accept the trust dialog."
    }
    $script:Stats.Cost += $cost
    $all = "$result`n$errText`n$raw"
    $limit = $isError -and (Test-LimitHit $all)
    return [pscustomobject]@{
        ExitCode  = $code
        TimedOut  = ($code -eq -1)
        IsError   = $isError
        LimitHit  = $limit
        Transient = ($isError -and -not $limit -and (Test-TransientError $all))
        Result    = $result
        ErrorText = $errText
        Log       = $base
    }
}

# Retries through usage limits (sleeping until reset) and transient API errors.
function Invoke-AgentSafely([string]$Role, [string]$Prompt, [string]$Model, [switch]$ReadOnly) {
    $transientTries = 0
    while ($true) {
        if ((Get-Date) -ge $script:Deadline) { Stop-Night 'deadline reached' }
        $r = Invoke-Agent -Role $Role -Prompt $Prompt -Model $Model -ReadOnly:$ReadOnly
        if ($r.LimitHit) {
            $now = Get-Date
            $reset = Get-LimitResetTime "$($r.Result)`n$($r.ErrorText)" $now
            $decision = Get-LimitDecision $reset $script:Deadline $now $script:Config.limitFallbackSleepMinutes
            $script:Stats.LimitSleeps++
            Write-Log "usage limit hit; decision=$($decision.Action) until $($decision.Until)"
            if ($decision.Action -eq 'stop') {
                Add-Report "- [limit] $(Get-Date -Format HH:mm) usage limit; resets after the deadline ($($decision.Until.ToString('HH:mm'))) - ending the run"
                Stop-Night 'usage limit resets after the deadline'
            }
            Add-Report "- [limit] $(Get-Date -Format HH:mm) usage limit; sleeping until $($decision.Until.ToString('HH:mm'))"
            Wait-Until $decision.Until
            continue
        }
        if ($r.Transient -and $transientTries -lt 3) {
            $transientTries++
            Write-Log "transient API error; retry $transientTries in 5 minutes"
            Wait-Until ((Get-Date).AddMinutes(5))
            continue
        }
        return $r
    }
}

# ---------------------------------------------------------------- services

function Test-DockerUp {
    $log = Join-Path $script:SessionsDir "$(Get-Stamp)-docker.log"
    return ((Invoke-Logged 'docker info' $log $null $null 2) -eq 0)
}

function Start-DockerDesktop {
    if (Test-DockerUp) { return }
    $candidates = @(
        "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe",
        "$env:LOCALAPPDATA\Programs\DockerDesktop\Docker Desktop.exe"
    ) | Where-Object { Test-Path $_ }
    if ($candidates) {
        Write-Log 'starting Docker Desktop'
        Start-Process -FilePath $candidates[0] | Out-Null
        $until = (Get-Date).AddMinutes(5)
        while ((Get-Date) -lt $until -and -not (Test-DockerUp)) { Start-Sleep -Seconds 15 }
    }
    if (-not (Test-DockerUp)) { Stop-Night 'Docker is not running' }
}

# services.<name> = { when, docker, check, start, startTimeoutMinutes, forPhases[], forTextMatch }
function Initialize-Service([string]$Name) {
    if ($script:ReadyServices[$Name]) { return }
    $svc = $script:Config.services.$Name
    if (-not $svc) { throw "Unknown service '$Name' in config" }
    if (-not (Test-GateCondition $svc.when $script:Repo @() @())) { return }
    if ($svc.docker) { Start-DockerDesktop }
    if ($svc.check) {
        $log = Join-Path $script:SessionsDir "$(Get-Stamp)-svc-$Name-check.log"
        if ((Invoke-Logged $svc.check $log $null $null 5) -eq 0) { $script:ReadyServices[$Name] = $true; return }
    }
    if ($svc.start) {
        $log = Join-Path $script:SessionsDir "$(Get-Stamp)-svc-$Name-start.log"
        $timeout = if ($svc.startTimeoutMinutes) { [int]$svc.startTimeoutMinutes } else { 20 }
        Write-Log "starting service $Name"
        if ((Invoke-Logged $svc.start $log $null $null $timeout) -ne 0) { Stop-Night "service $Name failed to start (see $log)" }
    }
    $script:ReadyServices[$Name] = $true
}

function Initialize-ServicesForItem($Item) {
    foreach ($p in $script:Config.services.PSObject.Properties) {
        $svc = $p.Value
        $byPhase = $svc.forPhases -and (@($svc.forPhases) -contains $Item.Phase)
        $byText = $svc.forTextMatch -and ($Item.Text -match $svc.forTextMatch)
        if ($byPhase -or $byText) { Initialize-Service $p.Name }
    }
}

# ---------------------------------------------------------------- gates

function Get-TestBaseline {
    if (Test-Path $script:BaselineFile) { return [int](Get-Content $script:BaselineFile -Raw | ConvertFrom-Json).count }
    return 0
}

function Set-TestBaseline([int]$Count) {
    [IO.File]::WriteAllText($script:BaselineFile, "{`"count`": $Count}", $script:Utf8)
}

function Invoke-Gate([string]$Name, [string]$CommandLine, [string]$Label, [int]$TimeoutMinutes) {
    $log = Join-Path $script:SessionsDir "$(Get-Stamp)-gate-$Label-$Name.log"
    Write-Log "gate $Name"
    $code = Invoke-Logged $CommandLine $log $null $null $TimeoutMinutes
    $output = if (Test-Path $log) { [IO.File]::ReadAllText($log) } else { '' }
    $why = if ($code -eq -1) { "timed out after $TimeoutMinutes min" } else { "exit code $code" }
    return [pscustomobject]@{
        Pass     = ($code -eq 0)
        Output   = $output
        Feedback = "Check '$Name' (``$CommandLine``) failed, $why. Last lines:`n``````n$(Get-Tail $log 80)`n``````"
    }
}

function Invoke-Gates([string]$Label, [string[]]$ChangedPaths) {
    $result = [pscustomobject]@{ Pass = $true; Feedback = ''; TestCount = $null; Summary = '' }
    $tasks = Read-TaskList $script:TasksPath
    $ran = New-Object System.Collections.ArrayList
    foreach ($gate in $script:Config.gates) {
        if (-not (Test-GateCondition $gate.when $script:Repo $ChangedPaths $tasks)) { continue }
        foreach ($s in @($gate.services)) { if ($s) { Initialize-Service $s } }
        $timeout = if ($gate.timeoutMinutes) { [int]$gate.timeoutMinutes } else { [int]$script:Config.gateTimeoutMinutes }
        $g = Invoke-Gate $gate.name $gate.run $Label $timeout
        [void]$ran.Add($gate.name)

        if ($gate.autoFix) {
            if ($g.Pass -and (Test-TreeDirty)) { New-Commit "style($Label): $($gate.name)" | Out-Null }
            continue
        }
        if ($gate.countTests) { $result.TestCount = Get-PassedTestCount $g.Output $gate.testCountPattern }
        if (-not $g.Pass) { $result.Pass = $false; $result.Feedback = $g.Feedback; return $result }
        if ($gate.countTests -and $null -ne $result.TestCount) {
            $baseline = Get-TestBaseline
            if ($result.TestCount -lt $baseline) {
                $result.Pass = $false
                $result.Feedback = "Passing test count dropped from $baseline to $($result.TestCount). Tests must not be deleted or skipped; restore them."
                return $result
            }
        }
    }
    $result.Summary = if ($ran.Count) { "checks: $($ran -join ', ')" + $(if ($null -ne $result.TestCount) { "; $($result.TestCount) tests" } else { '' }) } else { 'no checks applied yet' }
    return $result
}

function Invoke-Review($Item) {
    $stat = (Invoke-Git "diff --stat $($script:Base)...HEAD") -join "`n"
    $excludes = (@($script:Config.reviewExclude) | ForEach-Object { "`"$_`"" }) -join ' '
    $diff = (Invoke-Git "diff $($script:Base)...HEAD -- . $excludes") -join "`n"
    if ($diff.Length -gt 120000) { $diff = $diff.Substring(0, 120000) + "`n... [diff truncated - read the files directly]" }
    # Small diffs get the cheap reviewer; real logic gets the full one.
    $lines = Get-DiffLineCount ((Invoke-Git "diff --shortstat $($script:Base)...HEAD -- . $excludes") -join ' ')
    $model = $script:Config.models.reviewer
    if ($script:Config.review.smallModel -and $lines -le [int]$script:Config.review.smallDiffLines) { $model = $script:Config.review.smallModel }
    Write-Log "review: $lines changed lines -> $model"
    $prompt = Expand-Template 'reviewer' @{ TASK = $Item.TaskText; STAT = $stat; DIFF = $diff }
    for ($i = 0; $i -lt 2; $i++) {
        $r = Invoke-AgentSafely -Role "review-$($Item.Id)" -Prompt $prompt -Model $model -ReadOnly
        $verdict = Get-ReviewVerdict $r.Result
        if ($verdict) { return $verdict }
    }
    Write-Log 'reviewer gave no parseable verdict twice; checks passed, approving'
    return [pscustomobject]@{ verdict = 'approve'; issues = @('(reviewer gave no verdict)') }
}

# ---------------------------------------------------------------- work items

function Complete-Merge($Item, [string]$Branch, $Gates, [int]$Attempt) {
    Invoke-Git "switch -q $($script:Base)" | Out-Null
    $msgFile = Join-Path $script:StateDir 'merge-msg.txt'
    [IO.File]::WriteAllText($msgFile, "merge($($Item.Id)): $($Item.Text)", $script:Utf8)
    Invoke-Git "merge -q --no-ff --no-verify -F `"$msgFile`" $Branch" | Out-Null
    if ($null -ne $Gates.TestCount) { Set-TestBaseline $Gates.TestCount }
    switch ($Item.Kind) {
        'task' {
            foreach ($id in $Item.Ids) { Set-TaskStatus $script:TasksPath $id 'x' }
            New-Commit "chore(tasks): complete $($Item.Ids -join ', ')" @($script:Config.files.tasks) | Out-Null
        }
        'backlog' { Set-TaskStatus $script:BacklogPath $Item.Id 'x'; New-Commit "chore(backlog): complete $($Item.Id)" @($script:Config.files.backlog) | Out-Null }
    }
    Invoke-Git "branch -q -d $Branch" -AllowFail | Out-Null
    $script:Stats.Merged++
    Add-Report "- [merged] $($Item.Id) $($Item.Text) - attempt $Attempt; $($Gates.Summary)"
    Write-Log "merged $($Item.Id)"
}

function Complete-Failure($Item, [string]$Branch, [string]$Reason, [switch]$Blocked) {
    if (Test-TreeDirty) { New-Commit "wip($($Item.Id)): state at failure" | Out-Null }
    Invoke-Git "switch -q $($script:Base)" | Out-Null
    if (-not $Reason) { $Reason = 'failed without a recorded reason' }
    $short = ($Reason -split "`n")[0]
    # A failed batch is not a verdict on its tasks: retry them one at a time instead.
    if ($Item.Kind -eq 'task' -and $Item.Ids.Count -gt 1) {
        foreach ($id in $Item.Ids) { [void]$script:NoBatch.Add($id) }
        Add-Report "- [batch retry] $($Item.Id) - $short; branch ``$Branch``; retrying one task at a time"
        Write-Log "batch $($Item.Id) failed ($short); retrying singly"
        return
    }
    $note = if ($Blocked) { "BLOCKED: $short" } else { "$short (branch $Branch)" }
    switch ($Item.Kind) {
        'task' { Set-TaskStatus $script:TasksPath $Item.Id '!' $note; New-Commit "chore(tasks): mark $($Item.Id) failed" @($script:Config.files.tasks) | Out-Null }
        'backlog' { Set-TaskStatus $script:BacklogPath $Item.Id '!' $note; New-Commit "chore(backlog): mark $($Item.Id) failed" @($script:Config.files.backlog) | Out-Null }
    }
    # A branch with no commits of its own is just noise.
    if ([int](((Invoke-Git "rev-list --count $($script:Base)..$Branch") -join '').Trim()) -eq 0) {
        Invoke-Git "branch -q -D $Branch" -AllowFail | Out-Null
        $where = ''
    } else { $where = "; branch ``$Branch``" }
    if ($Blocked) { $script:Stats.Blocked++ } else { $script:Stats.Failed++ }
    $tag = if ($Blocked) { 'blocked' } else { 'failed' }
    Add-Report "- [$tag] $($Item.Id) $($Item.Text) - $short$where"
    Write-Log "$tag $($Item.Id): $short"
}

function Invoke-WorkItem($Item) {
    $safe = $Item.Id -replace '[^A-Za-z0-9.-]', '-'
    $branch = "$($script:Config.branchPrefix)$safe-$(Get-Date -Format 'yyyyMMdd-HHmm')"
    Invoke-Git "switch -q -c $branch $($script:Base)" | Out-Null
    Write-Log "=== $($Item.Kind) $($Item.Id): $($Item.Text) on $branch"
    Initialize-ServicesForItem $Item

    $taskText = $Item.TaskText
    $protectedText = Get-ProtectedText $Item
    # Only the task's own phase of the tasks file, so agents don't re-read the whole plan every session.
    $phase = if ($Item.Kind -eq 'task') { Get-PhaseSection $script:TasksPath $Item.Phase } else { '' }
    if (-not $phase) { $phase = '(not applicable)' }
    $feedback = $null
    for ($attempt = 1; $attempt -le $script:Config.maxAttempts; $attempt++) {
        $model = if ($attempt -eq 1) { $script:Config.models.builder } else { $script:Config.models.escalate }
        if ($attempt -eq 1 -and $Item.Kind -eq 'polish') {
            $done = if ($script:PolishDone.Count) { $script:PolishDone -join '; ' } else { 'nothing yet' }
            $prompt = Expand-Template 'polish' @{ DONE_TONIGHT = $done; PROTECTED = $protectedText }
        } elseif ($attempt -eq 1) {
            $prompt = Expand-Template 'builder' @{ TASK = $taskText; PROTECTED = $protectedText; PHASE_CONTEXT = $phase }
        } else {
            $prompt = Expand-Template 'fixer' @{ TASK = $taskText; FEEDBACK = $feedback; PROTECTED = $protectedText; PHASE_CONTEXT = $phase }
        }

        $role = if ($attempt -eq 1) { "build-$safe" } else { "fix-$safe" }
        $r = Invoke-AgentSafely -Role $role -Prompt $prompt -Model $model

        if ($r.Result -match '(?m)^\s*BLOCKED:\s*(.+)$') {
            if ($Item.Kind -eq 'polish') { $script:PolishExhausted = $true }
            Complete-Failure $Item $branch $Matches[1].Trim() -Blocked
            return
        }
        if ($r.TimedOut) {
            $feedback = "The previous session timed out after $($script:Config.agentTimeoutMinutes) minutes. Finish the remaining work with the smallest change that satisfies the task."
        }
        if (Test-TreeDirty) { New-Commit "chore($($Item.Id)): uncommitted agent changes" | Out-Null }

        $ahead = [int](((Invoke-Git "rev-list --count $($script:Base)..HEAD") -join '').Trim())
        if ($ahead -eq 0) {
            if (-not $feedback) { $feedback = 'No changes were committed. Implement the task and commit it.' }
            continue
        }

        $changed = @(Invoke-Git "diff --name-only $($script:Base)...HEAD" | Where-Object { $_.Trim() })
        $violations = Get-ProtectedPathViolations $changed $script:Protected $Item.Ids
        if ($violations.Count -gt 0) {
            $feedback = "You modified protected paths this task does not own: $($violations -join ', '). Restore them with ``git checkout $($script:Base) -- <path>`` (or delete them if new), commit, and keep the rest of the work."
            continue
        }

        $gates = Invoke-Gates $safe $changed
        if (-not $gates.Pass) { $feedback = $gates.Feedback; continue }

        $review = Invoke-Review $Item
        if ($review.verdict -ne 'approve') {
            $feedback = "The reviewer requested changes:`n- " + (@($review.issues) -join "`n- ")
            continue
        }

        if ($Item.Kind -eq 'polish') { [void]$script:PolishDone.Add(($r.Result -split "`n" | Where-Object { $_ -match '^DONE:' } | Select-Object -Last 1)) }
        Complete-Merge $Item $branch $gates $attempt
        return
    }
    if ($Item.Kind -eq 'polish') { $script:PolishExhausted = $true }
    Complete-Failure $Item $branch $feedback
}

function Invoke-Product {
    $script:ProductRan = $true
    $backlogRel = $script:Config.files.backlog -replace '\\', '/'
    $branch = "$($script:Config.branchPrefix)product-$(Get-Date -Format 'yyyyMMdd-HHmm')"
    Invoke-Git "switch -q -c $branch $($script:Base)" | Out-Null
    $backlog = if (Test-Path $script:BacklogPath) { Read-TaskList $script:BacklogPath } else { @() }
    $nextId = Get-NextBacklogId $backlog
    $prompt = Expand-Template 'product' @{ MAX = $script:Config.maxProposalsPerNight; NEXT_ID = $nextId }
    Invoke-AgentSafely -Role 'product' -Prompt $prompt -Model $script:Config.models.product | Out-Null
    if (Test-TreeDirty) { New-Commit 'docs(backlog): proposals' | Out-Null }
    $changed = @(Invoke-Git "diff --name-only $($script:Base)...HEAD" | Where-Object { $_.Trim() })
    $bad = @($changed | Where-Object { $_ -ne $backlogRel })
    Invoke-Git "switch -q $($script:Base)" | Out-Null
    if ($changed.Count -eq 0 -or $bad.Count -gt 0) {
        Add-Report "- [product] no usable proposals (changed: $($changed -join ', ')); branch ``$branch``"
        return
    }
    Invoke-Git "merge -q --no-ff --no-verify -m `"merge(backlog): product proposals`" $branch" | Out-Null
    Invoke-Git "branch -q -d $branch" -AllowFail | Out-Null
    Add-Report "- [product] new proposals in $backlogRel (from $nextId) - mark ``status: approved`` to queue them"
}

function Select-NextItem {
    $tasks = Read-TaskList $script:TasksPath
    $backlog = if (Test-Path $script:BacklogPath) { Read-TaskList $script:BacklogPath } else { @() }

    if ($script:ForcedTask -and -not $script:ForcedTaskUsed) {
        $script:ForcedTaskUsed = $true
        $t = @($tasks) + @($backlog) | Where-Object { $_.Id -eq $script:ForcedTask } | Select-Object -First 1
        if (-not $t) { throw "Task $($script:ForcedTask) not found" }
        $kind = if ($t.Id -match '^B\d+$') { 'backlog' } else { 'task' }
        return New-TaskItem @($t) $kind
    }

    $batch = Get-NextTaskBatch $tasks ([int]$script:Config.batch.maxTasks) ([int]$script:Config.batch.maxTextLength) @($script:NoBatch)
    if ($batch.Count -gt 0) { return New-TaskItem $batch 'task' }

    $b = Get-NextBacklogTask $backlog
    if ($b) { $item = New-TaskItem @($b) 'backlog'; $item.Phase = 'backlog'; return $item }

    if (-not $script:ProductRan) {
        return [pscustomobject]@{ Kind = 'product'; Id = 'product'; Ids = @('product'); Text = 'propose backlog items'; TaskText = 'propose backlog items'; Phase = '' }
    }

    if (-not $script:PolishExhausted -and $script:PolishCount -lt $script:Config.polishCap) {
        $script:PolishCount++
        $polishId = "polish-$($script:PolishCount)"
        return [pscustomobject]@{ Kind = 'polish'; Id = $polishId; Ids = @($polishId); Text = 'one focused quality improvement'; TaskText = 'one focused quality improvement'; Phase = '' }
    }
    return $null
}

function Write-Summary {
    $tasks = Read-TaskList $script:TasksPath
    $open = @($tasks | Where-Object { $_.Status -eq ' ' }).Count
    $done = @($tasks | Where-Object { $_.Status -eq 'x' }).Count
    Add-Report ''
    Add-Report "### Summary ($(Get-Date -Format 'HH:mm'))"
    Add-Report ''
    Add-Report "- merged: $($script:Stats.Merged), failed: $($script:Stats.Failed), blocked: $($script:Stats.Blocked), usage-limit sleeps: $($script:Stats.LimitSleeps)"
    Add-Report "- $($script:Config.files.tasks): $done done, $open open"
    Add-Report ("- notional API-equivalent cost of the sessions: `${0:N2} (covered by the subscription)" -f $script:Stats.Cost)
    $failed = @($tasks | Where-Object { $_.Status -eq '!' })
    if ($failed) { Add-Report "- needs your look ([!]): $(($failed | ForEach-Object { $_.Id }) -join ', ')" }
    $user = Get-PendingUserTasks $tasks
    if ($user) {
        Add-Report '- waiting on you ([>]):'
        foreach ($u in $user) { Add-Report "  - $($u.Id) $($u.Text)" }
    }
    if (Test-Path $script:BacklogPath) {
        $backlog = Read-TaskList $script:BacklogPath
        $proposed = @($backlog | Where-Object { $_.Status -eq ' ' -and $_.Text -match 'status:\s*proposed' })
        if ($proposed) {
            Add-Report "- proposals awaiting approval ($($script:Config.files.backlog)):"
            foreach ($p in $proposed) { Add-Report "  - $($p.Id) $($p.Text)" }
        }
    }
    $notesPath = Join-Path $script:Repo $script:Config.files.notes
    if (Test-Path $notesPath) {
        $notesLines = @(Get-Content $notesPath).Count
        if ($notesLines -gt [int]$script:Config.notesMaxLines) {
            Add-Report "- $($script:Config.files.notes) is $notesLines lines (limit $($script:Config.notesMaxLines)): every agent session reads it, so prune or condense it to keep sessions cheap"
        }
    }
    Add-Report ''
    Add-Report "Promote when happy: ``git switch main && git merge $($script:Base)``"
}

function Publish-Report {
    if (-not (Test-Path $script:ReportPath)) { return }
    if (-not (Test-Path $script:FinalReportPath)) {
        [IO.File]::WriteAllText($script:FinalReportPath, "# Night shift $($script:NightDate) - $($script:Config.name)`n", $script:Utf8)
    }
    [IO.File]::AppendAllText($script:FinalReportPath, [IO.File]::ReadAllText($script:ReportPath), $script:Utf8)
    $rel = ".nightshift/reports/$($script:NightDate).md"
    New-Commit "docs(night): report $($script:NightDate)" @($rel) | Out-Null
}

function Get-RunningPid {
    if (-not (Test-Path $script:LockFile)) { return $null }
    $otherPid = (Get-Content $script:LockFile -Raw).Trim()
    if ($otherPid -and (Get-Process -Id $otherPid -ErrorAction SilentlyContinue)) { return [int]$otherPid }
    return $null
}

function Test-WorkspaceTrusted {
    $claudeJson = Join-Path $env:USERPROFILE '.claude.json'
    if (-not (Test-Path $claudeJson)) { return $false }
    $key = $script:Repo -replace '\\', '/'
    $entry = (Get-Content $claudeJson -Raw | ConvertFrom-Json).projects.PSObject.Properties |
        Where-Object { $_.Name -ieq $key } | Select-Object -First 1
    return [bool]($entry -and $entry.Value.hasTrustDialogAccepted)
}

# ---------------------------------------------------------------- main loop

function Start-Run([switch]$Once, [string]$Task) {
    $script:ForcedTask = $Task
    $running = Get-RunningPid
    if ($running) { Write-Host "Night shift already running for $($script:Config.name) (PID $running)."; return 0 }
    [IO.File]::WriteAllText($script:LockFile, "$PID", $script:Utf8)
    if (Test-Path $script:StopFile) { Remove-Item $script:StopFile -Force }  # stale STOP from an earlier run

    Add-Type -Namespace NightShift -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);' -ErrorAction SilentlyContinue
    [NightShift.Power]::SetThreadExecutionState([uint32]2147483649) | Out-Null  # ES_CONTINUOUS | ES_SYSTEM_REQUIRED
    $env:ECC_GATEGUARD = 'off'

    $exitCode = 0
    try {
        if (-not (Test-Path (Join-Path $script:Repo '.git'))) { Stop-Night 'not a git repository' }
        $selfTestLog = Join-Path $script:SessionsDir "$(Get-Stamp)-engine-selftest.log"
        $selfTest = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $script:EngineDir 'tests\run-tests.ps1')`""
        if ((Invoke-Logged $selfTest $selfTestLog $null $null 5) -ne 0) { Stop-Night "engine self-tests failed (see $selfTestLog)" }
        if (-not (Test-WorkspaceTrusted)) {
            Stop-Night "workspace not trusted by Claude Code - run 'claude' once in $($script:Repo) and accept the trust dialog"
        }

        $current = Get-CurrentBranch
        if (Test-TreeDirty) {
            if ($current -like "$($script:Config.branchPrefix)*") { New-Commit 'wip: state left by an interrupted run' | Out-Null }
            else { Stop-Night "working tree is dirty on '$current' - commit or stash first" }
        }
        Invoke-Git "switch -q $($script:Base)" | Out-Null

        Add-Report ''
        Add-Report "## Run $(Get-Date -Format 'HH:mm') -> until $($script:Deadline.ToString('ddd HH:mm'))"
        Add-Report ''
        Write-Log "run started for $($script:Config.name); deadline $($script:Deadline)"

        while ($true) {
            if (Test-Path $script:StopFile) { Stop-Night 'stopped on request (STOP file)' }
            if ((Get-Date) -ge $script:Deadline) { Stop-Night 'deadline reached' }
            $item = Select-NextItem
            if (-not $item) { Write-Log 'nothing left to do'; Add-Report '- [idle] nothing left to do'; break }
            if ($item.Kind -eq 'product') { Invoke-Product } else { Invoke-WorkItem $item }
            if ($Once) { break }
        }
    } catch {
        $msg = $_.Exception.Message
        if ($msg -like 'STOP_NIGHT:*') {
            Write-Log $msg
            Add-Report "- [stop] $($msg.Substring(12))"
        } else {
            $exitCode = 1
            Write-Log "CRASH: $msg`n$($_.ScriptStackTrace)"
            Add-Report "- [crash] $msg (see .nightshift/state/run.log)"
        }
    } finally {
        try {
            if ((Get-CurrentBranch) -ne $script:Base) {
                if (Test-TreeDirty) { New-Commit 'wip: state at shutdown' | Out-Null }
                Invoke-Git "switch -q $($script:Base)" -AllowFail | Out-Null
            }
            Write-Summary
            Publish-Report
        } catch { Write-Log "finalize failed: $($_.Exception.Message)" }
        [NightShift.Power]::SetThreadExecutionState([uint32]2147483648) | Out-Null
        Remove-Item $script:LockFile -ErrorAction SilentlyContinue
        if (Test-Path $script:StopFile) { Remove-Item $script:StopFile -Force }
        Write-Log 'run finished'
    }
    return $exitCode
}
