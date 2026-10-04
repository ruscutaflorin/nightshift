# Self-tests for the night-shift helpers. No Pester dependency (Windows PowerShell 5.1 ships Pester 3).
# Run: nightshift test   (or: powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1)

$ErrorActionPreference = 'Stop'
$lib = Join-Path (Split-Path $PSScriptRoot -Parent) 'lib'
. (Join-Path $lib 'tasks.ps1')
. (Join-Path $lib 'limits.ps1')
. (Join-Path $lib 'gates.ps1')
. (Join-Path $lib 'config.ps1')
. (Join-Path $lib 'guard.ps1')

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
    Assert-Equal "- [ ] B1 Proposed thing - status: proposed`n  - Why: x" (Get-BacklogItemBlock $backlogFile 'B1') 'backlog block includes indented detail lines'
    Assert-Equal '- [ ] B2 Approved thing - status: approved' (Get-BacklogItemBlock $backlogFile 'B2') 'backlog block stops at the next item'
    Set-TaskStatus $backlogFile 'B2' 'x'
    Assert-Equal $true ([IO.File]::ReadAllText($backlogFile) -match '- \[x\] B2 Approved thing - status: done') 'done backlog item flips status text'

    # Product round guardrails: existing items restored, approvals limited by size and count.
    $productFile = Join-Path $tmp 'BACKLOG-product.md'
    $orig = @('- [ ] B1 Old idea - status: proposed', '  - Size: S')
    [IO.File]::WriteAllText($productFile, ($orig -join "`n"), (New-Object Text.UTF8Encoding($false)))
    $before = Get-BacklogLineMap (Read-TaskList $productFile)
    $agent = @(
        '- [ ] B1 Old idea - status: approved', '  - Size: S',
        '- [ ] B2 Small - status: approved', '  - Why: y', '  - Size: S',
        '- [ ] B3 Large - status: approved', '  - Size: L (split first)',
        '- [ ] B4 Medium - status: approved', '  - Size: M',
        '- [ ] B5 Over the cap - status: approved', '  - Size: S',
        '- [ ] B6 Plain proposal - status: proposed', '  - Size: S'
    )
    [IO.File]::WriteAllText($productFile, ($agent -join "`n"), (New-Object Text.UTF8Encoding($false)))
    $kept = Limit-ProductApprovals $productFile $before $true 2
    Assert-Equal 'B2 B4' ($kept -join ' ') 'auto-approve keeps S/M items up to the cap'
    $status = @{}
    foreach ($t in (Read-TaskList $productFile)) { $status[$t.Id] = $t.Text }
    Assert-Equal 'Old idea - status: proposed' $status['B1'] 'existing item line restored'
    Assert-Equal 'Large - status: proposed' $status['B3'] 'size L demoted to proposed'
    Assert-Equal 'Over the cap - status: proposed' $status['B5'] 'approvals over the cap demoted'
    [IO.File]::WriteAllText($productFile, ($agent -join "`n"), (New-Object Text.UTF8Encoding($false)))
    $kept = Limit-ProductApprovals $productFile $before $false 2
    Assert-Equal '' ($kept -join ' ') 'without auto-approve nothing stays approved'
    Assert-Equal $false ([IO.File]::ReadAllText($productFile) -match 'status: approved') 'every approval demoted when auto-approve is off'

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

    Assert-Equal $true (Test-TestDropAllowed '9.1 [test-audit] Prune server route tests') 'tagged task may drop tests'
    Assert-Equal $true (Test-TestDropAllowed '9.1 [Test-Audit] prune' 1) 'tag is case-insensitive'
    Assert-Equal $false (Test-TestDropAllowed '9.2 Add a rating model') 'untagged task keeps the baseline'
    Assert-Equal $false (Test-TestDropAllowed "These 2 tasks:`n- 9.1 [test-audit] x`n- 9.2 y" 2) 'batches never drop tests'

    $r = Get-ReviewVerdict "Looks fine.`n{`"verdict`":`"approve`",`"issues`":[]}"
    Assert-Equal 'approve' $r.verdict 'reads approve verdict'
    $r = Get-ReviewVerdict "Problems.`n``{`"verdict`":`"changes`",`"issues`":[`"lib/a.dart:3 - bug - fix`"]}``"
    Assert-Equal 'changes' $r.verdict 'reads changes verdict inside backticks'
    Assert-Equal 1 @($r.issues).Count 'keeps issues'
    Assert-Equal '' "$(Get-ReviewVerdict 'no json here')" 'missing verdict -> null'
    Assert-Equal '' "$(Get-ReviewVerdict '{"verdict":"maybe"}')" 'invalid verdict value -> null'

    $o = Get-ResolverOutcome "Looked around.`n{`"diagnosis`":`"old`"}`nThen:`n``{`"diagnosis`":`"stale temp`",`"did`":[`"deleted supabase/.temp`"],`"retry`":true,`"human`":null,`"hint`":`"h`"}``"
    Assert-Equal 'stale temp|1|deleted supabase/.temp|True||h' "$($o.diagnosis)|$(@($o.did).Count)|$($o.did[0])|$($o.retry)|$($o.human)|$($o.hint)" 'reads last resolver outcome inside backticks'
    $o = Get-ResolverOutcome '{"diagnosis":"needs a Stripe key","retry":false,"human":{"ask":"Create a Stripe test account"}}'
    Assert-Equal 'False|Create a Stripe test account|0' "$($o.retry)|$($o.human)|$(@($o.did).Count)" 'resolver outcome: human ask object, defaults'
    Assert-Equal 'Put the key in .env' (Get-ResolverOutcome '{"diagnosis":"x","human":"Put the key in .env"}').human 'resolver outcome: human ask string'
    Assert-Equal '' "$(Get-ResolverOutcome 'no outcome {diagnosis}')" 'missing resolver outcome -> null'
    Assert-Equal 'False' "$((Get-ResolverOutcome '{"diagnosis":"x","retry":"yes"}').retry)" 'retry must be literally true'

    Assert-Equal 7 (Get-PassedTestCount 'Tests:      1 failed, 7 passed, 8 total' 'Tests:\s+(?:\d+ \w+, )*(\d+) passed') 'custom pattern (jest)'
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

    $rules = Get-MatchingSections $batchFile '(?i)\brules\b'
    Assert-Equal "## Rules`n- A.1 not a task" $rules 'rule sections extracted, phases left out'
    Assert-Equal '' (Get-MatchingSections $batchFile '') 'no heading pattern -> empty'
    Assert-Equal '' (Get-MatchingSections (Join-Path $tmp 'missing.md') 'x') 'missing file -> empty'

    $gl = Get-ApplicableGateLines (@(
        '{"name":"test","run":"flutter test","when":{"fileExists":"pubspec.yaml"}}',
        '{"name":"cov","run":"dart run cov.dart","when":{"taskDone":"1.2"}}',
        '{"name":"db","run":"supabase test db","when":{"changed":"supabase/*"}}',
        '{"name":"fmt","run":"dart format ."}'
    ) | ConvertFrom-Json) $tmp $tl
    Assert-Equal "- ``flutter test``|- ``supabase test db`` (only if you change supabase/*)|- ``dart format .``" ($gl -join '|') 'verify list: static conditions filtered, changed becomes a hint'

    Assert-Equal 'The reviewer requested changes: a.json:3 - near-duplicate - replace it' (Get-ShortReason "The reviewer requested changes:`n- a.json:3 - near-duplicate - replace it`n- b.json:1 - x") 'short reason names the first reviewer issue'
    Assert-Equal "Check 'test' failed, exit code 1. -> 00:05 +40 -2: Some tests failed." (Get-ShortReason "Check 'test' failed, exit code 1. Last lines:`n``````n00:01 +3: loading`n00:05 +40 -2: Some tests failed.`n``````") 'short reason for a check keeps the last output line'
    Assert-Equal 'BLOCKED-ish plain line' (Get-ShortReason 'BLOCKED-ish plain line') 'plain one-liner unchanged'
    Assert-Equal 'failed without a recorded reason' (Get-ShortReason '') 'empty reason'

    $splitFile = Join-Path $tmp 'SPLIT.md'
    [IO.File]::WriteAllText($splitFile, "## Phase 2 - Data`n`n- [x] 2.2 done`n- [ ] 2.3a spring palettes`n- [ ] 2.3b summer palettes`n- [ ] 2.4 metals", (New-Object Text.UTF8Encoding($false)))
    $sl = Read-TaskList $splitFile
    Assert-Equal '2.3a' (Get-NextTask $sl).Id 'letter-suffixed ids are real tasks'
    Assert-Equal '2.3a 2.3b' ((Get-NextTaskBatch $sl 2 240 @() | ForEach-Object { $_.Id }) -join ' ') 'letter-suffixed ids batch normally'

    # ---------------------------------------------------------- lanes + overlay
    $laneFile = Join-Path $tmp 'LANES.md'
    $lt = @(
        '## Phase 1 - Base', '',
        '- [x] 1.1 done',
        '- [ ] 1.2 open a',
        '- [ ] 1.3 open b', '',
        '## Phase 2 - Next', '',
        '- [ ] 2.1 open c', '',
        '## Phase 3 - Side work (parallel)', '',
        '- [ ] 3.1 side a',
        '- [ ] 3.2 side b', '',
        '## Phase 4 - After base (after 1)', '',
        '- [ ] 4.1 waits for phase 1'
    ) -join "`n"
    [IO.File]::WriteAllText($laneFile, $lt, (New-Object Text.UTF8Encoding($false)))
    $lTasks = Read-TaskList $laneFile
    $flags = Get-PhaseFlags $laneFile
    Assert-Equal 'False True 1' "$($flags['1'].Parallel) $($flags['3'].Parallel) $(@($flags['4'].After) -join ',')" 'phase flags: (parallel) and (after N)'
    $fmt = { param($b) ($b | ForEach-Object { "$($_.Lane)=$(($_.Tasks | ForEach-Object { $_.Id }) -join '+')" }) -join ' ' }
    Assert-Equal 'tasks=1.2 phase:3=3.1' (& $fmt (Get-TaskLaneBatches $lTasks $flags @() $false 1 240 @())) 'sequential lane + parallel phase; (after 1) waits'
    Assert-Equal 'phase:3=3.1+3.2' (& $fmt (Get-TaskLaneBatches $lTasks $flags @('tasks') $false 2 240 @())) 'busy lane skipped; batching inside a lane'
    Assert-Equal 'phase:1 phase:2 phase:3' ((Get-TaskLaneBatches $lTasks $flags @() $true 1 240 @() | ForEach-Object { $_.Lane }) -join ' ') 'all-parallel: one lane per phase, after-phase still waits'

    $ov = @{ '1.2' = [pscustomobject]@{ state = 'failed'; text = 'open a' }; '1.3' = [pscustomobject]@{ state = 'human'; text = 'changed text' } }
    $merged = Merge-TaskOverlay $lTasks $ov
    Assert-Equal '! ' "$(($merged | Where-Object Id -eq '1.2').Status)$(($merged | Where-Object Id -eq '1.3').Status)" 'overlay applies while text matches; rewritten task drops it'
    $lb = Get-TaskLaneBatches $merged $flags @() $false 1 240 @()
    Assert-Equal 'tasks=2.1' (& $fmt @($lb | Where-Object Lane -eq 'tasks')) 'failed overlay blocks the rest of its phase, next phase proceeds'
    $failedLine = @([pscustomobject]@{ Id = '5.1'; Status = '!'; Text = 'x'; Phase = '5'; Line = 0 })
    Assert-Equal ' ' (Merge-TaskOverlay $failedLine @{ '5.1' = [pscustomobject]@{ state = 'open' } })[0].Status 'open overlay reopens a [!] line'
    $doneLine = @([pscustomobject]@{ Id = '5.2'; Status = 'x'; Text = 't'; Phase = '5'; Line = 0 })
    Assert-Equal 'x' (Merge-TaskOverlay $doneLine @{ '5.2' = [pscustomobject]@{ state = 'failed' } })[0].Status 'done tasks ignore the overlay'
    $bl3 = @(
        [pscustomobject]@{ Id = 'B7'; Status = ' '; Text = 'a - status: approved' },
        [pscustomobject]@{ Id = 'B8'; Status = ' '; Text = 'b - status: approved' },
        [pscustomobject]@{ Id = 'B9'; Status = ' '; Text = 'c - status: proposed' })
    Assert-Equal 'B8' ((Get-BacklogLaneItems $bl3 @('backlog:B7') | ForEach-Object { $_.Id }) -join ' ') 'backlog lanes: approved, not busy'

    $pp = Get-PhasePlan "thinking`n{`"phases`":{`"2`":{`"after`":[`"1`"]},`"3`":{`"after`":[]},`"x`":{},`"4`":{`"after`":[`"4`",`"oops`"]}}}"
    Assert-Equal '1||' "$(@($pp['2']) -join ',')|$(@($pp['3']) -join ',')|$(@($pp['4']) -join ',')" 'phase plan parsed; self and junk deps dropped'
    Assert-Equal '' "$(Get-PhasePlan 'no plan')" 'missing phase plan -> null'
    Assert-Equal '1 2 3 4' ((Get-OpenPhaseIds $lTasks) -join ' ') 'open phases in file order'
    $mf = Merge-PhasePlan $flags @{ '1' = @(); '2' = @('1'); '3' = @('1'); '4' = @() }
    Assert-Equal 'True|False 1|True|1' "$($mf['1'].Parallel)|$($mf['2'].Parallel) $(@($mf['2'].After) -join ',')|$($mf['3'].Parallel)|$(@($mf['4'].After) -join ',')" 'planner fills lanes; heading flags win'
    $lb = Get-TaskLaneBatches $lTasks $mf @() $false 1 240 @()
    Assert-Equal 'phase:1=1.2 phase:3=3.1' (& $fmt $lb) 'planned lanes: independent phases run, dependent ones wait'

    # ---------------------------------------------------------- active hours + limit resume
    Assert-Equal $true (Test-InActiveHours @() ([datetime]'2026-10-01 13:00')) 'no windows = always active'
    Assert-Equal $true (Test-InActiveHours @('22:00-07:00') ([datetime]'2026-10-01 02:00')) 'window across midnight'
    Assert-Equal $false (Test-InActiveHours @('22:00-07:00') ([datetime]'2026-10-01 12:00')) 'outside window'
    Assert-Equal $true (Test-InActiveHours @('09:00-12:00', '13:00-18:00') ([datetime]'2026-10-01 14:00')) 'second window'
    Assert-Equal ([datetime]'2026-10-01 22:00') (Get-NextActiveStart @('22:00-07:00') ([datetime]'2026-10-01 12:00')) 'next window start today'
    Assert-Equal ([datetime]'2026-10-02 09:00') (Get-NextActiveStart @('09:00-12:00') ([datetime]'2026-10-01 12:30')) 'next window start tomorrow'
    $threw = $false; try { Test-InActiveHours @('soon') (Get-Date) | Out-Null } catch { $threw = $true }
    Assert-Equal $true $threw 'bad window throws'
    $noon = [datetime]'2026-10-01 12:00'
    $d = Get-LimitDecision ([datetime]'2026-10-01 15:00') ([datetime]::MaxValue) $noon 30 ''
    Assert-Equal 'sleep 2026-10-01 15:02 False' "$($d.Action) $($d.Until.ToString('yyyy-MM-dd HH:mm')) $($d.Probe)" 'no deadline: sleep until the reset'
    $d = Get-LimitDecision ([datetime]'2026-10-01 15:00') ([datetime]::MaxValue) $noon 30 '22:00'
    Assert-Equal '2026-10-01 22:00' $d.Until.ToString('yyyy-MM-dd HH:mm') 'resumeAt: wake at the chosen hour after the reset'
    $d = Get-LimitDecision ([datetime]'2026-10-01 23:00') ([datetime]::MaxValue) $noon 30 '22:00'
    Assert-Equal '2026-10-02 22:00' $d.Until.ToString('yyyy-MM-dd HH:mm') 'resumeAt before the reset rolls to the next day'
    $d = Get-LimitDecision $null ([datetime]::MaxValue) $noon 30 ''
    Assert-Equal '12:30 True' "$($d.Until.ToString('HH:mm')) $($d.Probe)" 'unknown reset: fallback sleep, then probe'

    # ---------------------------------------------------------- guard.ps1
    $repoRoot = Join-Path $tmp 'repo'
    $wtRoot = Join-Path $tmp 'repo.nightshift'
    $roots = @($repoRoot, $wtRoot)
    $cwd = Join-Path $wtRoot 'resolver'
    $branches = @('main', 'master', 'develop')
    $cmdRd = 'rd ' + '/s /q '
    $blocked = @(
        'git push --force origin ns/x', 'git push -f', 'git push origin +HEAD:develop', 'git push origin main', 'git push origin HEAD:main',
        'git push origin --delete develop', 'git reset --hard HEAD~3', 'git filter-branch --all', 'git branch -D develop', 'git update-ref refs/heads/main abc',
        'git worktree remove ../w1', 'gh repo delete me/x --yes', 'gh secret set X', 'gh api -X DELETE repos/me/x',
        'rm -rf /c/Users', 'rm -rf ~', 'rm -rf ../../outside', 'Remove-Item -Recurse -Force C:\Windows\Temp\x', ($cmdRd + 'D:\other'),
        'cat ~/.ssh/id_rsa', 'type %USERPROFILE%\.claude.json', 'shutdown /s /t 0', 'format d: /q', 'npm test && git push --force'
    )
    foreach ($c in $blocked) {
        Assert-Equal $true ([bool](Get-GuardVerdict 'Bash' ([pscustomobject]@{ command = $c }) $cwd $roots $branches)) "guard blocks: $c"
    }
    $allowed = @(
        'git push -u origin ns/1.2-20261001-1200', 'git commit -m "fix main menu"', 'git push origin feature/main-menu', 'npm install -g pnpm',
        'docker run -d --name pg -p 5432:5432 postgres:16', 'rm -rf supabase/.temp', 'rm -rf node_modules', "Remove-Item -Recurse -Force $cwd\build",
        ($cmdRd + 'build'), 'dart format .', 'winget install --id Git.Git -e', 'git branch -D ns/old-branch', 'rm -rf *'
    )
    foreach ($c in $allowed) {
        Assert-Equal '' (Get-GuardVerdict 'Bash' ([pscustomobject]@{ command = $c }) $cwd $roots $branches) "guard allows: $c"
    }
    Assert-Equal $true ([bool](Get-GuardVerdict 'Edit' ([pscustomobject]@{ file_path = "$env:USERPROFILE\.claude\settings.json" }) $cwd $roots $branches)) 'guard blocks editing user settings'
    Assert-Equal $true ([bool](Get-GuardVerdict 'Read' ([pscustomobject]@{ file_path = "$env:USERPROFILE\.ssh\id_ed25519" }) $cwd $roots $branches)) 'guard blocks reading keys'
    Assert-Equal '' (Get-GuardVerdict 'Edit' ([pscustomobject]@{ file_path = "$cwd\CLAUDE.md" }) $cwd $roots $branches) 'guard allows editing CLAUDE.md in its worktree'
    Assert-Equal '' (Get-GuardVerdict 'Write' ([pscustomobject]@{ file_path = "$repoRoot\.claude\settings.json" }) $cwd $roots $branches) 'guard allows editing the project settings'
    Assert-Equal '' (Get-GuardVerdict 'Read' ([pscustomobject]@{ file_path = 'C:\Program Files\x\readme.txt' }) $cwd $roots $branches) 'guard allows reading elsewhere'

    # ---------------------------------------------------------- settings
    $projSettings = '{"permissions":{"allow":["Bash(flutter:*)"],"deny":["Bash(rm -rf:*)"]}}' | ConvertFrom-Json
    $as = New-AgentSettings $projSettings 'docs/TASKS.md'
    Assert-Equal 'True True True True' "$($as.permissions.allow -contains 'Bash(flutter:*)') $($as.permissions.deny -contains 'Bash(rm -rf:*)') $($as.permissions.deny -contains 'Bash(git push:*)') $($as.permissions.deny -contains 'Edit(docs/TASKS.md)')" 'agent settings: project policy + engine denies + tasks file'
    $old = '{"permissions":{"allow":["Read","Bash(flutter:*)"],"deny":["Edit(.nightshift/**)","Edit(CLAUDE.md)","PowerShell","Bash(git push:*)","Bash(custom-thing:*)"]},"env":{"X":"1"}}' | ConvertFrom-Json
    $hs = ConvertTo-HumanSettings $old @('Bash(git push:*)') @('Bash(dart:*)')
    Assert-Equal 'Bash(custom-thing:*)' (@($hs.permissions.deny | Where-Object { $script:HumanDeny -notcontains $_ }) -join ',') 'human settings: agent-only denies removed, own denies kept'
    Assert-Equal 'True True True acceptEdits 1' "$($hs.permissions.allow -contains 'PowerShell') $($hs.permissions.allow -contains 'Bash(dart:*)') $($hs.permissions.allow -contains 'Bash(flutter:*)') $($hs.permissions.defaultMode) $($hs.env.X)" 'human settings: allowlist added, rest kept'
    Assert-Equal 'True' "$($old.permissions.deny -contains 'PowerShell')" 'human settings conversion leaves its input alone'
    $rs = New-ResolverSettings 'powershell -File guard.ps1'
    Assert-Equal 'True powershell -File guard.ps1' "$($rs.permissions.deny -contains 'Bash(git push --force:*)') $($rs.hooks.PreToolUse[0].hooks[0].command)" 'resolver settings: denies + guard hook'

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
    Assert-Equal 'proj haiku opus develop 2 opus' "$($rc.name) $($rc.models.builder) $($rc.models.escalate) $($rc.baseBranch) $($rc.workers) $($rc.models.resolver)" 'project config merged over defaults'
    [IO.File]::WriteAllText((Join-Path $tmp 'proj\.nightshift\config.json'), '{"maxProposalsPerNight":2,"unblock":{"enabled":false}}')
    $rc = Read-ProjectConfig (Join-Path $tmp 'proj')
    Assert-Equal '2 False' "$($rc.product.maxProposals) $($rc.resolver.enabled)" 'old config keys still honored'
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
