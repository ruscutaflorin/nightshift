# Parsing and updating TASKS.md / BACKLOG.md checkbox lists, and picking runnable work per lane.
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

# A backlog item's checkbox line plus its indented detail lines (Why / Scope / Acceptance /
# Size). The builder needs all of it: the checkbox line alone is only the title.
function Get-BacklogItemBlock([string]$Path, [string]$Id) {
    $out = New-Object System.Collections.ArrayList
    $inside = $false
    foreach ($line in (Read-TextFile $Path).Lines) {
        if ($line -match $script:TaskLinePattern) {
            if ($inside) { break }
            if ($Matches[2] -eq $Id) { $inside = $true; [void]$out.Add($line) }
            continue
        }
        if ($inside) {
            if ($line -match '^\s+\S') { [void]$out.Add($line) } else { break }
        }
    }
    return (($out -join "`n").Trim())
}

# Backlog item lines by id ("- [ ] B4 ... status: proposed"), the snapshot a product round
# is checked against.
function Get-BacklogLineMap($Tasks) {
    $map = @{}
    foreach ($t in $Tasks) {
        if ($t.Id -match '^B\d+$') { $map[$t.Id] = "- [$($t.Status)] $($t.Id) $($t.Text)" }
    }
    return $map
}

# Supervisor guardrail after a product round: the agent may only add items. Lines of items in
# $Before (id -> original line) are restored verbatim, so the human's proposed / approved /
# rejected decisions can't change. A new item keeps "status: approved" only when $AutoApprove
# is on, its Size is S or M, and fewer than $Max were kept before it (file order); every other
# approval is turned back into "status: proposed". Returns the ids left approved.
function Limit-ProductApprovals([string]$Path, [hashtable]$Before, [bool]$AutoApprove, [int]$Max) {
    $file = Read-TextFile $Path
    $lines = $file.Lines
    $kept = New-Object System.Collections.ArrayList
    $changed = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch $script:TaskLinePattern) { continue }
        $id = $Matches[2]
        if ($id -notmatch '^B\d+$') { continue }
        if ($Before.ContainsKey($id)) {
            if ($lines[$i] -ne $Before[$id]) { $lines[$i] = $Before[$id]; $changed = $true }
            continue
        }
        if ($lines[$i] -notmatch 'status:\s*approved') { continue }
        $size = ''
        for ($j = $i + 1; $j -lt $lines.Count -and $lines[$j] -match '^\s+\S'; $j++) {
            if ($lines[$j] -match 'Size:\s*([SML])\b') { $size = $Matches[1]; break }
        }
        if ($AutoApprove -and $size -in @('S', 'M') -and $kept.Count -lt $Max) {
            [void]$kept.Add($id)
        } else {
            $lines[$i] = $lines[$i] -replace 'status:\s*approved', 'status: proposed'
            $changed = $true
        }
    }
    if ($changed) { Write-TextFile $Path $lines $file.NewLine }
    return , $kept.ToArray()
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

# Phase heading flags: "## Phase 3 - Name (parallel)" runs as its own lane next to the others;
# "(after 1, 2)" also runs as its own lane, once phases 1 and 2 have no open or failed tasks.
function Get-PhaseFlags([string]$Path) {
    $map = @{}
    if (-not (Test-Path $Path)) { return $map }
    $inFence = $false
    foreach ($line in (Read-TextFile $Path).Lines) {
        if ($line -match '^\s*```') { $inFence = -not $inFence; continue }
        if ($inFence -or $line -notmatch '^## Phase (\d+)\b(.*)$') { continue }
        $id = $Matches[1]; $rest = $Matches[2]
        $after = @()
        if ($rest -match '\((?:after|needs)\s+(?:phases?\s+)?([\d,\s]+)\)') { $after = @($Matches[1] -split '[,\s]+' | Where-Object { $_ }) }
        $map[$id] = [pscustomobject]@{ Parallel = ($rest -match '\(parallel\)'); After = $after }
    }
    return $map
}

# Engine-side task states (state/queue.json, id -> {state, text, ...}) layered over the file:
# failed / blocked / resolving -> '!', human -> '>', open -> ' ' (reopens a [!] line). An entry
# only applies while the task's text is unchanged, so rewriting or splitting a task clears it.
function Merge-TaskOverlay($Tasks, $Overlay) {
    $out = New-Object System.Collections.ArrayList
    foreach ($t in @($Tasks)) {
        $status = $t.Status
        $o = if ($Overlay) { $Overlay[$t.Id] } else { $null }
        if ($o -and $status -ne 'x' -and (-not $o.text -or $o.text -eq $t.Text)) {
            switch ([string]$o.state) {
                { $_ -in @('failed', 'blocked', 'resolving') } { $status = '!' }
                'human' { $status = '>' }
                'open' { if ($status -eq '!') { $status = ' ' } }
            }
        }
        [void]$out.Add([pscustomobject]@{ Id = $t.Id; Status = $status; Text = $t.Text; Phase = $t.Phase; Line = $t.Line })
    }
    return , $out.ToArray()
}

# The next batch for every lane that isn't busy, in file order. Phases share the lane "tasks"
# (strictly in order, as before); a "(parallel)" / "(after N)" phase - or every phase when
# $AllParallel - is its own lane "phase:N", held back while any of its "after" phases has open
# or failed tasks. Returns [pscustomobject]@{ Lane; Tasks } items.
function Get-TaskLaneBatches($Tasks, $Flags, [string[]]$BusyLanes, [bool]$AllParallel, [int]$MaxTasks = 1, [int]$MaxTextLength = 240, [string[]]$NoBatchIds = @()) {
    $lanes = [ordered]@{}
    foreach ($t in @($Tasks)) {
        if ($t.Id -notmatch $script:TaskIdPattern) { continue }
        $f = if ($Flags) { $Flags[$t.Phase] } else { $null }
        $own = $AllParallel -or ($f -and ($f.Parallel -or @($f.After).Count))
        $lane = if ($own) { "phase:$($t.Phase)" } else { 'tasks' }
        if (-not $lanes.Contains($lane)) { $lanes[$lane] = New-Object System.Collections.ArrayList }
        [void]$lanes[$lane].Add($t)
    }
    $result = New-Object System.Collections.ArrayList
    foreach ($lane in $lanes.Keys) {
        if ($BusyLanes -contains $lane) { continue }
        if ($lane -ne 'tasks') {
            $f = if ($Flags) { $Flags[$lane.Substring(6)] } else { $null }
            if ($f -and @($f.After).Count) {
                $waiting = @($Tasks | Where-Object { @($f.After) -contains $_.Phase -and $_.Id -match $script:TaskIdPattern -and $_.Status -in @(' ', '!') })
                if ($waiting) { continue }
            }
        }
        $batch = Get-NextTaskBatch ($lanes[$lane].ToArray()) $MaxTasks $MaxTextLength $NoBatchIds
        if ($batch.Count) { [void]$result.Add([pscustomobject]@{ Lane = $lane; Tasks = $batch }) }
    }
    return , $result.ToArray()
}

# Every open approved backlog item whose lane ("backlog:<id>") isn't busy, in file order.
function Get-BacklogLaneItems($Tasks, [string[]]$BusyLanes) {
    $result = New-Object System.Collections.ArrayList
    foreach ($t in @($Tasks)) {
        if ($t.Id -notmatch '^B\d+$' -or $t.Status -ne ' ' -or $t.Text -notmatch 'status:\s*approved') { continue }
        if ($BusyLanes -contains "backlog:$($t.Id)") { continue }
        [void]$result.Add($t)
    }
    return , $result.ToArray()
}

# Phases (in file order) that still have open or failed tasks.
function Get-OpenPhaseIds($Tasks) {
    $seen = New-Object System.Collections.ArrayList
    foreach ($t in @($Tasks)) {
        if ($t.Id -notmatch $script:TaskIdPattern -or $t.Status -notin @(' ', '!') -or -not $t.Phase) { continue }
        if (-not $seen.Contains($t.Phase)) { [void]$seen.Add($t.Phase) }
    }
    return , $seen.ToArray()
}

# The planner's dependencies layered under the heading flags: a phase whose heading says
# "(parallel)" or "(after N)" keeps that; every other planned phase becomes its own lane that
# waits for its "after" phases. $Plan: phase -> after-phases (see Get-PhasePlan).
function Merge-PhasePlan($Flags, $Plan) {
    $out = @{}
    if ($Flags) { foreach ($k in $Flags.Keys) { $out[$k] = $Flags[$k] } }
    if (-not $Plan) { return $out }
    foreach ($phase in $Plan.Keys) {
        $f = $out[$phase]
        if ($f -and ($f.Parallel -or @($f.After).Count)) { continue }
        $after = @($Plan[$phase])
        $out[$phase] = [pscustomobject]@{ Parallel = ($after.Count -eq 0); After = $after }
    }
    return $out
}
