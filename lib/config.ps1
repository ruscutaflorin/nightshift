# Project configuration: discovery, defaults, merging, durations. Pure where possible (testable).

$script:DefaultConfigJson = @'
{
  "name": "",
  "baseBranch": "develop",
  "branchPrefix": "night/",
  "stopAt": "07:00",
  "models": { "builder": "sonnet", "escalate": "opus", "reviewer": "sonnet", "product": "opus" },
  "maxAttempts": 2,
  "agentTimeoutMinutes": 45,
  "gateTimeoutMinutes": 20,
  "polishCap": 4,
  "maxProposalsPerNight": 5,
  "limitFallbackSleepMinutes": 30,
  "batch": { "maxTasks": 3, "maxTextLength": 240 },
  "review": { "smallDiffLines": 150, "smallModel": "haiku" },
  "notesMaxLines": 60,
  "files": { "tasks": "TASKS.md", "backlog": "BACKLOG.md", "notes": "NOTES.md", "plan": "PLAN.md", "rules": ".nightshift/rules.md" },
  "gates": [],
  "services": {},
  "protectedPaths": {},
  "reviewExclude": [":(exclude)*.lock", ":(exclude)package-lock.json", ":(exclude)**/*.png", ":(exclude)**/*.jpg"]
}
'@

# Deep-merge two PSCustomObjects: objects merge key by key, everything else (arrays, scalars) is replaced.
function Merge-Config($Base, $Override) {
    if ($null -eq $Override) { return $Base }
    if ($null -eq $Base -or -not ($Base -is [pscustomobject]) -or -not ($Override -is [pscustomobject])) { return $Override }
    $result = [pscustomobject]@{}
    foreach ($p in $Base.PSObject.Properties) { $result | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
    foreach ($p in $Override.PSObject.Properties) {
        if ($result.PSObject.Properties[$p.Name]) {
            $result.($p.Name) = Merge-Config $result.($p.Name) $p.Value
        } else {
            $result | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value
        }
    }
    return $result
}

# Walk up from $Start to the first directory containing .nightshift/config.json.
function Find-ProjectRoot([string]$Start) {
    $dir = (Resolve-Path $Start).Path
    while ($dir) {
        if (Test-Path (Join-Path $dir '.nightshift\config.json')) { return $dir }
        $parent = Split-Path $dir -Parent
        if ($parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

function Read-ProjectConfig([string]$Root) {
    $defaults = $script:DefaultConfigJson | ConvertFrom-Json
    $project = Get-Content (Join-Path $Root '.nightshift\config.json') -Raw | ConvertFrom-Json
    $config = Merge-Config $defaults $project
    if (-not $config.name) { $config.name = Split-Path $Root -Leaf }
    return $config
}

# Protected paths = engine-owned paths (never editable by agents) + the project's own map.
function Get-ProtectedMap($Config) {
    $map = [pscustomobject]@{}
    foreach ($p in @('.nightshift/', '.claude/', 'CLAUDE.md', $Config.files.tasks)) {
        $map | Add-Member -NotePropertyName $p -NotePropertyValue @() -Force
    }
    foreach ($p in $Config.protectedPaths.PSObject.Properties) {
        $map | Add-Member -NotePropertyName $p.Name -NotePropertyValue @($p.Value) -Force
    }
    return $map
}

# "2h", "90m", "1h30m", "45" (minutes) -> TimeSpan. Throws on garbage.
function ConvertTo-Duration([string]$Text) {
    $t = $Text.Trim().ToLowerInvariant()
    if ($t -match '^\d+$') { return [TimeSpan]::FromMinutes([int]$t) }
    if ($t -match '^(?:(\d+)h)?\s*(?:(\d+)m)?$' -and ($Matches[1] -or $Matches[2])) {
        $h = if ($Matches[1]) { [int]$Matches[1] } else { 0 }
        $m = if ($Matches[2]) { [int]$Matches[2] } else { 0 }
        return New-Object TimeSpan($h, $m, 0)
    }
    throw "Can't parse duration '$Text' (use e.g. 2h, 90m, 1h30m)"
}
