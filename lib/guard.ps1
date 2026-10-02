# The resolver's hard limits. It runs with --dangerously-skip-permissions, so this PreToolUse
# hook (plus the deny rules in its settings) is what stands between it and the machine.
#
# Dot-sourced: defines Get-GuardVerdict (pure, tested).
# As a hook:   powershell -File guard.ps1 -GuardHook -GuardRoots "D:\repo;D:\repo.nightshift" -GuardBranches "main;master;develop"
#              reads the tool call as JSON on stdin; exit 2 + a reason on stderr blocks it.
param([switch]$GuardHook, [string]$GuardRoots, [string]$GuardBranches)

# Git Bash "/c/x" -> "C:\x"; "~" / $HOME / $env:USERPROFILE -> the profile folder. Relative paths
# resolve against $Cwd. Returns a full Windows path, or '' when it can't be judged.
function ConvertTo-GuardPath([string]$Path, [string]$Cwd) {
    $p = $Path.Trim().Trim('"', "'")
    if (-not $p) { return '' }
    $profileDir = $env:USERPROFILE
    $p = $p -replace '^(~|\$HOME|\$env:USERPROFILE|%USERPROFILE%)(?=$|[\\/])', $profileDir
    if ($p -match '^/([a-zA-Z])(/|$)') { $p = "$($Matches[1]):\" + $p.Substring(3) }
    elseif ($p -match '^/') { return 'X:\outside' }   # /etc, /tmp ... : not one of ours
    $p = $p -replace '/', '\'
    $p = $p -replace '[*?].*$', ''                    # judge a wildcard by the folder before it
    if (-not $p) { $p = '.' }
    try {
        if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $Cwd $p }
        return [IO.Path]::GetFullPath($p).TrimEnd('\')
    } catch { return '' }
}

function Test-GuardPathInside([string]$Full, [string[]]$Roots) {
    if (-not $Full) { return $false }
    foreach ($r in @($Roots | Where-Object { $_ })) {
        $root = [IO.Path]::GetFullPath($r).TrimEnd('\')
        if ($Full -ieq $root -or $Full.StartsWith("$root\", [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

$script:GuardSecretPattern = '(?i)([\\/]\.ssh([\\/]|$)|\.claude[\\/]\.credentials|[\\/]\.claude\.json$|\.claude\.json\b|\bid_(rsa|ed25519|ecdsa)\b|\.pem\b|\.pfx\b|[\\/]\.aws[\\/]credentials|\.git-credentials)'

# '' when the tool call is fine, else the reason it is blocked.
#   $Roots: folders the resolver may write/delete in (repo, worktrees, temp)
#   $Branches: branches it may never push to or delete (main, master, the base branch)
function Get-GuardVerdict([string]$Tool, $ToolInput, [string]$Cwd, [string[]]$Roots, [string[]]$Branches) {
    if (-not $Cwd) { $Cwd = (Get-Location).Path }
    if ($Tool -in @('Read', 'Edit', 'Write', 'MultiEdit', 'NotebookEdit')) {
        $path = [string]$ToolInput.file_path
        if (-not $path) { $path = [string]$ToolInput.notebook_path }
        if ($path -match $script:GuardSecretPattern) { return "credentials are off limits ($path)" }
        if ($Tool -ne 'Read') {
            $full = ConvertTo-GuardPath $path $Cwd
            if (-not (Test-GuardPathInside $full $Roots)) { return "writing outside the repo and its worktrees ($path)" }
        }
        return ''
    }
    if ($Tool -notin @('Bash', 'PowerShell')) { return '' }

    $command = [string]$ToolInput.command
    if ($command -match $script:GuardSecretPattern) { return 'the command touches credentials' }
    $protected = (@($Branches | Where-Object { $_ }) | ForEach-Object { [regex]::Escape($_) }) -join '|'
    if (-not $protected) { $protected = 'main|master' }

    foreach ($seg in ($command -split '&&|\|\||;|\||\r?\n')) {
        $s = $seg.Trim()
        if (-not $s) { continue }
        if ($s -match '(?i)\bgit\b.*\bpush\b') {
            if ($s -match '(?i)\s(-f|--force|--force-with-lease|--force-if-includes|--mirror)\b' -or $s -match '\s\+\S') { return 'force-pushing is not allowed' }
            if ($s -match '(?i)\s(--delete|-d)\b' -or $s -match '\s:\S') { return 'deleting remote branches is not allowed' }
            if ($s -match "(?i)(\s|:)($protected)(\s|$)") { return "pushing to a protected branch is not allowed ($s)" }
        }
        if ($s -match '(?i)\bgit\b.*\breset\b.*--hard') { return 'git reset --hard is not allowed; restore files with git checkout -- <path>' }
        if ($s -match '(?i)\bgit\b.*\b(filter-branch|filter-repo)\b') { return 'rewriting history is not allowed' }
        if ($s -match '(?i)\bgit\b.*\bupdate-ref\b') { return 'moving refs directly is not allowed' }
        if ($s -match '(?i)\bgit\b.*\bworktree\s+(remove|prune|move)\b') { return 'the engine owns the worktrees' }
        if ($s -match "(?i)\bgit\b.*\bbranch\b.*\s(-d|-D|--delete|-m|-M|--move|-f|--force)\b.*(\s|^)($protected)(\s|$)") { return 'deleting, moving or resetting a protected branch is not allowed' }
        if ($s -match '(?i)\bgh\s+repo\s+(delete|create|rename|archive|edit)\b' -or $s -match '(?i)\bgh\s+(secret|auth|ssh-key|gpg-key)\b' -or $s -match '(?i)\bgh\s+release\s+delete\b') { return 'that gh command changes the account or repository settings' }
        if ($s -match '(?i)\bgh\s+api\b.*(-X|--method)\s*(DELETE|PUT|PATCH)') { return 'mutating GitHub API calls are not allowed' }
        if ($s -match '(?i)(^|\s)(format(\.com)?\s+[a-z]:|diskpart|bcdedit|cipher\s+/w|shutdown(\.exe)?\s|Stop-Computer|Restart-Computer|Clear-Disk|Format-Volume|Initialize-Disk|reg(\.exe)?\s+delete|Remove-ItemProperty\s+.*HKLM)') { return 'machine-level destructive command' }

        # Deletes: every path argument must be inside the allowed roots.
        if ($s -match '(?i)^(sudo\s+)?(rm|rmdir|rd|del|erase|Remove-Item|ri|unlink)(\.exe)?(\s|$)(.*)$') {
            $cmdStyle = $Matches[2] -in @('rmdir', 'rd', 'del', 'erase')
            $rest = $Matches[5]
            $tokens = @([regex]::Matches($rest, '"[^"]*"|''[^'']*''|\S+') | ForEach-Object { $_.Value })
            $skipNext = $false
            foreach ($tok in $tokens) {
                if ($skipNext) { $skipNext = $false; continue }
                if ($tok -match '^-(ErrorAction|ea|Filter|Include|Exclude|Credential|Stream)$') { $skipNext = $true; continue }
                if ($tok.StartsWith('-')) { continue }                                   # -rf, -Recurse, -Force
                if ($cmdStyle -and $tok -match '^/[sqfap]$') { continue }                 # rd /s /q, del /f
                $full = ConvertTo-GuardPath $tok $Cwd
                if (-not (Test-GuardPathInside $full $Roots)) { return "deleting outside the repo and its worktrees ($tok)" }
            }
        }
    }
    return ''
}

if ($GuardHook) {
    try {
        [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
        $call = [Console]::In.ReadToEnd() | ConvertFrom-Json
    } catch { exit 0 }
    $roots = @($GuardRoots -split ';' | Where-Object { $_ }) + @($env:TEMP)
    $why = Get-GuardVerdict ([string]$call.tool_name) $call.tool_input ([string]$call.cwd) $roots @($GuardBranches -split ';')
    if ($why) {
        [Console]::Error.WriteLine("Blocked by the Night Shift guard: $why. Find another way, or report it under ""human"" in your outcome.")
        exit 2
    }
    exit 0
}
