# Parsing and updating TASKS.md / BACKLOG.md checkbox lists.
# Line format: "- [<status>] <id> <text>"  status: ' ' open, 'x' done, '>' user-owned, '!' failed.

$script:TaskLinePattern = '^- \[([ x>!])\] (\S+) (.*)$'
# Task ids: "3.4", or "2.3a" when a task was split after the fact.
$script:TaskIdPattern = '^\d+\.\d+[a-z]?$'

function Read-TextFile([string]$Path) {
    $text = [IO.File]::ReadAllText($Path)
    $nl = if ($text -match "`r`n") { "`r`n" } else { "`n" }
    return @{ Lines = @($text -split "`r?`n"); NewLine = $nl }
}

function Write-TextFile([string]$Path, [string[]]$Lines, [string]$NewLine) {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, ($Lines -join $NewLine), $utf8NoBom)
}

function Read-TaskList([string]$Path) {
    $file = Read-TextFile $Path
    $phase = ''
    $inFence = $false
    $tasks = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $file.Lines.Count; $i++) {
        $line = $file.Lines[$i]
        if ($line -match '^\s*```') { $inFence = -not $inFence; continue }
        if ($inFence) { continue }
        if ($line -match '^## Phase (\d+)') { $phase = $Matches[1]; continue }
        if ($line -match '^## ') { $phase = ''; continue }
        if ($line -match $script:TaskLinePattern) {
            [void]$tasks.Add([pscustomobject]@{
                Id     = $Matches[2]
                Status = $Matches[1]
                Text   = $Matches[3]
                Phase  = $phase
                Line   = $i
            })
        }
    }
    return , $tasks.ToArray()
}

# First open task in file order. A failed ([!]) task blocks the rest of its phase,
# because later tasks in a phase usually build on earlier ones. [>] tasks are skipped.
function Get-NextTask($Tasks, [string[]]$SkipIds = @()) {
    $blockedPhases = @{}
    foreach ($t in $Tasks) {
        if ($t.Id -notmatch $script:TaskIdPattern) { continue }
        if ($t.Status -eq '!') { $blockedPhases[$t.Phase] = $true; continue }
        if ($t.Status -ne ' ') { continue }
        if ($blockedPhases.ContainsKey($t.Phase)) { continue }
        if ($SkipIds -contains $t.Id) { $blockedPhases[$t.Phase] = $true; continue }
        return $t
    }
    return $null
}

# The next task plus following small open tasks of the same phase, so one agent session
# (and one review) covers several tiny steps. Batching stops at the first task that is not
# open, too long (a proxy for "not small"), in $NoBatchIds, or from another phase.
function Get-NextTaskBatch($Tasks, [int]$MaxTasks = 1, [int]$MaxTextLength = 240, [string[]]$NoBatchIds = @()) {
    $first = Get-NextTask $Tasks
    if (-not $first) { return , @() }
    $batch = New-Object System.Collections.ArrayList
    [void]$batch.Add($first)
    if ($MaxTasks -le 1 -or $first.Text.Length -gt $MaxTextLength -or $NoBatchIds -contains $first.Id) { return , $batch.ToArray() }
    $started = $false
    foreach ($t in $Tasks) {
        if (-not $started) { if ($t.Id -eq $first.Id) { $started = $true }; continue }
        if ($batch.Count -ge $MaxTasks) { break }
        if ($t.Phase -ne $first.Phase -or $t.Status -ne ' ' -or $t.Id -notmatch $script:TaskIdPattern) { break }
        if ($t.Text.Length -gt $MaxTextLength -or $NoBatchIds -contains $t.Id) { break }
        [void]$batch.Add($t)
    }
    return , $batch.ToArray()
}

# The "## Phase N" section of a tasks file (heading through the line before the next "## "),
# given to agents instead of the whole file.
function Get-PhaseSection([string]$Path, [string]$Phase) {
    if (-not $Phase) { return '' }
    $lines = (Read-TextFile $Path).Lines
    $out = New-Object System.Collections.ArrayList
    $inside = $false
    foreach ($line in $lines) {
        if ($line -match '^## ') {
            if ($inside) { break }
            if ($line -match "^## Phase $([regex]::Escape($Phase))\b") { $inside = $true }
        }
        if ($inside) { [void]$out.Add($line) }
    }
    return (($out -join "`n").Trim())
}

# Every `## ` section whose heading matches $HeadingPattern, in file order (e.g. the rules
# appendix of the tasks file, so agents get it in their prompt instead of reading the whole file).
function Get-MatchingSections([string]$Path, [string]$HeadingPattern) {
    if (-not $HeadingPattern -or -not (Test-Path $Path)) { return '' }
    $out = New-Object System.Collections.ArrayList
    $inside = $false
    foreach ($line in (Read-TextFile $Path).Lines) {
        if ($line -match '^## ') { $inside = ($line -match $HeadingPattern) }
        if ($inside) { [void]$out.Add($line) }
    }
    return (($out -join "`n").Trim())
}

function Get-NextBacklogTask($Tasks, [string[]]$SkipIds = @()) {
    foreach ($t in $Tasks) {
        if ($t.Id -notmatch '^B\d+$' -or $t.Status -ne ' ') { continue }
        if ($t.Text -notmatch 'status:\s*approved') { continue }
        if ($SkipIds -contains $t.Id) { continue }
        return $t
    }
    return $null
}

function Get-NextBacklogId($Tasks) {
    $max = 0
    foreach ($t in $Tasks) {
        if ($t.Id -match '^B(\d+)$' -and [int]$Matches[1] -gt $max) { $max = [int]$Matches[1] }
    }
    return "B$($max + 1)"
}

function Set-TaskStatus([string]$Path, [string]$Id, [string]$Status, [string]$Note = '') {
    $file = Read-TextFile $Path
    $found = $false
    for ($i = 0; $i -lt $file.Lines.Count; $i++) {
        if ($file.Lines[$i] -match $script:TaskLinePattern -and $Matches[2] -eq $Id) {
            $text = $Matches[3] -replace '\s*<!-- failed .*? -->$', ''
            if ($Status -eq 'x' -and $Id -match '^B\d+$') { $text = $text -replace 'status:\s*approved', 'status: done' }
            $line = "- [$Status] $Id $text"
            if ($Note) {
                $clean = ($Note -replace '--', '-' -replace '\s+', ' ').Trim()
                if ($clean.Length -gt 160) { $clean = $clean.Substring(0, 160) + '...' }
                $line += " <!-- failed $(Get-Date -Format 'yyyy-MM-dd'): $clean -->"
            }
            $file.Lines[$i] = $line
            $found = $true
            break
        }
    }
    if (-not $found) { throw "Task $Id not found in $Path" }
    Write-TextFile $Path $file.Lines $file.NewLine
}

function Get-PendingUserTasks($Tasks) {
    return @($Tasks | Where-Object { $_.Status -eq '>' })
}
