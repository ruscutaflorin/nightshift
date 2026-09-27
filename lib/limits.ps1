# Detecting subscription usage limits in claude CLI output and deciding whether to
# sleep until the reset or end the night.

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

# Decide what to do after a limit hit: sleep until the reset (+2 min buffer) or stop
# if the reset lands after the night's deadline.
function Get-LimitDecision($ResetTime, [datetime]$Deadline, [datetime]$Now, [int]$FallbackMinutes) {
    $until = if ($ResetTime) { ([datetime]$ResetTime).AddMinutes(2) } else { $Now.AddMinutes($FallbackMinutes) }
    if ($until -ge $Deadline) {
        return [pscustomobject]@{ Action = 'stop'; Until = $until }
    }
    return [pscustomobject]@{ Action = 'sleep'; Until = $until }
}
