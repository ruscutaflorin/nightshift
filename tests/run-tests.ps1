# Self-tests for the night-shift helpers. No Pester dependency (Windows PowerShell 5.1 ships Pester 3).
# Run: nightshift test   (or: powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1)

$ErrorActionPreference = 'Stop'
$lib = Join-Path (Split-Path $PSScriptRoot -Parent) 'lib'
. (Join-Path $lib 'tasks.ps1')
. (Join-Path $lib 'limits.ps1')
. (Join-Path $lib 'gates.ps1')
. (Join-Path $lib 'config.ps1')

$script:Failures = 0
$script:Count = 0
function Assert-Equal($Expected, $Actual, [string]$Name) {
    $script:Count++
    if ("$Expected" -ne "$Actual") {
        $script:Failures++
        Write-Host "FAIL $Name`n     expected: $Expected`n     actual:   $Actual" -ForegroundColor Red
    } else {
        Write-Host "ok   $Name"
    }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) "night-shift-tests-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
try {
    # ---------------------------------------------------------- tasks.ps1
    $tasksFile = Join-Path $tmp 'TASKS.md'
    $content = @(
        '# Tasks', '',
        '## Phase 0 - Toolchain', '',
        '- [x] 0.1 done already',
        '- [>] 0.2 user owned', '',
        '## Phase 1 - Scaffold', '',
        '- [!] 1.1 failed before <!-- failed 2026-09-01: boom -->',
        '- [ ] 1.2 blocked by 1.1', '',
        '## Phase 2 - Data', '',
        '- [>] 2.1 user thing',
        '- [ ] 2.2 first open in phase 2',
        '- [ ] 2.3 second open', '',
        '## Architecture rules', '',
        '- A.1 not a task'
    ) -join "`n"
    [IO.File]::WriteAllText($tasksFile, $content, (New-Object Text.UTF8Encoding($false)))

    $tasks = Read-TaskList $tasksFile
    Assert-Equal 7 $tasks.Count 'parses only checkbox lines'
    Assert-Equal '1' ($tasks | Where-Object Id -eq '1.2').Phase 'tracks phase numbers'

    $next = Get-NextTask $tasks
    Assert-Equal '2.2' $next.Id 'failed task blocks rest of its phase; [>] skipped'

    $next = Get-NextTask $tasks @('2.2')
    Assert-Equal '' "$($next.Id)" 'skip list blocks the rest of that phase too'

    Set-TaskStatus $tasksFile '2.2' 'x'
    $tasks = Read-TaskList $tasksFile
    Assert-Equal 'x' ($tasks | Where-Object Id -eq '2.2').Status 'marks done'
    Assert-Equal '2.3' (Get-NextTask $tasks).Id 'advances after done'

    Set-TaskStatus $tasksFile '2.3' '!' 'gate -- test failed'
    $line = ([IO.File]::ReadAllText($tasksFile) -split "`n") | Where-Object { $_ -match '2\.3' }
    Assert-Equal $true ($line -match '^- \[!\] 2\.3 second open <!-- failed \d{4}-\d{2}-\d{2}: gate - test failed -->$') 'failure note appended, -- sanitized'

    Set-TaskStatus $tasksFile '1.1' ' '
    $line = ([IO.File]::ReadAllText($tasksFile) -split "`n") | Where-Object { $_ -match '^- \[.\] 1\.1 ' }
    Assert-Equal '- [ ] 1.1 failed before' $line 'reopening strips old failure note'

    Assert-Equal $false ([IO.File]::ReadAllText($tasksFile) -match "`r") 'keeps LF line endings'
    Assert-Equal 2 @(Get-PendingUserTasks (Read-TaskList $tasksFile)).Count 'lists [>] tasks'

    $backlogFile = Join-Path $tmp 'BACKLOG.md'
    $bl = @(
        '```',
        '- [ ] B<n> Title - status: proposed | approved',
        '```',
        '- [ ] B1 Proposed thing - status: proposed',
        '  - Why: x',
        '- [ ] B2 Approved thing - status: approved',
        '- [x] B3 Done thing - status: done'
    ) -join "`n"
    [IO.File]::WriteAllText($backlogFile, $bl, (New-Object Text.UTF8Encoding($false)))
    $backlog = Read-TaskList $backlogFile
    Assert-Equal 'B1 B2 B3' (($backlog | ForEach-Object { $_.Id }) -join ' ') 'ignores example lines inside code fences'
    Assert-Equal 'B2' (Get-NextBacklogTask $backlog).Id 'picks approved backlog item only'
    Assert-Equal 'B4' (Get-NextBacklogId $backlog) 'next backlog id'
    Set-TaskStatus $backlogFile 'B2' 'x'
    Assert-Equal $true ([IO.File]::ReadAllText($backlogFile) -match '- \[x\] B2 Approved thing - status: done') 'done backlog item flips status text'

    # ---------------------------------------------------------- limits.ps1
    $now = [datetime]'2026-09-27 23:40'
    Assert-Equal $true (Test-LimitHit "You've hit your limit - resets 3am (Europe/Bucharest)") 'detects "hit your limit"'
    Assert-Equal $true (Test-LimitHit 'Claude AI usage limit reached|1790000000') 'detects legacy usage-limit format'
    Assert-Equal $false (Test-LimitHit 'All tests passed') 'no false positive'
    Assert-Equal $true (Test-TransientError 'API Error: 529 overloaded_error') 'detects overloaded'

    Assert-Equal ([datetime]'2026-09-28 03:00') (Get-LimitResetTime "You've hit your limit - resets 3am" $now) 'parses "resets 3am" as next occurrence'
    Assert-Equal ([datetime]'2026-09-28 01:30') (Get-LimitResetTime 'limit reached, resets at 1:30 AM' $now) 'parses "resets at 1:30 AM"'
    Assert-Equal ([datetime]'2026-09-27 23:50') (Get-LimitResetTime 'resets 11:50pm' $now) 'same-day reset later tonight'
    Assert-Equal ([datetime]'2026-10-02 17:00') (Get-LimitResetTime 'weekly limit - resets Oct 2, 5pm' $now) 'parses weekly reset date'
    $epoch = [DateTimeOffset]::FromUnixTimeSeconds(1790000000).LocalDateTime
    Assert-Equal $epoch (Get-LimitResetTime 'usage limit reached|1790000000' $now) 'parses epoch'
    Assert-Equal '' "$(Get-LimitResetTime 'usage limit reached' $now)" 'unparseable -> null'

    $deadline = Get-Deadline '07:00' $now
    Assert-Equal ([datetime]'2026-09-28 07:00') $deadline 'deadline rolls to next morning'
    Assert-Equal ([datetime]'2026-09-27 07:00') (Get-Deadline '07:00' ([datetime]'2026-09-27 02:00')) 'deadline same morning after midnight'

    $d = Get-LimitDecision ([datetime]'2026-09-28 03:00') $deadline $now 30
    Assert-Equal 'sleep' $d.Action 'sleeps when reset is before the deadline'
    Assert-Equal ([datetime]'2026-09-28 03:02') $d.Until 'adds 2 minute buffer'
    $d = Get-LimitDecision ([datetime]'2026-09-28 08:00') $deadline $now 30
    Assert-Equal 'stop' $d.Action 'stops when reset is after the deadline'
    $d = Get-LimitDecision $null $deadline $now 30
    Assert-Equal ([datetime]'2026-09-28 00:10') $d.Until 'fallback sleep when reset unknown'

    # ---------------------------------------------------------- gates.ps1
    $protected = '{"factory/":[],"TASKS.md":[],"test/architecture/":["1.12","1.13"],"analysis_options.yaml":["1.6"]}' | ConvertFrom-Json
    $v = Get-ProtectedPathViolations @('lib/a.dart', 'test/architecture/import_rules_test.dart', 'TASKS.md') $protected '3.4'
    Assert-Equal 'test/architecture/import_rules_test.dart TASKS.md' ($v -join ' ') 'flags protected paths the task does not own'
    $v = Get-ProtectedPathViolations @('test/architecture/import_rules_test.dart') $protected '1.12'
    Assert-Equal 0 $v.Count 'owner task may edit its protected path'
    $v = Get-ProtectedPathViolations @('lib/TASKS.md', 'factoryx/a') $protected '3.4'
    Assert-Equal 0 $v.Count 'exact-file and prefix matching do not over-match'

    Assert-Equal 42 (Get-PassedTestCount "00:01 +10: loading`n00:05 +42 ~1: All tests passed!") 'passed test count'
    Assert-Equal 40 (Get-PassedTestCount '00:05 +40 -2: Some tests failed.') 'passed count with failures'
    Assert-Equal '' "$(Get-PassedTestCount 'no summary')" 'no summary -> null'

    $r = Get-ReviewVerdict "Looks fine.`n{`"verdict`":`"approve`",`"issues`":[]}"
    Assert-Equal 'approve' $r.verdict 'reads approve verdict'
    $r = Get-ReviewVerdict "Problems.`n``{`"verdict`":`"changes`",`"issues`":[`"lib/a.dart:3 - bug - fix`"]}``"
    Assert-Equal 'changes' $r.verdict 'reads changes verdict inside backticks'
    Assert-Equal 1 @($r.issues).Count 'keeps issues'
    Assert-Equal '' "$(Get-ReviewVerdict 'no json here')" 'missing verdict -> null'
    Assert-Equal '' "$(Get-ReviewVerdict '{"verdict":"maybe"}')" 'invalid verdict value -> null'

    Assert-Equal 7 (Get-PassedTestCount 'Tests:       1 failed, 7 passed, 8 total' 'Tests:\s+(?:\d+ \w+, )*(\d+) passed') 'custom pattern (jest)'
    Assert-Equal 12 (Get-PassedTestCount '===== 12 passed in 0.31s =====' '(\d+) passed') 'custom pattern (pytest)'

    New-Item -ItemType Directory -Force (Join-Path $tmp 'test') | Out-Null
    [IO.File]::WriteAllText((Join-Path $tmp 'pubspec.yaml'), 'name: x')
    $tl = Read-TaskList $tasksFile
    Assert-Equal $true (Test-GateCondition $null $tmp @() $tl) 'no condition -> true'
    Assert-Equal $true (Test-GateCondition ('{"fileExists":["pubspec.yaml","test"]}' | ConvertFrom-Json) $tmp @() $tl) 'fileExists all present'
    Assert-Equal $false (Test-GateCondition ('{"fileExists":"nope.txt"}' | ConvertFrom-Json) $tmp @() $tl) 'fileExists missing'
    Assert-Equal $true (Test-GateCondition ('{"changed":"supabase/*"}' | ConvertFrom-Json) $tmp @('lib/a.dart', 'supabase/migrations/1.sql') $tl) 'changed glob matches'
    Assert-Equal $false (Test-GateCondition ('{"changed":["supabase/*"]}' | ConvertFrom-Json) $tmp @('lib/a.dart') $tl) 'changed glob no match'
    Assert-Equal $true (Test-GateCondition ('{"taskDone":"0.1"}' | ConvertFrom-Json) $tmp @() $tl) 'taskDone satisfied'
    Assert-Equal $false (Test-GateCondition ('{"taskDone":"1.2","fileExists":"pubspec.yaml"}' | ConvertFrom-Json) $tmp @() $tl) 'all keys must hold'

    $v = Get-ProtectedPathViolations @('test/architecture/a.dart') $protected @('1.11', '1.12')
    Assert-Equal 0 $v.Count 'a batch owns a path if any of its tasks owns it'
    Assert-Equal 42 (Get-DiffLineCount ' 3 files changed, 40 insertions(+), 2 deletions(-)') 'diff line count'
    Assert-Equal 1 (Get-DiffLineCount ' 1 file changed, 1 insertion(+)') 'diff line count, singular'
    Assert-Equal 0 (Get-DiffLineCount '') 'empty diff'

    # ---------------------------------------------------------- batching + phase slice
    $batchFile = Join-Path $tmp 'BATCH.md'
    $long = 'x' * 300
    $bt = @(
        '## Phase 3 - Engine', '',
        '- [x] 3.1 done',
        '- [ ] 3.2 small a',
        '- [ ] 3.3 small b',
        '- [ ] 3.4 small c',
        '- [ ] 3.5 small d', '',
        '## Phase 4 - Data', '',
        '- [ ] 4.1 small e',
        "- [ ] 4.2 $long",
        '- [ ] 4.3 small f', '',
        '## Rules', '- A.1 not a task'
    ) -join "`n"
    [IO.File]::WriteAllText($batchFile, $bt, (New-Object Text.UTF8Encoding($false)))
    $bl2 = Read-TaskList $batchFile
    Assert-Equal '3.2 3.3 3.4' ((Get-NextTaskBatch $bl2 3 240 @() | ForEach-Object { $_.Id }) -join ' ') 'batches up to maxTasks in one phase'
    Assert-Equal '3.2' ((Get-NextTaskBatch $bl2 1 240 @() | ForEach-Object { $_.Id }) -join ' ') 'maxTasks 1 disables batching'
    Assert-Equal '3.2' ((Get-NextTaskBatch $bl2 3 240 @('3.2') | ForEach-Object { $_.Id }) -join ' ') 'no-batch ids run alone'
    Set-TaskStatus $batchFile '3.2' 'x'; Set-TaskStatus $batchFile '3.3' 'x'; Set-TaskStatus $batchFile '3.4' 'x'
    $bl2 = Read-TaskList $batchFile
    Assert-Equal '3.5' ((Get-NextTaskBatch $bl2 3 240 @() | ForEach-Object { $_.Id }) -join ' ') 'batch never crosses a phase'
    Set-TaskStatus $batchFile '3.5' 'x'
    $bl2 = Read-TaskList $batchFile
    Assert-Equal '4.1' ((Get-NextTaskBatch $bl2 3 240 @() | ForEach-Object { $_.Id }) -join ' ') 'long task ends the batch'
    Set-TaskStatus $batchFile '4.1' 'x'
    $bl2 = Read-TaskList $batchFile
    Assert-Equal '4.2' ((Get-NextTaskBatch $bl2 3 240 @() | ForEach-Object { $_.Id }) -join ' ') 'long task runs alone'
    $emptyBatch = Get-NextTaskBatch @() 3 240 @()
    Assert-Equal 0 $emptyBatch.Count 'empty list -> empty batch'

    $section = Get-PhaseSection $batchFile '4'
    Assert-Equal $true ($section.StartsWith('## Phase 4') -and $section -match '4\.3 small f' -and $section -notmatch '3\.5|A\.1') 'phase section is just that phase'
    Assert-Equal '' (Get-PhaseSection $batchFile '9') 'unknown phase -> empty'
    Assert-Equal $true ((Get-PhaseSection $batchFile '3') -notmatch 'Phase 4') 'phase 3 does not bleed into phase 4'

    Assert-Equal 'The reviewer requested changes: a.json:3 - near-duplicate - replace it' (Get-ShortReason "The reviewer requested changes:`n- a.json:3 - near-duplicate - replace it`n- b.json:1 - x") 'short reason names the first reviewer issue'
    Assert-Equal "Check 'test' failed, exit code 1. -> 00:05 +40 -2: Some tests failed." (Get-ShortReason "Check 'test' failed, exit code 1. Last lines:`n``````n00:01 +3: loading`n00:05 +40 -2: Some tests failed.`n``````") 'short reason for a check keeps the last output line'
    Assert-Equal 'BLOCKED-ish plain line' (Get-ShortReason 'BLOCKED-ish plain line') 'plain one-liner unchanged'
    Assert-Equal 'failed without a recorded reason' (Get-ShortReason '') 'empty reason'

    $splitFile = Join-Path $tmp 'SPLIT.md'
    [IO.File]::WriteAllText($splitFile, "## Phase 2 - Data`n`n- [x] 2.2 done`n- [ ] 2.3a spring palettes`n- [ ] 2.3b summer palettes`n- [ ] 2.4 metals", (New-Object Text.UTF8Encoding($false)))
    $sl = Read-TaskList $splitFile
    Assert-Equal '2.3a' (Get-NextTask $sl).Id 'letter-suffixed ids are real tasks'
    Assert-Equal '2.3a 2.3b' ((Get-NextTaskBatch $sl 2 240 @() | ForEach-Object { $_.Id }) -join ' ') 'letter-suffixed ids batch normally'

    # ---------------------------------------------------------- config.ps1
    $base = '{"a":1,"models":{"builder":"sonnet","reviewer":"sonnet"},"gates":[1,2]}' | ConvertFrom-Json
    $over = '{"models":{"builder":"opus"},"gates":[3],"extra":true}' | ConvertFrom-Json
    $m = Merge-Config $base $over
    Assert-Equal 'opus sonnet' "$($m.models.builder) $($m.models.reviewer)" 'deep-merges nested objects'
    Assert-Equal '3' ($m.gates -join ',') 'arrays are replaced, not merged'
    Assert-Equal 'True 1' "$($m.extra) $($m.a)" 'keeps base keys and adds new ones'

    Assert-Equal '02:00:00' (ConvertTo-Duration '2h').ToString() 'duration 2h'
    Assert-Equal '01:30:00' (ConvertTo-Duration '1h30m').ToString() 'duration 1h30m'
    Assert-Equal '01:30:00' (ConvertTo-Duration '90m').ToString() 'duration 90m'
    Assert-Equal '00:45:00' (ConvertTo-Duration '45').ToString() 'bare number = minutes'
    $threw = $false; try { ConvertTo-Duration 'soon' | Out-Null } catch { $threw = $true }
    Assert-Equal $true $threw 'garbage duration throws'

    $cfg = '{"files":{"tasks":"docs/TASKS.md"},"protectedPaths":{"test/arch/":["1.2"]}}' | ConvertFrom-Json
    $pm = Get-ProtectedMap $cfg
    Assert-Equal '.nightshift/ .claude/ CLAUDE.md docs/TASKS.md test/arch/' (($pm.PSObject.Properties | ForEach-Object { $_.Name }) -join ' ') 'engine-owned paths always protected'
    Assert-Equal '1.2' (@($pm.'test/arch/') -join ',') 'project owners preserved'

    $proj = Join-Path $tmp 'proj\sub'
    New-Item -ItemType Directory -Force $proj, (Join-Path $tmp 'proj\.nightshift') | Out-Null
    [IO.File]::WriteAllText((Join-Path $tmp 'proj\.nightshift\config.json'), '{"models":{"builder":"haiku"}}')
    Assert-Equal (Join-Path $tmp 'proj') (Find-ProjectRoot $proj) 'finds project root walking up'
    $rc = Read-ProjectConfig (Join-Path $tmp 'proj')
    Assert-Equal 'proj haiku opus develop' "$($rc.name) $($rc.models.builder) $($rc.models.escalate) $($rc.baseBranch)" 'project config merged over defaults'
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) of $($script:Count) checks FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "All $($script:Count) checks passed" -ForegroundColor Green
exit 0
