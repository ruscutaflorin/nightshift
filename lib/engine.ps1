# Shared core of the supervisor: paths, logging, git, prompts, agents, usage limits, services,
# checks and review. Dot-sourced by lib/cli.ps1 with worker.ps1 and daemon.ps1.
#
# Two folders matter:
#   $script:ProjectHome  the project's own checkout: state, reports, STOP/PAUSE files. The engine never
#                 switches its branch or touches its working tree.
#   $script:Repo  where agents and checks run: one of the engine's worktrees (see Get-SlotPath).
# Config, tasks and prompts are read from $script:Repo, i.e. from the integrated base branch.

function Initialize-Engine([string]$Root, [string]$EngineDir, [datetime]$Deadline) {
    $script:ProjectHome = $Root
    $script:EngineDir = $EngineDir
    $script:Ns = Join-Path $Root '.nightshift'
    $script:StateDir = Join-Path $script:Ns 'state'
    $script:SessionsDir = Join-Path $script:StateDir 'sessions'
    $script:ReportsDir = Join-Path $script:Ns 'reports'
    $script:SlotsDir = Join-Path $script:StateDir 'slots'
    $script:JobsDir = Join-Path $script:StateDir 'jobs'
    $script:ResultsDir = Join-Path $script:StateDir 'results'
    $script:InboxDir = Join-Path $script:StateDir 'inbox'
    $script:LocksDir = Join-Path $script:StateDir 'locks'
    $script:SettingsDir = Join-Path $script:StateDir 'settings'
    New-Item -ItemType Directory -Force -Path $script:SessionsDir, $script:ReportsDir, $script:SlotsDir, $script:JobsDir,
        $script:ResultsDir, $script:InboxDir, (Join-Path $script:InboxDir 'done'), $script:LocksDir, $script:SettingsDir | Out-Null

    $script:StopFile = Join-Path $script:Ns 'STOP'
    $script:PauseFile = Join-Path $script:StateDir 'PAUSE'
    $script:LockFile = Join-Path $script:StateDir 'run.lock'
    $script:LogFile = Join-Path $script:StateDir 'run.log'
    $script:BaselineFile = Join-Path $script:StateDir 'test-baseline.json'
    $script:LimitFile = Join-Path $script:StateDir 'limit.json'
    $script:Utf8 = New-Object System.Text.UTF8Encoding($false)
    $script:Deadline = $Deadline
    $script:SlotName = 'main'
    $script:LogTag = ''
    $script:ReadyServices = @{}
    $script:HeldLocks = @{}

    Import-ProjectConfig $Root
    $script:BaseRef = $script:Base
    Set-WorkDir $Root
}

# (Re)reads .nightshift/config.json from $From (a worktree on the base branch, or the checkout).
function Import-ProjectConfig([string]$From) {
    $script:Config = Read-ProjectConfig $From
    if (-not $script:Config.name) { $script:Config.name = Split-Path $script:ProjectHome -Leaf }
    $script:Protected = Get-ProtectedMap $script:Config
    $script:Base = $script:Config.baseBranch
}

# Points agents, checks and file lookups at $Dir.
function Set-WorkDir([string]$Dir) {
    $script:Repo = $Dir
    $script:TasksPath = Join-Path $Dir $script:Config.files.tasks
    $script:BacklogPath = Join-Path $Dir $script:Config.files.backlog
    Set-Location $Dir
    [Environment]::CurrentDirectory = $Dir
}

# Where the engine's worktrees live: config worktree.root, or "<project>.nightshift" next to the
# project (outside it, so the project's own tools never scan them).
function Get-WorktreeRoot {
    $root = [string]$script:Config.worktree.root
    if ($root) {
        if (-not [IO.Path]::IsPathRooted($root)) { $root = Join-Path $script:ProjectHome $root }
        return [IO.Path]::GetFullPath($root)
    }
    return Join-Path (Split-Path $script:ProjectHome -Parent) "$(Split-Path $script:ProjectHome -Leaf).nightshift"
}

function Get-SlotPath([string]$Slot) { return Join-Path (Get-WorktreeRoot) $Slot }

# ---------------------------------------------------------------- utilities

# Appends from several processes at once (daemon + workers share the log and report).
function Add-SharedText([string]$Path, [string]$Text) {
    $bytes = $script:Utf8.GetBytes($Text)
    for ($i = 0; $i -lt 40; $i++) {
        try {
            $fs = [IO.File]::Open($Path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
            try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
            return
        } catch [System.IO.IOException] { Start-Sleep -Milliseconds (25 * ($i + 1)) }
    }
}

function Write-Log([string]$Message) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $($script:LogTag)$Message"
    Write-Host $line
    Add-SharedText $script:LogFile ($line + "`r`n")
}

# Today's report, .nightshift/reports/<date>.md (gitignored; nothing is committed for it).
function Add-Report([string]$Line) {
    $path = Join-Path $script:ReportsDir "$(Get-Date -Format 'yyyy-MM-dd').md"
    if (-not (Test-Path $path)) { Add-SharedText $path "# Night Shift $(Get-Date -Format 'yyyy-MM-dd') - $($script:Config.name)`n`n" }
    Add-SharedText $path ($Line + "`n")
}

function Stop-Night([string]$Reason) { throw "STOP_NIGHT: $Reason" }

# Clicking into a console window starts a QuickEdit selection, which freezes every write to that
# console until the selection ends, and with it a daemon that logs to the window. Turned off for
# the daemon's own window.
function Disable-ConsoleQuickEdit {
    try {
        Add-Type -Namespace NightShift -Name ConsoleMode -ErrorAction SilentlyContinue -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int handle);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr handle, out uint mode);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr handle, uint mode);
'@
        $h = [NightShift.ConsoleMode]::GetStdHandle(-10)   # STD_INPUT_HANDLE
        $mode = [uint32]0
        if ([NightShift.ConsoleMode]::GetConsoleMode($h, [ref]$mode)) {
            # clear ENABLE_QUICK_EDIT_MODE (0x40); ENABLE_EXTENDED_FLAGS (0x80) makes the change stick
            [void][NightShift.ConsoleMode]::SetConsoleMode($h, [uint32](($mode -band -65) -bor 0x80))
        }
    } catch { }
}

function Assert-NotStopped { if (Test-Path $script:StopFile) { Stop-Night 'stopped on request (STOP file)' } }

function Get-Stamp { return (Get-Date -Format 'yyyyMMdd-HHmmss') }

function Get-SafeId([string]$Id) { return ($Id -replace '[^A-Za-z0-9.-]', '-') }

function Get-Tail([string]$Path, [int]$Lines = 80) {
    if (-not (Test-Path $Path)) { return '' }
    return ((Get-Content $Path -Tail $Lines -Encoding UTF8) -join "`n")
}

function Write-JsonFile([string]$Path, $Object) {
    $tmp = "$Path.$PID.tmp"
    [IO.File]::WriteAllText($tmp, ($Object | ConvertTo-Json -Depth 10), $script:Utf8)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    try { return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json) } catch { return $null }
}

# Small id -> value maps kept in state/ (queue overlay, hints for the next builder).
function Read-StateMap([string]$Name) {
    $map = @{}
    $obj = Read-JsonFile (Join-Path $script:StateDir $Name)
    if ($obj) { foreach ($p in $obj.PSObject.Properties) { $map[$p.Name] = $p.Value } }
    return $map
}

function Write-StateMap([string]$Name, [hashtable]$Map) {
    Write-JsonFile (Join-Path $script:StateDir $Name) ([pscustomobject]$Map)
}

# Runs a command line through cmd.exe with redirected output and a hard timeout.
# Returns the exit code, or -1 on timeout (the whole process tree is killed).
# -AgentResult: the output file is a `claude -p --output-format json` result. Once it holds a
# complete result but the process still hasn't exited (a child it spawned keeps it alive), the
# session is done: after a one-minute grace the tree is ended and 0 returned, instead of waiting
# out the full timeout.
function Invoke-Logged([string]$CommandLine, [string]$OutFile, [string]$ErrFile, [string]$InFile, [int]$TimeoutMinutes, [switch]$AgentResult) {
    $cmd = $CommandLine
    if ($InFile) { $cmd += " < `"$InFile`"" }
    $cmd += " > `"$OutFile`""
    if ($ErrFile) { $cmd += " 2> `"$ErrFile`"" } else { $cmd += ' 2>&1' }
    $p = Start-Process -FilePath $env:ComSpec -ArgumentList "/d /s /c `"$cmd`"" -WorkingDirectory $script:Repo -NoNewWindow -PassThru
    $null = $p.Handle
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $doneAt = $null
    while (-not $p.WaitForExit(10000)) {
        if ((Get-Date) -ge $deadline) {
            & $env:ComSpec /d /c "taskkill /T /F /PID $($p.Id) >nul 2>&1"
            return -1
        }
        if ($AgentResult -and -not $doneAt -and (Test-AgentResultComplete $OutFile)) { $doneAt = Get-Date }
        if ($doneAt -and ((Get-Date) - $doneAt).TotalSeconds -ge 60) {
            Write-Log "the agent finished but its process didn't exit (a child process holds it open); ending it"
            & $env:ComSpec /d /c "taskkill /T /F /PID $($p.Id) >nul 2>&1"
            return 0
        }
    }
    $p.WaitForExit()
    return $p.ExitCode
}

function Test-AgentResultComplete([string]$Path) {
    try {
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try { $text = (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
        if (-not $text.Trim()) { return $false }
        $json = $text | ConvertFrom-Json
        return ([string]$json.type -eq 'result')
    } catch { return $false }
}

# git in $Dir (default: the current work dir). Throws on failure unless -AllowFail.
function Invoke-Git([string]$ArgLine, [switch]$AllowFail, [string]$Dir) {
    if (-not $Dir) { $Dir = $script:Repo }
    $out = & $env:ComSpec /d /s /c "`"git -C `"$Dir`" -c core.safecrlf=false $ArgLine 2>&1`""
    $code = $LASTEXITCODE
    $script:GitExit = $code
    if ($code -ne 0 -and -not $AllowFail) { throw "git $ArgLine failed ($code): $($out -join "`n")" }
    return @($out | Where-Object { $_ -ne $null })
}

function Test-Git([string]$ArgLine, [string]$Dir) {
    Invoke-Git $ArgLine -AllowFail -Dir $Dir | Out-Null
    return ($script:GitExit -eq 0)
}

function Get-GitSha([string]$Ref, [string]$Dir) {
    $out = Invoke-Git "rev-parse -q --verify `"$Ref^{commit}`"" -AllowFail -Dir $Dir
    if ($script:GitExit -ne 0) { return '' }
    return (($out -join '').Trim())
}

# Whether $Old is an ancestor of (or equal to) $New.
function Test-GitAncestor([string]$Old, [string]$New, [string]$Dir) { return (Test-Git "merge-base --is-ancestor $Old $New" $Dir) }

function Get-AheadCount([string]$From, [string]$To = 'HEAD') {
    return [int](((Invoke-Git "rev-list --count $From..$To") -join '').Trim())
}

function Test-TreeDirty([string]$Dir) { return [bool](Invoke-Git 'status --porcelain' -Dir $Dir | Where-Object { $_.Trim() }) }

function Get-CurrentBranch([string]$Dir) { return ((Invoke-Git 'branch --show-current' -Dir $Dir) -join '').Trim() }

function Get-ConflictedPaths { return @(Invoke-Git 'diff --name-only --diff-filter=U' -AllowFail | Where-Object { $_.Trim() }) }

# Commit everything (or the given paths). Returns $true if a commit was made.
function New-Commit([string]$Message, [string[]]$Paths) {
    $msgFile = Join-Path $script:StateDir "commit-msg-$PID.txt"
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
        Assert-NotStopped
        Start-Sleep -Seconds 30
    }
}

# A cross-process lock (a file held open exclusively): released when the process dies, too.
function Enter-NamedLock([string]$Name) {
    if ($script:HeldLocks[$Name]) { return }
    $path = Join-Path $script:LocksDir "$Name.lock"
    $logged = $false
    while ($true) {
        try {
            $script:HeldLocks[$Name] = [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            return
        } catch [System.IO.IOException] {
            if (-not $logged) { Write-Log "waiting for $Name (another worker is using it)"; $logged = $true }
            Assert-NotStopped
            Start-Sleep -Seconds 5
        }
    }
}

function Exit-NamedLock([string]$Name) {
    if ($script:HeldLocks[$Name]) { $script:HeldLocks[$Name].Dispose(); $script:HeldLocks.Remove($Name) }
}

# Windows toast (and an ntfy.sh-style POST when notify.ntfyUrl is set) for things that need you.
function Send-Notice([string]$Title, [string]$Message) {
    Write-Log "notice: $Title - $Message"
    if ($script:Config.notify.toast) {
        try {
            [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
            [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
            $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
            $esc = { param($s) [Security.SecurityElement]::Escape($s) }
            $xml.LoadXml("<toast><visual><binding template=`"ToastGeneric`"><text>$(& $esc $Title)</text><text>$(& $esc $Message)</text></binding></visual></toast>")
            $app = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
            [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($app).Show((New-Object Windows.UI.Notifications.ToastNotification $xml))
        } catch { }
    }
    if ($script:Config.notify.ntfyUrl) {
        try { Invoke-RestMethod -Method Post -Uri $script:Config.notify.ntfyUrl -Body "$Title - $Message" -TimeoutSec 15 | Out-Null } catch { }
    }
}

# ---------------------------------------------------------------- prompts

# The project's rules file plus the tasks file's rule sections (config `ruleSections`), inlined
# so agents never read the whole tasks file just to find them.
function Get-ProjectRules {
    $parts = @()
    $path = Join-Path $script:Repo $script:Config.files.rules
    if (Test-Path $path) { $parts += [IO.File]::ReadAllText($path).Trim() }
    $sections = Get-MatchingSections $script:TasksPath $script:Config.ruleSections
    if ($sections) { $parts += ($sections -replace '(?m)^## ', '### ') }
    if (-not $parts) { return '(none)' }
    return ($parts -join "`n`n")
}

# The notes file inlined (kept short by `notesMaxLines`): every session needs it, and reading it
# as a tool call costs a turn plus the file again in every later turn's context.
function Get-NotesText {
    $path = Join-Path $script:Repo $script:Config.files.notes
    if (-not (Test-Path $path)) { return '(none yet)' }
    $text = [IO.File]::ReadAllText($path).Trim()
    if ($text) { return $text } else { return '(none yet)' }
}

# What landed most recently on the base, so a session builds on it instead of redoing it.
function Get-RecentCommitsText {
    $lines = @(Invoke-Git "log -n 10 --no-merges --oneline $($script:BaseRef)" -AllowFail | Where-Object { $_.Trim() })
    if ($script:GitExit -ne 0 -or -not $lines) { return '(none)' }
    return ($lines -join "`n")
}

function Get-VerifyText {
    $lines = Get-ApplicableGateLines $script:Config.gates $script:Repo (Read-TaskList $script:TasksPath)
    if (-not $lines) { return '- (no automated checks configured)' }
    return ($lines -join "`n")
}

function Get-ProtectedText($Item) {
    $names = foreach ($p in $script:Protected.PSObject.Properties) {
        if (-not (@($p.Value) | Where-Object { $Item.Ids -contains $_ })) { "``$($p.Name)``" }
    }
    return ($names -join ', ')
}

function Expand-Template([string]$Name, [hashtable]$Values) {
    $override = Join-Path $script:Repo ".nightshift\prompts\$Name.md"
    $path = if (Test-Path $override) { $override } else { Join-Path $script:EngineDir "prompts\$Name.md" }
    $text = [IO.File]::ReadAllText($path)
    $common = @{
        TASKS_FILE    = $script:Config.files.tasks
        BACKLOG_FILE  = $script:Config.files.backlog
        NOTES_FILE    = $script:Config.files.notes
        PLAN_FILE     = $script:Config.files.plan
        BASE          = $script:BaseRef
        VERIFY        = Get-VerifyText
        PROJECT_RULES = Get-ProjectRules
        NOTES         = Get-NotesText
        PHASE_CONTEXT = '(not applicable)'
        RECENT_COMMITS = Get-RecentCommitsText
    }
    foreach ($k in $common.Keys) { if (-not $Values.ContainsKey($k)) { $Values[$k] = $common[$k] } }
    foreach ($k in $Values.Keys) { $text = $text.Replace("{{$k}}", [string]$Values[$k]) }
    return $text
}

# ---------------------------------------------------------------- agents

# The settings file a building agent runs under (see New-AgentSettings), written per slot.
function Write-AgentSettings {
    $policy = $null
    foreach ($rel in '.nightshift\agent-settings.json', '.claude\settings.json') {
        $policy = Read-JsonFile (Join-Path $script:Repo $rel)
        if ($policy) { break }
    }
    if (-not $policy) { $policy = Read-JsonFile (Join-Path $script:EngineDir 'templates\agent-settings.base.json') }
    $path = Join-Path $script:SettingsDir "agent-$($script:SlotName).json"
    Write-JsonFile $path (New-AgentSettings $policy $script:Config.files.tasks)
    return $path
}

function Write-ResolverSettings {
    $guard = Join-Path $script:EngineDir 'lib\guard.ps1'
    $roots = @($script:ProjectHome, (Get-WorktreeRoot)) -join ';'
    $branches = @('main', 'master', $script:Base | Select-Object -Unique) -join ';'
    $hook = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$guard`" -GuardHook -GuardRoots `"$roots`" -GuardBranches `"$branches`""
    $path = Join-Path $script:SettingsDir 'resolver.json'
    Write-JsonFile $path (New-ResolverSettings $hook)
    return $path
}

# One headless session. Policy: worker (allowlist + engine denies), readonly (Read/Grep/Glob),
# resolver (permission checks bypassed; hard denies + the guard hook).
# Project settings are the only settings source: your user-level hooks and plugins would defeat
# the policy, and only the project source loads CLAUDE.md. The policy itself comes via --settings,
# and deny rules there win over anything the project file allows.
function Invoke-Agent([string]$Role, [string]$Prompt, [string]$Model, [string]$Policy = 'worker') {
    $base = Join-Path $script:SessionsDir "$(Get-Stamp)-$($script:SlotName)-$Role"
    $in = "$base.prompt.md"; $out = "$base.out.json"; $err = "$base.err.log"
    [IO.File]::WriteAllText($in, $Prompt, $script:Utf8)

    # --exclude-dynamic-system-prompt-sections keeps the system prompt identical across sessions
    # so back-to-back sessions reuse its prompt cache instead of re-writing it.
    $cli = "claude -p --output-format json --model $Model --setting-sources project --strict-mcp-config --exclude-dynamic-system-prompt-sections"
    $budget = if ($Policy -eq 'resolver') { [double]$script:Config.resolver.maxBudgetUsd } else { [double]$script:Config.agentMaxBudgetUsd }
    if ($budget -gt 0) { $cli += " --max-budget-usd $budget" }
    switch ($Policy) {
        'readonly' {
            $cli += ' --tools "Read,Grep,Glob" --permission-mode default --allowedTools "Read" "Grep" "Glob" --disallowedTools "Edit" "Write" "Bash" "PowerShell" "NotebookEdit"'
        }
        'resolver' {
            $cli += " --settings `"$(Write-ResolverSettings)`" --dangerously-skip-permissions"
        }
        default {
            $tasks = $script:Config.files.tasks
            $cli += " --settings `"$(Write-AgentSettings)`" --tools `"Bash,Read,Edit,Write,Grep,Glob`" --permission-mode acceptEdits"
            $cli += " --disallowedTools `"Edit($tasks)`" `"Edit(/$tasks)`" `"Write($tasks)`" `"Write(/$tasks)`""
        }
    }
    Write-Log "agent $Role ($Model) -> $base"
    $code = Invoke-Logged $cli $out $err $in $script:Config.agentTimeoutMinutes -AgentResult

    $raw = if (Test-Path $out) { [IO.File]::ReadAllText($out) } else { '' }
    $errText = if (Test-Path $err) { [IO.File]::ReadAllText($err) } else { '' }
    $result = $raw; $isError = ($code -ne 0); $cost = 0.0; $overBudget = $false
    try {
        $json = $raw | ConvertFrom-Json
        $result = [string]$json.result
        # Hit the budget cap: the work so far is on the branch; checks/fixer take it from there.
        if ([string]$json.subtype -match 'budget') { $overBudget = $true; Write-Log "agent $Role stopped at its budget cap" }
        if ($json.is_error) { $isError = $true }
        if ($json.total_cost_usd) { $cost = [double]$json.total_cost_usd }
    } catch { }
    Add-SharedText (Join-Path $script:StateDir 'cost.log') ("$(Get-Date -Format 'yyyy-MM-dd')`t$Role`t$cost`n")
    $all = "$result`n$errText`n$raw"
    $limit = $isError -and -not $overBudget -and (Test-LimitHit $all)
    return [pscustomobject]@{
        ExitCode   = $code
        TimedOut   = ($code -eq -1)
        OverBudget = $overBudget
        IsError    = $isError
        LimitHit   = $limit
        Transient  = ($isError -and -not $limit -and -not $overBudget -and (Test-TransientError $all))
        Result     = $result
        ErrorText  = $errText
        Log        = $base
    }
}

# ---------------------------------------------------------------- usage limits (shared by all workers)

function Read-LimitState { return (Read-JsonFile $script:LimitFile) }

function Set-LimitState([datetime]$Until, [bool]$Probe) {
    $cur = Read-LimitState
    if ($cur -and [datetime]$cur.until -ge $Until) { return }
    Write-JsonFile $script:LimitFile ([pscustomobject]@{ until = $Until.ToString('s'); probe = $Probe; set = (Get-Date).ToString('s') })
    Add-Report "- [limit] $(Get-Date -Format 'HH:mm') usage limit; every worker waits until $($Until.ToString('ddd HH:mm'))"
    Send-Notice "Night Shift hit the usage limit ($($script:Config.name))" "Every worker waits until $($Until.ToString('ddd HH:mm')), then carries on."
}

# A one-line haiku session: is the subscription usable again?
function Test-UsageAvailable {
    $base = Join-Path $script:SessionsDir "$(Get-Stamp)-$($script:SlotName)-probe"
    [IO.File]::WriteAllText("$base.prompt.md", 'Reply with the single word OK.', $script:Utf8)
    $code = Invoke-Logged 'claude -p --output-format json --model haiku --setting-sources "" --strict-mcp-config --tools ""' "$base.out.json" "$base.err.log" "$base.prompt.md" 5
    $text = "$(Get-Tail "$base.out.json" 50)`n$(Get-Tail "$base.err.log" 50)"
    if ($code -ne 0 -and (Test-LimitHit $text)) { return [pscustomobject]@{ Ok = $false; Text = $text } }
    return [pscustomobject]@{ Ok = $true; Text = $text }
}

# Blocks while a usage limit is in force (written by whichever worker hit it). When the reset
# time was unknown, a cheap probe confirms the limit is gone before real work resumes.
function Wait-ForUsageLimit {
    $logged = $false
    while ($true) {
        $l = Read-LimitState
        if (-not $l) { return }
        $until = [datetime]$l.until
        if ((Get-Date) -lt $until) {
            if (-not $logged) { Write-Log "usage limit in force; waiting until $until"; $logged = $true }
            if ((Get-Date) -ge $script:Deadline) { Stop-Night 'deadline reached during a usage-limit wait' }
            Assert-NotStopped
            Start-Sleep -Seconds 60
            continue
        }
        if ($l.probe) {
            $probe = Test-UsageAvailable
            if (-not $probe.Ok) {
                $reset = Get-LimitResetTime $probe.Text (Get-Date)
                $d = Get-LimitDecision $reset ([datetime]::MaxValue) (Get-Date) $script:Config.limitFallbackSleepMinutes $script:Config.schedule.resumeAt
                Write-JsonFile $script:LimitFile ([pscustomobject]@{ until = $d.Until.ToString('s'); probe = $d.Probe; set = (Get-Date).ToString('s') })
                Write-Log "still limited; next check $($d.Until)"
                continue
            }
        }
        Remove-Item $script:LimitFile -ErrorAction SilentlyContinue
        Write-Log 'usage limit cleared'
        return
    }
}

# Retries through usage limits (every worker waits for the reset) and transient API errors.
# -IgnoreDeadline: used for the review of work that already passed its checks, so a deadline
# never throws away a finished task.
function Invoke-AgentSafely([string]$Role, [string]$Prompt, [string]$Model, [string]$Policy = 'worker', [switch]$IgnoreDeadline) {
    $transientTries = 0
    while ($true) {
        Assert-NotStopped
        if (-not $IgnoreDeadline -and (Get-Date) -ge $script:Deadline) { Stop-Night 'deadline reached' }
        Wait-ForUsageLimit
        $r = Invoke-Agent -Role $Role -Prompt $Prompt -Model $Model -Policy $Policy
        if ($r.LimitHit) {
            $now = Get-Date
            $reset = Get-LimitResetTime "$($r.Result)`n$($r.ErrorText)" $now
            $d = Get-LimitDecision $reset $script:Deadline $now $script:Config.limitFallbackSleepMinutes $script:Config.schedule.resumeAt
            Write-Log "usage limit hit; $($d.Action) until $($d.Until)"
            if ($d.Action -eq 'stop') { Stop-Night "usage limit resets after the deadline ($($d.Until.ToString('HH:mm')))" }
            Set-LimitState $d.Until $d.Probe
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
    $log = Join-Path $script:SessionsDir "$(Get-Stamp)-$($script:SlotName)-docker.log"
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
    if (-not (Test-DockerUp)) { throw 'Docker is not running' }
}

# services.<name> = { when, docker, check, start, startTimeoutMinutes, forPhases[], forTextMatch, exclusive }
function Initialize-Service([string]$Name) {
    if ($script:ReadyServices[$Name]) { return }
    $svc = $script:Config.services.$Name
    if (-not $svc) { throw "Unknown service '$Name' in config" }
    if (-not (Test-GateCondition $svc.when $script:Repo @() @())) { return }
    if ($svc.docker) { Start-DockerDesktop }
    if ($svc.check) {
        $log = Join-Path $script:SessionsDir "$(Get-Stamp)-$($script:SlotName)-svc-$Name-check.log"
        if ((Invoke-Logged $svc.check $log $null $null 5) -eq 0) { $script:ReadyServices[$Name] = $true; return }
    }
    if ($svc.start) {
        $log = Join-Path $script:SessionsDir "$(Get-Stamp)-$($script:SlotName)-svc-$Name-start.log"
        $timeout = if ($svc.startTimeoutMinutes) { [int]$svc.startTimeoutMinutes } else { 20 }
        Write-Log "starting service $Name"
        Enter-NamedLock "svc-$Name"
        try { $code = Invoke-Logged $svc.start $log $null $null $timeout } finally { Exit-NamedLock "svc-$Name" }
        if ($code -ne 0) { throw "service $Name failed to start (see $log)" }
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

function Get-TreeOf([string]$Rev) {
    return ((Invoke-Git "log -1 --format=%T $Rev" -AllowFail) -join '').Trim()
}

# Compared against the count where this branch started (see Select-TestBaseline).
function Get-TestBaseline {
    $b = Read-JsonFile $script:BaselineFile
    $start = ''
    if ($b -and $script:BaseRef) {
        $mb = ((Invoke-Git "merge-base $($script:BaseRef) HEAD" -AllowFail) -join '').Trim()
        if ($script:GitExit -eq 0 -and $mb) { $start = Get-TreeOf $mb }
    }
    return (Select-TestBaseline $b $start)
}

# Called on the branch about to land, so HEAD's tree is the tree the base gets.
function Set-TestBaseline([int]$Count) {
    Write-JsonFile $script:BaselineFile (Add-TestBaseline (Read-JsonFile $script:BaselineFile) $Count (Get-TreeOf 'HEAD'))
}

function Invoke-Gate([string]$Name, [string]$CommandLine, [string]$Label, [int]$TimeoutMinutes) {
    $log = Join-Path $script:SessionsDir "$(Get-Stamp)-$($script:SlotName)-gate-$Label-$Name.log"
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

# Gates marked "exclusive" (or using an "exclusive" service) run one worker at a time.
# -AllowTestDrop (a [test-audit] task) skips the drop check but still needs passing tests.
function Invoke-Gates([string]$Label, [string[]]$ChangedPaths, [switch]$AllowTestDrop) {
    $result = [pscustomobject]@{ Pass = $true; Feedback = ''; TestCount = $null; Summary = ''; Gate = '' }
    $tasks = Read-TaskList $script:TasksPath
    $ran = New-Object System.Collections.ArrayList
    foreach ($gate in $script:Config.gates) {
        if (-not (Test-GateCondition $gate.when $script:Repo $ChangedPaths $tasks)) { continue }
        foreach ($s in @($gate.services)) { if ($s) { Initialize-Service $s } }
        $timeout = if ($gate.timeoutMinutes) { [int]$gate.timeoutMinutes } else { [int]$script:Config.gateTimeoutMinutes }
        $locks = @()
        if ($gate.exclusive) { $locks += "gate-$($gate.name)" }
        foreach ($s in @($gate.services)) { if ($s -and $script:Config.services.$s.exclusive) { $locks += "svc-$s" } }
        foreach ($l in $locks) { Enter-NamedLock $l }
        try { $g = Invoke-Gate $gate.name $gate.run $Label $timeout } finally { foreach ($l in $locks) { Exit-NamedLock $l } }
        [void]$ran.Add($gate.name)

        if ($gate.autoFix) {
            if ($g.Pass -and (Test-TreeDirty)) { New-Commit "style($Label): $($gate.name)" | Out-Null }
            continue
        }
        if ($gate.countTests) { $result.TestCount = Get-PassedTestCount $g.Output $gate.testCountPattern }
        if (-not $g.Pass) { $result.Pass = $false; $result.Feedback = $g.Feedback; $result.Gate = $gate.name; return $result }
        if ($gate.countTests -and $null -ne $result.TestCount) {
            if ($AllowTestDrop) {
                if ($result.TestCount -le 0) {
                    $result.Pass = $false
                    $result.Gate = $gate.name
                    $result.Feedback = "No passing tests were counted. A test audit may remove low-value tests, not all of them."
                    return $result
                }
                continue
            }
            $baseline = Get-TestBaseline
            if ($result.TestCount -lt $baseline) {
                $result.Pass = $false
                $result.Gate = $gate.name
                $result.Feedback = "Passing test count dropped from $baseline to $($result.TestCount). Tests must not be deleted or skipped; restore them."
                return $result
            }
        }
    }
    $result.Summary = if ($ran.Count) { "checks: $($ran -join ', ')" + $(if ($null -ne $result.TestCount) { "; $($result.TestCount) tests" } else { '' }) } else { 'no checks applied yet' }
    return $result
}

function Invoke-Review($Item) {
    $stat = (Invoke-Git "diff --stat $($script:BaseRef)...HEAD") -join "`n"
    $excludes = (@($script:Config.reviewExclude) | ForEach-Object { "`"$_`"" }) -join ' '
    $diff = (Invoke-Git "diff $($script:BaseRef)...HEAD -- . $excludes") -join "`n"
    if ($diff.Length -gt 120000) { $diff = $diff.Substring(0, 120000) + "`n... [diff truncated - read the files directly]" }
    # Small diffs get the cheap reviewer; real logic gets the full one.
    $lines = Get-DiffLineCount ((Invoke-Git "diff --shortstat $($script:BaseRef)...HEAD -- . $excludes") -join ' ')
    $model = $script:Config.models.reviewer
    if ($script:Config.review.smallModel -and $lines -le [int]$script:Config.review.smallDiffLines) { $model = $script:Config.review.smallModel }
    Write-Log "review: $lines changed lines -> $model"
    $prompt = Expand-Template 'reviewer' @{ TASK = $Item.TaskText; STAT = $stat; DIFF = $diff }
    for ($i = 0; $i -lt 2; $i++) {
        $r = Invoke-AgentSafely -Role "review-$(Get-SafeId $Item.Id)" -Prompt $prompt -Model $model -Policy 'readonly' -IgnoreDeadline
        $verdict = Get-ReviewVerdict $r.Result
        if ($verdict) { return $verdict }
    }
    Write-Log 'reviewer gave no parseable verdict twice; checks passed, approving'
    return [pscustomobject]@{ verdict = 'approve'; issues = @('(reviewer gave no verdict)') }
}

# ---------------------------------------------------------------- items

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

# The end of the newest builder/fixer session for this item: its final message and stderr.
function Get-LastSessionTail([string]$Safe) {
    $out = Get-ChildItem $script:SessionsDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*-build-$Safe.out.json" -or $_.Name -like "*-fix-$Safe.out.json" } |
        Sort-Object Name | Select-Object -Last 1
    if (-not $out) { return '(no session output found)' }
    $raw = [IO.File]::ReadAllText($out.FullName)
    $text = try { [string]($raw | ConvertFrom-Json).result } catch { $raw }
    $lines = @($text -split "`r?`n")
    $tail = ($lines | Select-Object -Last 60) -join "`n"
    $err = Get-Tail ($out.FullName -replace '\.out\.json$', '.err.log') 20
    if ($err.Trim()) { $tail += "`n--- stderr ---`n$err" }
    if ($tail.Length -gt 6000) { $tail = $tail.Substring($tail.Length - 6000) }
    return $tail.Replace('```', "'''")
}

function Get-RunningPid {
    if (-not (Test-Path $script:LockFile)) { return $null }
    $otherPid = (Get-Content $script:LockFile -Raw).Trim()
    if ($otherPid -and (Get-Process -Id $otherPid -ErrorAction SilentlyContinue)) { return [int]$otherPid }
    return $null
}
