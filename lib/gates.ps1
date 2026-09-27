# Pure helpers behind the merge gates (kept free of git/process calls so they're testable).

# Changed paths that touch a protected prefix the task doesn't own.
# $Protected is the config.protectedPaths object: prefix -> [task ids allowed to edit it].
function Get-ProtectedPathViolations([string[]]$ChangedPaths, $Protected, [string]$TaskId) {
    $violations = New-Object System.Collections.ArrayList
    foreach ($path in $ChangedPaths) {
        $p = $path -replace '\\', '/'
        foreach ($prop in $Protected.PSObject.Properties) {
            $prefix = $prop.Name
            $owners = @($prop.Value)
            $hit = if ($prefix.EndsWith('/')) { $p.StartsWith($prefix) } else { $p -eq $prefix }
            if ($hit -and -not ($owners -contains $TaskId)) {
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
