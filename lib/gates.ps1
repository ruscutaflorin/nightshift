# Pure helpers behind the merge gates (kept free of git/process calls so they're testable).

# Changed paths that touch a protected prefix none of the given tasks owns.
# $Protected is the config.protectedPaths object: prefix -> [task ids allowed to edit it].
function Get-ProtectedPathViolations([string[]]$ChangedPaths, $Protected, [string[]]$TaskIds) {
    $violations = New-Object System.Collections.ArrayList
    foreach ($path in $ChangedPaths) {
        $p = $path -replace '\\', '/'
        foreach ($prop in $Protected.PSObject.Properties) {
            $prefix = $prop.Name
            $owners = @($prop.Value)
            $hit = if ($prefix.EndsWith('/')) { $p.StartsWith($prefix) } else { $p -eq $prefix }
            $owned = [bool]($owners | Where-Object { $TaskIds -contains $_ })
            if ($hit -and -not $owned) {
                [void]$violations.Add($p)
            }
        }
    }
    return , @($violations | Select-Object -Unique)
}

# Default: dart/flutter test summary ("00:05 +42 ~1: All tests passed!").
$script:DefaultTestCountPattern = '\+(\d+)(?: ~\d+)?(?: -\d+)?: (?:All tests passed|Some tests failed)'

# Number of passing tests: group 1 of the LAST match of $Pattern in the output.
# Examples: jest 'Tests:.*?(\d+) passed', pytest '(\d+) passed'. Returns $null when nothing matches.
function Get-PassedTestCount([string]$Output, [string]$Pattern) {
    if (-not $Pattern) { $Pattern = $script:DefaultTestCountPattern }
    $found = $null
    foreach ($m in [regex]::Matches($Output, $Pattern)) {
        $found = [int]$m.Groups[1].Value
    }
    return $found
}

# One informative line from a failure reason for the report / task note: skips code fences and
# bare headers ("The reviewer requested changes:" -> "The reviewer requested changes: <first issue>").
function Get-ShortReason([string]$Reason, [int]$Max = 200) {
    if (-not $Reason) { return 'failed without a recorded reason' }
    $lines = @($Reason -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^```' })
    if ($lines.Count -eq 0) { return 'failed without a recorded reason' }
    $first = $lines[0] -replace '\s*Last lines:\s*$', ''
    if ($lines[0] -match 'Last lines:\s*$' -and $lines.Count -gt 1) {
        $first = "$first -> $($lines[-1])"
    } elseif ($first -match ':\s*$' -and $lines.Count -gt 1) {
        $first = $first.TrimEnd(':', ' ') + ': ' + ($lines[1] -replace '^- ', '')
    }
    if ($first.Length -gt $Max) { $first = $first.Substring(0, $Max) + '...' }
    return $first
}

# Insertions + deletions from `git diff --shortstat` ("3 files changed, 40 insertions(+), 2 deletions(-)").
function Get-DiffLineCount([string]$ShortStat) {
    $n = 0
    if ($ShortStat -match '(\d+) insertions?\(\+\)') { $n += [int]$Matches[1] }
    if ($ShortStat -match '(\d+) deletions?\(-\)') { $n += [int]$Matches[1] }
    return $n
}

# Whether a gate/service condition holds. All given keys must hold; a missing/empty $When is true.
#   fileExists: "path" | ["a","b"]   every path exists (relative to the repo)
#   changed:    "glob" | ["a/*","b"] any changed path matches any wildcard
#   taskDone:   "3.19"               that task is [x] in the tasks file
function Test-GateCondition($When, [string]$Repo, [string[]]$ChangedPaths, $Tasks) {
    if (-not $When) { return $true }
    if ($When.PSObject.Properties['fileExists']) {
        foreach ($p in @($When.fileExists)) {
            if (-not (Test-Path (Join-Path $Repo $p))) { return $false }
        }
    }
    if ($When.PSObject.Properties['changed']) {
        $hit = $false
        foreach ($c in @($ChangedPaths)) {
            foreach ($pattern in @($When.changed)) {
                if (($c -replace '\\', '/') -like $pattern) { $hit = $true }
            }
        }
        if (-not $hit) { return $false }
    }
    if ($When.PSObject.Properties['taskDone']) {
        if (-not (Test-TaskDone $Tasks ([string]$When.taskDone))) { return $false }
    }
    return $true
}

# Extract the reviewer's verdict from its final message: the last single-line JSON object
# containing "verdict" (the reviewer prompt asks for exactly that). Returns $null if absent/invalid.
function Get-ReviewVerdict([string]$Text) {
    if (-not $Text) { return $null }
    $lines = @($Text -split "`r?`n")
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = $lines[$i].Trim().Trim('`').Trim()
        if (-not ($line.StartsWith('{') -and $line -match '"verdict"')) { continue }
        try {
            $obj = $line | ConvertFrom-Json
            if ($obj.verdict -in @('approve', 'changes')) {
                if (-not $obj.PSObject.Properties['issues']) { $obj | Add-Member issues @() }
                return $obj
            }
        } catch { }
    }
    return $null
}

function Test-TaskDone($Tasks, [string]$Id) {
    return [bool]($Tasks | Where-Object { $_.Id -eq $Id -and $_.Status -eq 'x' })
}
