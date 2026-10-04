# One job in one worktree slot, run by the daemon as its own process:
#   lib\cli.ps1 worker -Project <checkout> -Slot w1
# It reads state/jobs/<slot>.json, writes state/results/<slot>.json and exits. Workers never merge
# and never edit the tasks file: the daemon integrates their branches one at a time.
#
# Kinds: task / backlog / polish  builder -> checks -> reviewer -> fixer (up to maxAttempts)
#        product                  backlog proposals (approvals limited by the supervisor)
#        resolve / maintain / health   the resolver (permission checks bypassed, guard hook on)
#        merge                    bring a finished branch that conflicts with the newer base up to date
#        plan                     read-only: which phases of the tasks file can run in parallel

$script:ResolverKinds = @('resolve', 'maintain', 'health')

function Write-SlotStatus([string]$Step) {
    if (-not $script:Job) { return }
    Write-JsonFile (Join-Path $script:SlotsDir "$($script:SlotName).json") ([pscustomobject]@{
            slot = $script:SlotName; pid = $PID; kind = $script:Job.Kind; id = $script:Job.Id; text = $script:Job.Text
            step = $Step; since = $script:JobStarted.ToString('s'); updated = (Get-Date).ToString('s')
        })
}

# ---------------------------------------------------------------- worktree slots

# Manifests / lockfiles: when they change, a slot's dependencies are installed again.
$script:SetupSignatureFiles = @('package.json', 'package-lock.json', 'pnpm-lock.yaml', 'yarn.lock', 'pubspec.yaml', 'pubspec.lock',
    'requirements.txt', 'pyproject.toml', 'poetry.lock', 'uv.lock', 'Gemfile.lock', 'go.sum', 'Cargo.lock')

function Get-SetupSignature([string[]]$Commands) {
    $specs = ($script:SetupSignatureFiles | ForEach-Object { "`":(glob)**/$_`"" }) -join ' '
    $blobs = @(Invoke-Git "ls-files -s -- $specs" -AllowFail | ForEach-Object { ($_ -split '\s+')[1] })
    $text = ($blobs -join ',') + '|' + ($Commands -join '|')
    $sha = [Security.Cryptography.SHA1]::Create()
    return ([BitConverter]::ToString($sha.ComputeHash($script:Utf8.GetBytes($text))) -replace '-', '')
}

# Files git doesn't track that a worktree still needs (config worktree.copy: .env, local.properties ...).
function Copy-SlotFiles([string]$Path) {
    foreach ($rel in @($script:Config.worktree.copy | Where-Object { $_ })) {
        $src = Join-Path $script:ProjectHome $rel
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $dst = Join-Path $Path $rel
        if ((Test-Path -LiteralPath $dst) -and (Get-Item -LiteralPath $dst).LastWriteTime -ge (Get-Item -LiteralPath $src).LastWriteTime) { continue }
        New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
        if ((Get-Item -LiteralPath $src).PSIsContainer) {
            New-Item -ItemType Directory -Force $dst | Out-Null
            Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force
        } else { Copy-Item -LiteralPath $src -Destination $dst -Force }
    }
}

# config worktree.setup, run in the slot when it is created and again whenever a manifest or
# lockfile changed: every worktree gets its own install, never one shared with another tree.
function Invoke-SlotSetup([string]$Slot) {
    $cmds = @($script:Config.worktree.setup | Where-Object { $_ })
    if (-not $cmds) { return }
    $sig = Get-SetupSignature $cmds
    $marker = Join-Path $script:SlotsDir "$Slot.setup"
    if ((Test-Path $marker) -and ([IO.File]::ReadAllText($marker) -eq $sig)) { return }
    foreach ($c in $cmds) {
        $log = Join-Path $script:SessionsDir "$(Get-Stamp)-$Slot-setup.log"
        Write-Log "setup: $c"
        $code = Invoke-Logged $c $log $null $null ([int]$script:Config.gateTimeoutMinutes)
        if ($code -ne 0) { Write-Log "setup '$c' failed (exit $code, see $log); retrying next time"; return }
    }
    [IO.File]::WriteAllText($marker, $sig, $script:Utf8)
}

# The slot's worktree exists, is clean and detached at $Ref, with its copied files and installs.
# Leftovers from a killed process are kept as a WIP commit on their branch (resumable), else dropped.
function Initialize-Slot([string]$Slot, [string]$Ref) {
    $path = Get-SlotPath $Slot
    if (-not (Test-Path (Join-Path $path '.git'))) {
        New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
        Invoke-Git 'worktree prune' -AllowFail -Dir $script:ProjectHome | Out-Null
        if (Test-Path $path) { Remove-Item -LiteralPath $path -Recurse -Force }
        Write-Log "creating worktree $path"
        Invoke-Git "worktree add -q --detach `"$path`" $Ref" -Dir $script:ProjectHome | Out-Null
    }
    Set-WorkDir $path
    if (Get-GitSha 'MERGE_HEAD') { Invoke-Git 'merge --abort' -AllowFail | Out-Null }
    if (Test-TreeDirty) {
        if (Get-CurrentBranch) { New-Commit 'wip: state left by an interrupted session' | Out-Null }
        else { Invoke-Git 'reset -q --hard' | Out-Null; Invoke-Git 'clean -fdq' | Out-Null }
    }
    Invoke-Git "switch -q --detach $Ref" | Out-Null
    Copy-SlotFiles $path
    Invoke-SlotSetup $Slot
}

# ---------------------------------------------------------------- branches

# Failed work is parked under <prefix>-failed/ so it is kept for inspection but never resumed;
# a branch with no commits of its own is just noise and is deleted. Returns the kept name or ''.
function Save-FailedBranch([string]$Branch) {
    if (-not $Branch -or -not (Get-GitSha $Branch)) { return '' }
    if ((Get-AheadCount $script:BaseRef $Branch) -eq 0) {
        Invoke-Git "branch -q -D $Branch" -AllowFail | Out-Null
        return ''
    }
    $prefix = $script:Config.branchPrefix
    $name = if ($Branch.StartsWith($prefix)) { $Branch.Substring($prefix.Length) } else { $Branch }
    $failed = $prefix.TrimEnd('/') + '-failed/' + $name
    Invoke-Git "branch -q -M $Branch $failed" -AllowFail | Out-Null
    if ($script:GitExit -ne 0) { return $Branch }
    return $failed
}

# The newest unfinished branch for exactly this item (left by a stop, crash, sleep or a failed integration).
function Find-ResumableBranch([string]$Safe) {
    $pattern = '^' + [regex]::Escape("$($script:Config.branchPrefix)$Safe-") + '\d{8}-\d{4}$'
    $names = @(Invoke-Git 'branch --list --format=%(refname:short)' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match $pattern } | Sort-Object -Descending)
    foreach ($b in $names) {
        if ((Get-AheadCount $script:BaseRef $b) -gt 0) { return $b }
    }
    return $null
}

# Puts protected paths the item doesn't own back the way they were where the branch started.
function Restore-ProtectedPaths([string[]]$Paths) {
    $mb = ((Invoke-Git "merge-base $($script:BaseRef) HEAD") -join '').Trim()
    foreach ($p in $Paths) {
        if (Test-Git "cat-file -e `"$($mb):$p`"") { Invoke-Git "checkout -q $mb -- `"$p`"" | Out-Null }
        else { Invoke-Git "rm -q -f --ignore-unmatch -- `"$p`"" | Out-Null }
    }
    New-Commit "chore: restore protected paths ($($Paths -join ', '))" | Out-Null
}

# ---------------------------------------------------------------- the worker process

function New-JobResult($Job) {
    return [pscustomobject]@{
        kind = $Job.Kind; id = $Job.Id; ids = @($Job.Ids); lane = $Job.Lane; text = $Job.Text; outcome = 'crashed'
        branch = ''; reason = ''; gate = ''; summary = ''; testCount = $null; attempt = 0; reviewNotes = @()
        polishDone = ''; polishExhausted = $false; approved = @(); resolution = $null; request = $Job.Request
    }
}

function Invoke-WorkerProcess([string]$Slot) {
    $script:SlotName = $Slot
    $script:LogTag = "[$Slot] "
    $script:Job = Read-JsonFile (Join-Path $script:JobsDir "$Slot.json")
    if (-not $script:Job) { throw "no job for slot $Slot" }
    $job = $script:Job
    $script:JobStarted = Get-Date
    $script:Deadline = if ($job.Deadline) { [datetime]$job.Deadline } else { [datetime]::MaxValue }
    $script:BaseRef = $job.BaseRef
    $result = New-JobResult $job
    try {
        Write-SlotStatus 'preparing worktree'
        Initialize-Slot $Slot $job.BaseRef
        Import-ProjectConfig $script:Repo
        Set-WorkDir $script:Repo
        $out = if ($job.Kind -eq 'product') { Invoke-ProductJob $job }
        elseif ($script:ResolverKinds -contains $job.Kind) { Invoke-ResolverJob $job }
        elseif ($job.Kind -eq 'merge') { Invoke-MergeJob $job }
        elseif ($job.Kind -eq 'plan') { Invoke-PlanJob $job }
        else { Invoke-WorkItem $job }
        foreach ($p in $out.PSObject.Properties) { $result | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force }
    } catch {
        $msg = $_.Exception.Message
        if ($msg -like 'STOP_NIGHT:*') { $result.outcome = 'stopped'; $result.reason = $msg.Substring(12).Trim() }
        else {
            $result.outcome = 'crashed'; $result.reason = $msg
            Write-Log "CRASH: $msg`n$($_.ScriptStackTrace)"
        }
    } finally {
        try {
            $b = Get-CurrentBranch
            if ($b) {
                if (Test-TreeDirty) { New-Commit "wip($($job.Id)): state at exit" | Out-Null }
                if (-not $result.branch) { $result.branch = $b }
                Invoke-Git 'switch -q --detach' -AllowFail | Out-Null   # frees the branch for the integrator
            }
        } catch { Write-Log "cleanup failed: $($_.Exception.Message)" }
        foreach ($l in @($script:HeldLocks.Keys)) { Exit-NamedLock $l }
        Write-JsonFile (Join-Path $script:ResultsDir "$Slot.json") $result
        Remove-Item (Join-Path $script:SlotsDir "$Slot.json") -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------- build -> checks -> review -> fix

function Invoke-WorkItem($Item) {
    $safe = Get-SafeId $Item.Id
    # Resume unfinished work for this exact item instead of rebuilding it: bring it up to date
    # with the base, then go straight to the checks + review. Conflicts -> start fresh.
    $resumed = $false
    $branch = if ($Item.Kind -in @('task', 'backlog')) { Find-ResumableBranch $safe } else { $null }
    if ($branch) {
        Invoke-Git "switch -q $branch" | Out-Null
        if (Test-Git "merge -q --no-edit --no-verify $($script:BaseRef)") {
            $resumed = $true
            Write-Log "resuming $branch (re-checking its existing work)"
            Add-Report "- [resume] $($Item.Id) from ``$branch``"
        } else {
            Invoke-Git 'merge --abort' -AllowFail | Out-Null
            Invoke-Git "switch -q --detach $($script:BaseRef)" | Out-Null
            Write-Log "cannot resume $branch (conflicts with $($script:BaseRef)); starting fresh"
            Save-FailedBranch $branch | Out-Null
            $branch = $null
        }
    }
    if (-not $branch) {
        $branch = "$($script:Config.branchPrefix)$safe-$(Get-Date -Format 'yyyyMMdd-HHmm')"
        Invoke-Git "switch -q -C $branch $($script:BaseRef)" | Out-Null
    }
    Write-Log "=== $($Item.Kind) $($Item.Id): $($Item.Text) on $branch"
    Initialize-ServicesForItem $Item

    $taskText = $Item.TaskText
    # What the resolver cleared since an earlier attempt, so the builder doesn't hit it again.
    $hints = Read-StateMap 'unblock-hints.json'
    $itemHints = @($Item.Ids | Where-Object { $hints[$_] } | ForEach-Object { "- $_`: $($hints[$_])" })
    if ($itemHints) { $taskText += "`n`nNote from the supervisor:`n$($itemHints -join "`n")" }
    $protectedText = Get-ProtectedText $Item
    # Only the task's own phase of the tasks file, so agents don't re-read the whole plan every session.
    # A backlog item gets its full block (Why / Scope / Acceptance), not just the title line.
    $phase = switch ($Item.Kind) {
        'task' { Get-PhaseSection $script:TasksPath $Item.Phase }
        'backlog' { Get-BacklogItemBlock $script:BacklogPath $Item.Id }
        default { '' }
    }
    if (-not $phase) { $phase = '(not applicable)' }
    $feedback = $null
    $lastGate = ''
    $polishDone = 'nothing yet'
    if ($Item.Kind -eq 'polish' -and $Item.Done) { $polishDone = $Item.Done }
    for ($attempt = 1; $attempt -le $script:Config.maxAttempts; $attempt++) {
        # The escalate model is a last resort: the builder model gets `escalateAfter` tries (fixes included) first.
        $model = if ($attempt -le [int]$script:Config.escalateAfter) { $script:Config.models.builder } else { $script:Config.models.escalate }
        if ($attempt -eq 1 -and $Item.Kind -eq 'polish') {
            $prompt = Expand-Template 'polish' @{ DONE_TONIGHT = $polishDone; PROTECTED = $protectedText }
        } elseif ($attempt -eq 1) {
            $prompt = Expand-Template 'builder' @{ TASK = $taskText; PROTECTED = $protectedText; PHASE_CONTEXT = $phase }
        } else {
            $prompt = Expand-Template 'fixer' @{ TASK = $taskText; FEEDBACK = $feedback; PROTECTED = $protectedText; PHASE_CONTEXT = $phase }
        }

        $role = if ($attempt -eq 1) { "build-$safe" } else { "fix-$safe" }
        if ($resumed -and $attempt -eq 1) {
            $r = [pscustomobject]@{ Result = ''; TimedOut = $false; OverBudget = $false }   # existing work: straight to the checks
        } else {
            Write-SlotStatus $(if ($attempt -eq 1) { 'build' } else { "fix (attempt $attempt)" })
            $r = Invoke-AgentSafely -Role $role -Prompt $prompt -Model $model
        }

        if ($r.Result -match '(?m)^\s*BLOCKED:\s*(.+)$') {
            return [pscustomobject]@{ outcome = 'blocked'; branch = $branch; reason = $Matches[1].Trim(); attempt = $attempt; polishExhausted = ($Item.Kind -eq 'polish') }
        }
        $feedback = $null
        if ($r.TimedOut) {
            $feedback = "The previous session timed out after $($script:Config.agentTimeoutMinutes) minutes. Finish the remaining work with the smallest change that satisfies the task."
        } elseif ($r.OverBudget) {
            $feedback = 'The previous session hit its token budget before finishing. Finish the remaining work with the smallest change that satisfies the task; read only what you need.'
        }
        if (Test-TreeDirty) { New-Commit "chore($($Item.Id)): uncommitted agent changes" | Out-Null }

        if ((Get-AheadCount $script:BaseRef) -eq 0) {
            if (-not $feedback) { $feedback = 'No changes were committed. Implement the task and commit it.' }
            continue
        }

        $changed = @(Invoke-Git "diff --name-only $($script:BaseRef)...HEAD" | Where-Object { $_.Trim() })
        $violations = Get-ProtectedPathViolations $changed $script:Protected $Item.Ids
        $restoredNote = ''
        if ($violations.Count -gt 0) {
            Restore-ProtectedPaths $violations
            Write-Log "restored protected paths: $($violations -join ', ')"
            $restoredNote = "The supervisor reverted your changes to protected paths you don't own: $($violations -join ', '). If the task can't be done without changing them, end with ``BLOCKED: needs <path> changed: <why>``."
            if ((Get-AheadCount $script:BaseRef) -eq 0 -or -not (Invoke-Git "diff --name-only $($script:BaseRef)...HEAD" | Where-Object { $_.Trim() })) {
                $feedback = $restoredNote
                continue
            }
            $changed = @(Invoke-Git "diff --name-only $($script:BaseRef)...HEAD" | Where-Object { $_.Trim() })
        }

        Write-SlotStatus 'checks'
        $gates = Invoke-Gates $safe $changed -AllowTestDrop:(Test-TestDropAllowed $Item.TaskText @($Item.Ids).Count)
        if (-not $gates.Pass) {
            $feedback = (@($gates.Feedback, $restoredNote) | Where-Object { $_ }) -join "`n`n"
            $lastGate = $gates.Gate
            continue
        }

        Write-SlotStatus 'review'
        $review = Invoke-Review $Item
        if ($review.verdict -ne 'approve') {
            $feedback = "The reviewer requested changes:`n- " + (@($review.issues) -join "`n- ")
            $lastGate = ''
            continue
        }

        $done = if ($Item.Kind -eq 'polish') { (@($r.Result -split "`n" | Where-Object { $_ -match '^DONE:' }) | Select-Object -Last 1) } else { '' }
        return [pscustomobject]@{
            outcome = 'ready'; branch = $branch; attempt = $attempt; summary = $gates.Summary; testCount = $gates.TestCount
            reviewNotes = @($review.issues); polishDone = [string]$done
        }
    }
    return [pscustomobject]@{ outcome = 'failed'; branch = $branch; reason = $feedback; gate = $lastGate; attempt = $script:Config.maxAttempts; polishExhausted = ($Item.Kind -eq 'polish') }
}

# ---------------------------------------------------------------- product

# Text for the product prompt's {{APPROVAL}} / {{FOCUS}} placeholders.
function Get-ProductApprovalText {
    $p = $script:Config.product
    if (-not $p.autoApprove) {
        return 'Mark every proposal `status: proposed`. The human approves them; the supervisor turns any `approved` you write back into `proposed`.'
    }
    return @"
You may mark up to $($p.maxAutoApprovePerRound) of your new proposals ``status: approved``: they are built right away by the normal builder -> checks -> reviewer pipeline, with no human in between. Approve only a proposal that:
- is Size S or M, and small enough for one builder session (split bigger ideas into several items);
- can be built and verified headlessly **with what exists today**: no accounts, payments, legal / store decisions, paid APIs, device-only checks, services that aren't configured, and no "TBD" in Acceptance;
- fits the plan file and touches nothing it marks out of scope, and no protected path;
- can be fully verified by the automated checks (name the tests in Acceptance).
Everything else gets ``status: proposed``. Put approved items first, most valuable first; they are built in file order. The builder sees only that item's block, so write Scope and Acceptance to stand alone: name the files, the existing code to reuse, and the tests. The supervisor enforces the size and count limits and restores any change to existing items.
"@
}

function Get-ProductFocusText {
    $focus = @($script:Config.product.focus | Where-Object { $_ })
    if (-not $focus) { return '(no preference: use your judgment)' }
    return (($focus | ForEach-Object { "- $_" }) -join "`n")
}

function Get-RecentReportText {
    $report = Get-ChildItem $script:ReportsDir -Filter *.md -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
    if (-not $report) { return '(no runs yet)' }
    return ((Get-Content $report.FullName -Tail 50 -Encoding UTF8) -join "`n")
}

function Invoke-ProductJob($Job) {
    $p = $script:Config.product
    $backlogRel = $script:Config.files.backlog -replace '\\', '/'
    $branch = "$($script:Config.branchPrefix)product-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Invoke-Git "switch -q -C $branch $($script:BaseRef)" | Out-Null
    $backlog = if (Test-Path $script:BacklogPath) { Read-TaskList $script:BacklogPath } else { @() }
    $before = Get-BacklogLineMap $backlog
    $nextId = Get-NextBacklogId $backlog
    $prompt = Expand-Template 'product' @{
        MAX = $p.maxProposals; NEXT_ID = $nextId; APPROVAL = Get-ProductApprovalText; FOCUS = Get-ProductFocusText
        RECENT_REPORT = Get-RecentReportText; QUEUE = $(if ($Job.State) { $Job.State } else { '(nothing failed or waiting)' })
    }
    Write-SlotStatus 'product'
    Invoke-AgentSafely -Role 'product' -Prompt $prompt -Model $script:Config.models.product | Out-Null
    if (Test-TreeDirty) { New-Commit 'docs(backlog): proposals' | Out-Null }
    $changed = @(Invoke-Git "diff --name-only $($script:BaseRef)...HEAD" | Where-Object { $_.Trim() })
    $bad = @($changed | Where-Object { $_ -ne $backlogRel })
    if ($changed.Count -eq 0) { return [pscustomobject]@{ outcome = 'failed'; branch = $branch; reason = 'no proposals written' } }
    if ($bad.Count -gt 0) { return [pscustomobject]@{ outcome = 'failed'; branch = $branch; reason = "changed files other than $($backlogRel): $($bad -join ', ')" } }
    # Don't trust the agent: restore existing items, enforce the approval limits.
    $approved = Limit-ProductApprovals $script:BacklogPath $before ([bool]$p.autoApprove) ([int]$p.maxAutoApprovePerRound)
    if (Test-TreeDirty) { New-Commit 'chore(backlog): enforce product approval limits' @($backlogRel) | Out-Null }
    $after = @{}
    foreach ($t in (Read-TaskList $script:BacklogPath)) { $after[$t.Id] = $true }
    $missing = @($before.Keys | Where-Object { -not $after.ContainsKey($_) })
    if ($missing) { return [pscustomobject]@{ outcome = 'failed'; branch = $branch; reason = "removed existing items: $($missing -join ', ')" } }
    return [pscustomobject]@{ outcome = 'ready'; branch = $branch; approved = $approved; summary = "new proposals from $nextId" }
}

# ---------------------------------------------------------------- resolver

# Branch tips the resolver must never rewrite: main/master/base locally and on origin, plus the
# local integration branch.
function Get-GuardedRefTips {
    $refs = @('main', 'master', $script:Base, "$($script:Config.branchPrefix)integration", 'origin/main', 'origin/master', "origin/$($script:Base)")
    $tips = @{}
    foreach ($r in ($refs | Select-Object -Unique)) { $sha = Get-GitSha $r; if ($sha) { $tips[$r] = $sha } }
    return $tips
}

# '' if every guarded ref only moved forward; otherwise restores local refs and says what happened.
function Test-GuardedRefTips([hashtable]$Before) {
    if (@($Before.Keys | Where-Object { $_ -like 'origin/*' }).Count) { Invoke-Git 'fetch -q origin' -AllowFail | Out-Null }
    $problems = @()
    foreach ($ref in $Before.Keys) {
        $now = Get-GitSha $ref
        if (-not $now) { $problems += "$ref was deleted"; continue }
        if ($now -eq $Before[$ref] -or (Test-GitAncestor $Before[$ref] $now)) { continue }
        $problems += "$ref was rewritten ($($Before[$ref].Substring(0, 8)) -> $($now.Substring(0, 8)))"
        if ($ref -notlike 'origin/*') { Invoke-Git "update-ref refs/heads/$ref $($Before[$ref])" -AllowFail | Out-Null }
    }
    return ($problems -join '; ')
}

function Get-ResolverModeText($Job) {
    switch ($Job.Kind) {
        'resolve' { return "A work item failed or was blocked. Make it buildable, then say whether to retry it." }
        'maintain' { return "The project owner asked for something. Do it, the way they would in an interactive session." }
        'health' { return "The pipeline itself looks unhealthy. Find out why and fix it." }
    }
}

function Invoke-ResolverJob($Job) {
    $safe = Get-SafeId $Job.Id
    $branch = "$($script:Config.branchPrefix)resolve-$safe-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Invoke-Git "switch -q -C $branch $($script:BaseRef)" | Out-Null
    $tips = Get-GuardedRefTips
    $itemSafe = if ($Job.ItemId) { Get-SafeId $Job.ItemId } else { $safe }
    $policy = New-AgentSettings (Read-JsonFile (Join-Path $script:Repo '.nightshift\agent-settings.json')) $script:Config.files.tasks
    $values = @{
        MODE           = Get-ResolverModeText $Job
        TASK           = $(if ($Job.TaskText) { $Job.TaskText } else { '(none)' })
        REASON         = $(if ($Job.Reason) { $Job.Reason } else { '(none)' })
        REQUEST        = $(if ($Job.Request) { $Job.Request } else { '(none)' })
        SESSION_TAIL   = $(if ($Job.Kind -eq 'resolve') { Get-LastSessionTail $itemSafe } else { '(not applicable)' })
        BRANCH         = $branch
        CHECKOUT       = $script:ProjectHome
        WORKTREES      = Get-WorktreeRoot
        QUEUE          = $(if ($Job.State) { $Job.State } else { '(nothing failed or waiting)' })
        AGENT_DENY     = ((@($policy.permissions.deny) | ForEach-Object { "``$_``" }) -join ', ')
        INTEGRATION    = $(if ($Job.PrMode) { "one pull request per item into ``$($script:Base)``, merged automatically" } else { "a local merge into ``$($script:BaseRef)`` (no GitHub remote)" })
    }
    $prompt = Expand-Template 'resolver' $values
    Write-SlotStatus "resolver ($($Job.Kind))"
    $r = Invoke-AgentSafely -Role "resolve-$safe" -Prompt $prompt -Model $script:Config.models.resolver -Policy 'resolver' -IgnoreDeadline
    $outcome = Get-ResolverOutcome $r.Result
    $fixed = $false
    for ($round = 1; $round -le 2; $round++) {
        $violation = Test-GuardedRefTips $tips
        if ($violation) { return [pscustomobject]@{ outcome = 'violation'; branch = ''; reason = $violation; resolution = $outcome } }
        if ((Get-CurrentBranch) -ne $branch) {
            if (Test-TreeDirty) { New-Commit "chore(resolve): $($Job.Id)" | Out-Null }
            Invoke-Git "switch -q $branch" -AllowFail | Out-Null
        }
        if (Test-TreeDirty) { New-Commit "chore(resolve): $($Job.Id)" | Out-Null }
        if ((Get-AheadCount $script:BaseRef) -eq 0) {
            return [pscustomobject]@{ outcome = 'done'; branch = $branch; resolution = $outcome }
        }
        $changed = @(Invoke-Git "diff --name-only $($script:BaseRef)...HEAD" | Where-Object { $_.Trim() })
        Write-SlotStatus 'checks'
        $gates = Invoke-Gates "resolve-$safe" $changed
        if ($gates.Pass) {
            return [pscustomobject]@{ outcome = 'ready'; branch = $branch; summary = $gates.Summary; testCount = $gates.TestCount; resolution = $outcome }
        }
        if ($round -eq 2) { break }
        # One chance to repair its own change before it is thrown away.
        $fixPrompt = "$prompt`n`n## Your previous attempt broke a check`n`nYou committed changes on ``$branch`` and this check now fails:`n`n$($gates.Feedback)`n`nFix it, or revert the part of your change that broke it. Commit, then end with the outcome JSON line again."
        $r = Invoke-AgentSafely -Role "resolve-$safe-fix" -Prompt $fixPrompt -Model $script:Config.models.resolver -Policy 'resolver' -IgnoreDeadline
        $o2 = Get-ResolverOutcome $r.Result
        if ($o2) { $outcome = $o2 }
    }
    return [pscustomobject]@{ outcome = 'failed'; branch = $branch; reason = $gates.Feedback; gate = $gates.Gate; resolution = $outcome }
}

# ---------------------------------------------------------------- merge (conflict with the newer base)

# A finished branch conflicted with the base when it was integrated. Instead of rebuilding the item,
# merge the base in here and let an agent reconcile the conflicts, then re-run the checks.
function Invoke-MergeJob($Job) {
    $branch = $Job.Branch
    $safe = Get-SafeId $Job.Id
    Invoke-Git "switch -q $branch" | Out-Null
    Write-Log "=== merging $($script:BaseRef) into $branch"
    if (-not (Test-Git "merge -q --no-edit --no-verify $($script:BaseRef)")) {
        $conflicts = @(Get-ConflictedPaths)
        if (-not $conflicts) {
            Invoke-Git 'merge --abort' -AllowFail | Out-Null
            return [pscustomobject]@{ outcome = 'failed'; branch = $branch; reason = "git merge $($script:BaseRef) failed without conflicts" }
        }
        $prompt = Expand-Template 'merger' @{
            TASK = $Job.TaskText; BRANCH = $branch
            CONFLICTS = (($conflicts | ForEach-Object { "- ``$_``" }) -join "`n")
        }
        Write-SlotStatus 'resolving merge conflicts'
        $r = Invoke-AgentSafely -Role "merge-$safe" -Prompt $prompt -Model $script:Config.models.builder
        $left = @(Get-ConflictedPaths)
        $pathArgs = ($conflicts | ForEach-Object { '"' + $_ + '"' }) -join ' '
        $markers = @(Invoke-Git "grep -l -e `"^<<<<<<< `" -e `"^>>>>>>> `" -- $pathArgs" -AllowFail | Where-Object { $_.Trim() })
        if ($r.Result -match '(?m)^\s*BLOCKED:\s*(.+)$' -or $left -or $markers) {
            $why = if ($r.Result -match '(?m)^\s*BLOCKED:\s*(.+)$') { $Matches[1].Trim() } else { "conflicts left unresolved in $(@($left + $markers | Select-Object -Unique) -join ', ')" }
            if (Get-GitSha 'MERGE_HEAD') { Invoke-Git 'merge --abort' -AllowFail | Out-Null }
            Invoke-Git 'reset -q --hard' -AllowFail | Out-Null
            return [pscustomobject]@{ outcome = 'failed'; branch = $branch; reason = "merger: $why" }
        }
        if (Get-GitSha 'MERGE_HEAD') { New-Commit "chore($($Job.Id)): merge $($script:BaseRef)" | Out-Null }
    }
    if (Test-TreeDirty) { New-Commit "chore($($Job.Id)): merge resolution" | Out-Null }
    if ($Job.OrigKind -eq 'product') { return [pscustomobject]@{ outcome = 'ready'; branch = $branch; summary = 'merged the newer base' } }
    $changed = @(Invoke-Git "diff --name-only $($script:BaseRef)...HEAD" | Where-Object { $_.Trim() })
    $violations = Get-ProtectedPathViolations $changed $script:Protected $Job.Ids
    if ($violations.Count -gt 0) { Restore-ProtectedPaths $violations }
    Write-SlotStatus 'checks'
    $gates = Invoke-Gates "$safe-merge" $changed -AllowTestDrop:(Test-TestDropAllowed $Job.TaskText @($Job.Ids).Count)
    if (-not $gates.Pass) { return [pscustomobject]@{ outcome = 'failed'; branch = $branch; reason = $gates.Feedback; gate = $gates.Gate } }
    return [pscustomobject]@{ outcome = 'ready'; branch = $branch; summary = "$($gates.Summary); merged the newer base"; testCount = $gates.TestCount; attempt = $Job.Attempt }
}

# ---------------------------------------------------------------- plan (which phases may run in parallel)

function Invoke-PlanJob($Job) {
    $tasks = Read-TaskList $script:TasksPath
    $open = Get-OpenPhaseIds $tasks
    $sections = foreach ($ph in $open) {
        $s = Get-PhaseSection $script:TasksPath $ph
        if ($s.Length -gt 4000) { $s = $s.Substring(0, 4000) + "`n... (truncated)" }
        $s
    }
    $done = @($tasks | Where-Object { $_.Phase -and $_.Id -match $script:TaskIdPattern } | Group-Object Phase |
        Where-Object { -not ($_.Group | Where-Object { $_.Status -in @(' ', '!') }) } | ForEach-Object { "Phase $($_.Name)" })
    $prompt = Expand-Template 'planner' @{
        OPEN_PHASES = ($sections -join "`n`n")
        DONE_PHASES = $(if ($done) { $done -join ', ' } else { '(none)' })
    }
    Write-SlotStatus 'planning lanes'
    $model = if ($script:Config.models.planner) { $script:Config.models.planner } else { 'sonnet' }
    $r = Invoke-AgentSafely -Role 'plan' -Prompt $prompt -Model $model -Policy 'readonly'
    $plan = Get-PhasePlan $r.Result
    if (-not $plan) { return [pscustomobject]@{ outcome = 'failed'; reason = 'the planner gave no parseable plan' } }
    return [pscustomobject]@{ outcome = 'done'; plan = ([pscustomobject]$plan) }
}
