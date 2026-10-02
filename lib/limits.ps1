# Detecting subscription usage limits in claude CLI output, deciding how long to sleep, and the
# active-hours windows the daemon starts new work in.

$script:LimitPatterns = @(
    'usage limit',
    'hit your (usage |session |weekly )?limit',
    'limit reached',
    'rate_limit_error',
    '(5-hour|five-hour|weekly|session) limit',
    'out of (extra )?usage'
)

$script:TransientPatterns = @(
    'overloaded',
    '\b529\b',
    '\b50[0234]\b',
    'ECONNRESET',
    'ETIMEDOUT',
    'socket hang up',
    'network error'
)

function Test-LimitHit([string]$Text) {
    if (-not $Text) { return $false }
    foreach ($p in $script:LimitPatterns) { if ($Text -match $p) { return $true } }
    return $false
}

function Test-TransientError([string]$Text) {
    if (-not $Text) { return $false }
    foreach ($p in $script:TransientPatterns) { if ($Text -match $p) { return $true } }
    return $false
}

function ConvertTo-Hour24([int]$Hour, [string]$AmPm) {
    $h = $Hour % 12
    if ($AmPm -match '^p') { $h += 12 }
    return $h
}

# Returns the local DateTime the limit resets, or $null if it can't be parsed.
# Handles: "usage limit reached|1759000000" (epoch), "resets 3am", "resets at 3:30 pm",
# "resets Oct 2, 5pm" / "resets Oct 2 at 5pm" (weekly).
function Get-LimitResetTime([string]$Text, [datetime]$Now) {
    if (-not $Text) { return $null }

    if ($Text -match '\|(\d{10})\b') {
        return [DateTimeOffset]::FromUnixTimeSeconds([long]$Matches[1]).LocalDateTime
    }

    $months = 'Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec'
    if ($Text -match "resets?\s+(?:on\s+)?($months)[a-z]*\.?\s+(\d{1,2}),?\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)") {
        $month = [array]::IndexOf(($months -split '\|'), $Matches[1]) + 1
        $day = [int]$Matches[2]
        $minute = if ($Matches[4]) { [int]$Matches[4] } else { 0 }
        $hour = ConvertTo-Hour24 ([int]$Matches[3]) $Matches[5]
        $candidate = New-Object DateTime($Now.Year, $month, $day, $hour, $minute, 0)
        if ($candidate -lt $Now.AddDays(-1)) { $candidate = $candidate.AddYears(1) }
        return $candidate
    }

    if ($Text -match 'resets?\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)') {
        $minute = if ($Matches[2]) { [int]$Matches[2] } else { 0 }
        $hour = ConvertTo-Hour24 ([int]$Matches[1]) $Matches[3]
        $candidate = $Now.Date.AddHours($hour).AddMinutes($minute)
        if ($candidate -le $Now) { $candidate = $candidate.AddDays(1) }
        return $candidate
    }

    return $null
}

# Next occurrence of the "HH:mm" stop hour after $Now (a run started at 23:30 stops tomorrow 07:00).
function Get-Deadline([string]$HHmm, [datetime]$Now) {
    $t = [datetime]::ParseExact($HHmm, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    $d = $Now.Date.AddHours($t.Hour).AddMinutes($t.Minute)
    if ($d -le $Now) { $d = $d.AddDays(1) }
    return $d
}

# Decide what to do after a limit hit: sleep until the reset (+2 min buffer), or until the first
# $ResumeAt ("HH:mm") at or after it, or stop if that lands after the run's deadline (only a run
# started with -For / -Until has one). Probe = the reset time was unknown, so check with a cheap
# session before spending a real one.
function Get-LimitDecision($ResetTime, [datetime]$Deadline, [datetime]$Now, [int]$FallbackMinutes, [string]$ResumeAt) {
    $until = if ($ResetTime) { ([datetime]$ResetTime).AddMinutes(2) } else { $Now.AddMinutes($FallbackMinutes) }
    if ($ResumeAt) { $until = Get-Deadline $ResumeAt $until.AddSeconds(-1) }
    $action = if ($until -ge $Deadline) { 'stop' } else { 'sleep' }
    return [pscustomobject]@{ Action = $action; Until = $until; Probe = (-not $ResetTime) }
}

# "HH:mm-HH:mm" (may cross midnight; equal ends = all day).
function ConvertTo-TimeWindow([string]$Text) {
    if ($Text -notmatch '^\s*(\d{1,2}):(\d{2})\s*-\s*(\d{1,2}):(\d{2})\s*$') { throw "Can't parse active-hours window '$Text' (use e.g. 22:00-07:00)" }
    return [pscustomobject]@{
        Start = New-TimeSpan -Hours ([int]$Matches[1]) -Minutes ([int]$Matches[2])
        End   = New-TimeSpan -Hours ([int]$Matches[3]) -Minutes ([int]$Matches[4])
    }
}

# Whether $Now falls in any of the windows. No windows = always active.
function Test-InActiveHours($Windows, [datetime]$Now) {
    $list = @($Windows | Where-Object { $_ })
    if (-not $list) { return $true }
    $t = $Now.TimeOfDay
    foreach ($w in $list) {
        $win = ConvertTo-TimeWindow $w
        if ($win.Start -eq $win.End) { return $true }
        if ($win.Start -lt $win.End) {
            if ($t -ge $win.Start -and $t -lt $win.End) { return $true }
        } elseif ($t -ge $win.Start -or $t -lt $win.End) { return $true }
    }
    return $false
}

# $Now if active, else the next window start.
function Get-NextActiveStart($Windows, [datetime]$Now) {
    if (Test-InActiveHours $Windows $Now) { return $Now }
    $best = $null
    foreach ($w in @($Windows | Where-Object { $_ })) {
        $c = $Now.Date.Add((ConvertTo-TimeWindow $w).Start)
        if ($c -le $Now) { $c = $c.AddDays(1) }
        if (-not $best -or $c -lt $best) { $best = $c }
    }
    return $best
}
