# The daemon (`nightshift run`): runs until stopped. It keeps up to `workers` worker processes busy
# on independent lanes, integrates their branches one at a time (a pull request per item, merged
# automatically, or a local merge when there is no GitHub remote), keeps the queue state, and sends
# whatever blocks to the resolver. It is the only writer of the queue state.
#
# Lanes keep dependent work in order: the tasks file's phases share the lane "tasks" unless a phase
# is marked "(parallel)" / "(after N)"; every approved backlog item, the product round and polish
# each have their own. A lane stays busy until its item is integrated, so the next task in it
# always starts from a base that has the previous one.

function Get-IntegrationBranch { return "$($script:Config.branchPrefix)integration" }

function Initialize-PrMode {
    $mode = [string]$script:Config.pr.mode
    if ($mode -eq 'off') { return $false }
    $hasOrigin = Test-Git 'remote get-url origin' $script:ProjectHome
    $gh = $false
    if ($hasOrigin) {
        $log = Join-Path $script:SessionsDir "$(Get-Stamp)-main-gh-auth.log"
        $gh = ((Invoke-Logged 'gh auth status' $log $null $null 1) -eq 0)
    }
    if ($mode -eq 'on' -and -not ($hasOrigin -and $gh)) { Stop-Night "pr.mode is 'on' but there is no 'origin' remote or gh is not logged in (gh auth login)" }
    return ($hasOrigin -and $gh)
}

# PR mode: workers branch from origin/<base>, every item lands through a merged PR.
# Local mode: they branch from <prefix>integration; <base> follows it whenever that can't touch
# your own work (Sync-BaseBranch), so your checkout may sit on <base> with uncommitted changes.
function Initialize-Integration {
    $home_ = $script:ProjectHome
    $script:PrMode = Initialize-PrMode
    if (-not (Get-GitSha $script:Base $home_)) { Invoke-Git "branch $($script:Base) HEAD" -Dir $home_ | Out-Null }
    if ($script:PrMode) {
        Invoke-Git 'fetch -q --prune origin' -Dir $home_ | Out-Null
        if (-not (Get-GitSha "origin/$($script:Base)" $home_)) {
            Invoke-Git "push -q origin $($script:Base)" -Dir $home_ | Out-Null
            Invoke-Git 'fetch -q origin' -Dir $home_ | Out-Null
        }
        $script:BaseRef = "origin/$($script:Base)"
    } else {
        $int = Get-IntegrationBranch
        if (-not (Get-GitSha $int $home_)) { Invoke-Git "branch $int $($script:Base)" -Dir $home_ | Out-Null }
        $script:BaseRef = $int
    }
    Initialize-Slot 'integrate' $script:BaseRef
    if (-not $script:PrMode) { Invoke-Git "switch -q $(Get-IntegrationBranch)" | Out-Null }
    Import-ProjectConfig $script:Repo
    Set-WorkDir $script:Repo
    $script:LastSync = Get-Date
}

# The integrate worktree back to a clean, idle state.
function Reset-IntegrateWorktree {
    $int = Get-SlotPath 'integrate'
    if (-not (Test-Path $int)) { return }
    Set-WorkDir $int
    if (Get-GitSha 'MERGE_HEAD') { Invoke-Git 'merge --abort' -AllowFail | Out-Null }
    if (Test-TreeDirty) { Invoke-Git 'reset -q --hard' -AllowFail | Out-Null; Invoke-Git 'clean -fdq' -AllowFail | Out-Null }
    if ($script:PrMode) { Invoke-Git "switch -q --detach $($script:BaseRef)" -AllowFail | Out-Null }
    else { Invoke-Git "switch -q $(Get-IntegrationBranch)" -AllowFail | Out-Null }
}

# Picks up new commits (yours on <base>, merged PRs) and re-reads the config from the base.
function Sync-Integration {
    $script:LastSync = Get-Date
    Reset-IntegrateWorktree
    if ($script:PrMode) {
        Invoke-Git 'fetch -q --prune origin' -AllowFail | Out-Null
        Invoke-Git "switch -q --detach $($script:BaseRef)" -AllowFail | Out-Null
    } else {
        $intBranch = Get-IntegrationBranch
        # Commits you made on the base branch flow into the integration branch.
        if (-not (Test-GitAncestor $script:Base $intBranch)) {
            if (-not (Test-Git "merge -q --no-edit --no-verify $($script:Base)")) {
                Invoke-Git 'merge --abort' -AllowFail | Out-Null
                if (-not $script:SyncConflictQueued) {
                    $script:SyncConflictQueued = $true
                    Add-ResolverJob 'health' 'base-sync' "Your ``$($script:Base)`` branch has commits that conflict with ``$intBranch`` (where Night Shift integrates finished work). Merge ``$($script:Base)`` into this branch, resolve the conflicts, and commit."
                }
            }
        }
    }
    Sync-BaseBranch
    Import-ProjectConfig $script:Repo
    Set-WorkDir $script:Repo
}

# Keeps your local base branch up to date with the integrated work: fast-forward only, never
# while the branch is checked out with uncommitted changes or in another worktree of yours.
function Sync-BaseBranch {
    $home_ = $script:ProjectHome
    $base = $script:Base
    $target = Get-GitSha $script:BaseRef $home_
    $cur = Get-GitSha $base $home_
    if (-not $target -or $target -eq $cur) { return }
    if ($cur -and -not (Test-GitAncestor $cur $target $home_)) { return }
    $wtList = @(Invoke-Git 'worktree list --porcelain' -Dir $home_)
    $holders = @()
    for ($i = 0; $i -lt $wtList.Count; $i++) {
        if ($wtList[$i] -like 'worktree *') { $wt = $wtList[$i].Substring(9) }
        if ($wtList[$i] -eq "branch refs/heads/$base") { $holders += $wt }
    }
    $homeNorm = [IO.Path]::GetFullPath($home_).TrimEnd('\')
    foreach ($h in $holders) {
        $hNorm = [IO.Path]::GetFullPath(($h -replace '/', '\')).TrimEnd('\')
        if ($hNorm -ine $homeNorm) { return }
    }
    if ($holders) {
        if (Test-TreeDirty $home_) { return }
        Invoke-Git "merge -q --ff-only $target" -AllowFail -Dir $home_ | Out-Null
    } else {
        Invoke-Git "update-ref refs/heads/$base $target $cur" -AllowFail -Dir $home_ | Out-Null
    }
}

# ---------------------------------------------------------------- queue state

function Save-Overlay { Write-StateMap 'queue.json' $script:Overlay }

function Get-ItemLine([string]$Id) {
    $path = if ($Id -match '^B\d+$') { $script:BacklogPath } else { $script:TasksPath }
    if (-not (Test-Path $path)) { return $null }
    $list = Read-TaskList $path
    return ($list | Where-Object { $_.Id -eq $Id } | Select-Object -First 1)
}

# What's failed or waiting on you, for the product and resolver prompts.
function Get-QueueSummary {
    $lines = foreach ($k in ($script:Overlay.Keys | Sort-Object)) {
        $o = $script:Overlay[$k]
        switch ([string]$o.state) {
            'human' { "- $k waits on the owner: $($o.ask)" }
            { $_ -in @('failed', 'blocked', 'resolving') } { "- $k $($o.state): $($o.short)" }
        }
    }
    if (-not $lines) { return '' }
    return ($lines -join "`n")
}

# Drops entries for items that are done or whose text changed (a rewrite clears a failure).
function Update-Overlay {
    $changed = $false
    foreach ($k in @($script:Overlay.Keys)) {
        $o = $script:Overlay[$k]
        $t = Get-ItemLine $k
        if (-not $t -or $t.Status -eq 'x' -or ($o.text -and $o.text -ne $t.Text -and $o.state -ne 'resolving')) {
            $script:Overlay.Remove($k); $changed = $true
        }
    }
    if ($changed) { Save-Overlay }
}

function Set-OverlayState([string]$Id, [string]$State, [hashtable]$Extra) {
    $old = $script:Overlay[$Id]
    $line = Get-ItemLine $Id
    $entry = [ordered]@{
        state  = $State
        text   = $(if ($line) { $line.Text } elseif ($old) { $old.text } else { '' })
        passes = $(if ($old -and $old.passes) { [int]$old.passes } else { 0 })
        since  = (Get-Date).ToString('s')
    }
    foreach ($k in 'reason', 'short', 'ask', 'branch') { if ($old -and $old.$k) { $entry[$k] = $old.$k } }
    if ($Extra) { foreach ($k in $Extra.Keys) { $entry[$k] = $Extra[$k] } }
    $script:Overlay[$Id] = [pscustomobject]$entry
    Save-Overlay
}

function Get-DailyState {
    $d = Read-JsonFile (Join-Path $script:StateDir 'daily.json')
    $today = Get-Date -Format 'yyyy-MM-dd'
    if (-not $d -or $d.date -ne $today) {
        $d = [pscustomobject]@{ date = $today; productRounds = 0; productCooldownUntil = ''; polishCount = 0; polishExhausted = $false; polishDone = @() }
    }
    return $d
}

function Save-DailyState($D) { Write-JsonFile (Join-Path $script:StateDir 'daily.json') $D }

# ---------------------------------------------------------------- choosing work

function Get-BusyLanes {
    $lanes = @($script:Running.Values | ForEach-Object { $_.Job.Lane })
    $lanes += @($script:Pending | ForEach-Object { $_.Job.Lane })
    if ($script:AwaitingPr) { $lanes += $script:AwaitingPr.Item.Job.Lane }
    $lanes += @($script:MergeQueue | ForEach-Object { $_.Lane })
    return @($lanes | Where-Object { $_ })
}

# Ids of every task / backlog item that is running, queued for a merge, or waiting to be integrated.
function Get-InFlightIds {
    $jobs = @($script:Running.Values | ForEach-Object { $_.Job }) + @($script:Pending | ForEach-Object { $_.Job }) + @($script:MergeQueue)
    if ($script:AwaitingPr) { $jobs += $script:AwaitingPr.Item.Job }
    return @($jobs | Where-Object { $_ -and ($_.Kind -in @('task', 'backlog', 'merge')) } | ForEach-Object { @($_.Ids) } | Select-Object -Unique)
}

function New-WorkJob($Item, [string]$Lane) {
    $job = [ordered]@{
        Kind = $Item.Kind; Id = $Item.Id; Ids = @($Item.Ids); Text = $Item.Text; TaskText = $Item.TaskText; Phase = $Item.Phase
        Lane = $Lane; BaseRef = $script:BaseRef; PrMode = $script:PrMode
        Deadline = $(if ($script:Deadline -lt [datetime]::MaxValue) { $script:Deadline.ToString('s') } else { '' })
    }
    return [pscustomobject]$job
}

# Up to $Free jobs for free worker slots: forced task, task lanes, approved backlog items; and when
# none of those is runnable, a product round (new backlog), then polish.
function Select-WorkJobs([int]$Free) {
    $jobs = New-Object System.Collections.ArrayList
    if ($Free -le 0) { return , $jobs.ToArray() }
    $busy = Get-BusyLanes
    # Items already being built, merged or integrated count as in progress even if the lanes were
    # re-planned since they started: they hold back the rest of their phase like a failed task.
    $inFlight = @{}
    foreach ($id in (Get-InFlightIds)) { $inFlight[$id] = [pscustomobject]@{ state = 'resolving' } }
    $overlay = @{}
    foreach ($k in $script:Overlay.Keys) { $overlay[$k] = $script:Overlay[$k] }
    foreach ($k in $inFlight.Keys) { $overlay[$k] = $inFlight[$k] }
    $tasks = Merge-TaskOverlay (Read-TaskList $script:TasksPath) $overlay

    if ($script:ForcedTask -and -not $script:ForcedTaskUsed) {
        $script:ForcedTaskUsed = $true
        $all = @($tasks) + @($(if (Test-Path $script:BacklogPath) { Read-TaskList $script:BacklogPath }))
        $t = $all | Where-Object { $_.Id -eq $script:ForcedTask } | Select-Object -First 1
        if (-not $t) { throw "Task $($script:ForcedTask) not found" }
        $kind = if ($t.Id -match '^B\d+$') { 'backlog' } else { 'task' }
        $item = New-TaskItem @($t) $kind
        $lane = if ($kind -eq 'backlog') { "backlog:$($t.Id)" } else { 'forced' }
        [void]$jobs.Add((New-WorkJob $item $lane))
        return , $jobs.ToArray()
    }

    $flags = Merge-PhasePlan (Get-PhaseFlags $script:TasksPath) (Get-CurrentPhasePlan)
    $batches = Get-TaskLaneBatches $tasks $flags $busy ($script:Config.parallel.phases -eq 'parallel') ([int]$script:Config.batch.maxTasks) ([int]$script:Config.batch.maxTextLength) @($script:NoBatch)
    foreach ($b in $batches) {
        if ($jobs.Count -ge $Free) { break }
        [void]$jobs.Add((New-WorkJob (New-TaskItem $b.Tasks 'task') $b.Lane))
    }
    $backlogWaiting = $false
    if (Test-Path $script:BacklogPath) {
        $backlog = Merge-TaskOverlay (Read-TaskList $script:BacklogPath) $overlay
        $backlogWaiting = [bool](@($backlog | Where-Object { $_.Id -match '^B\d+$' -and $_.Status -eq ' ' -and $_.Text -match 'status:\s*approved' }))
    }
    if ($jobs.Count -lt $Free -and (Test-Path $script:BacklogPath)) {
        foreach ($t in (Get-BacklogLaneItems $backlog $busy)) {
            if ($jobs.Count -ge $Free) { break }
            $item = New-TaskItem @($t) 'backlog'; $item.Phase = 'backlog'
            [void]$jobs.Add((New-WorkJob $item "backlog:$($t.Id)"))
        }
    }
    if ($jobs.Count -gt 0) { return , $jobs.ToArray() }
    # New work (product, polish) only once the plan itself is exhausted: while planned tasks are
    # merely waiting for their lane, a free worker stays free rather than inventing extra features
    # that compete with the plan for quota and files.
    $waiting = @($tasks | Where-Object { $_.Status -eq ' ' -and $_.Id -match $script:TaskIdPattern })
    if ($waiting -or $backlogWaiting) { return , $jobs.ToArray() }

    $daily = Get-DailyState
    $p = $script:Config.product
    $cool = $daily.productCooldownUntil -and (Get-Date) -lt [datetime]$daily.productCooldownUntil
    if ($busy -notcontains 'product' -and -not $cool -and [int]$daily.productRounds -lt [int]$p.maxRoundsPerDay) {
        $item = [pscustomobject]@{ Kind = 'product'; Id = 'product'; Ids = @('product'); Text = 'propose backlog items'; TaskText = 'propose backlog items'; Phase = '' }
        $job = New-WorkJob $item 'product'
        $job | Add-Member State (Get-QueueSummary)
        [void]$jobs.Add($job)
        return , $jobs.ToArray()
    }
    if ($busy -notcontains 'polish' -and -not $daily.polishExhausted -and [int]$daily.polishCount -lt [int]$script:Config.polishCap) {
        $n = [int]$daily.polishCount + 1
        $item = [pscustomobject]@{ Kind = 'polish'; Id = "polish-$n"; Ids = @("polish-$n"); Text = 'one focused quality improvement'; TaskText = 'one focused quality improvement'; Phase = '' }
        $job = New-WorkJob $item 'polish'
        $job | Add-Member Done $(if (@($daily.polishDone).Count) { @($daily.polishDone) -join '; ' } else { 'nothing yet' })
        [void]$jobs.Add($job)
    }
    return , $jobs.ToArray()
}

# ---------------------------------------------------------------- lane planning

# The tasks file's plan as a signature: the planner runs again when it changes (tasks added,
# rewritten or split, a phase heading retagged), and only while two or more phases have open work.
function Get-OpenPhaseSignature {
    $tasks = Read-TaskList $script:TasksPath
    $open = Get-OpenPhaseIds $tasks
    if (@($open).Count -lt 2) { return '' }
    # Ids and text only: ticking a task off must not trigger a new plan (finished phases simply
    # stop holding others back), but adding, rewriting or splitting tasks does.
    $rows = @($tasks | ForEach-Object { "$($_.Phase)|$($_.Id)|$($_.Text -replace '\s*<!-- failed .*? -->$', '')" })
    $headings = @((Read-TextFile $script:TasksPath).Lines | Where-Object { $_ -match '^## Phase ' })
    $text = ($rows + $headings) -join "`n"
    $sha = [Security.Cryptography.SHA1]::Create()
    return ([BitConverter]::ToString($sha.ComputeHash($script:Utf8.GetBytes($text))) -replace '-', '')
}

# The planner's plan for the current tasks file, or $null (lanes then follow the headings only).
function Get-CurrentPhasePlan {
    if ($script:Config.parallel.phases -eq 'parallel') { return $null }
    $saved = Read-JsonFile (Join-Path $script:StateDir 'phase-plan.json')
    if (-not $saved -or -not $saved.phases) { return $null }
    $plan = @{}
    foreach ($p in $saved.phases.PSObject.Properties) { $plan[$p.Name] = @($p.Value | ForEach-Object { "$_" }) }
    return $plan
}

# A planner job when the open phases changed since the last plan (and nothing is planning yet).
function New-PlanJob {
    if ($script:Config.parallel.phases -ne 'sequential' -or $script:Config.parallel.planner -eq $false) { return $null }
    if (@($script:Running.Values | Where-Object { $_.Job.Kind -eq 'plan' })) { return $null }
    $sig = Get-OpenPhaseSignature
    if (-not $sig) { return $null }
    $saved = Read-JsonFile (Join-Path $script:StateDir 'phase-plan.json')
    if ($saved -and $saved.signature -eq $sig) { return $null }
    $item = [pscustomobject]@{ Kind = 'plan'; Id = 'plan'; Ids = @('plan'); Text = 'plan parallel lanes'; TaskText = 'plan parallel lanes'; Phase = '' }
    $job = New-WorkJob $item 'plan'
    $job | Add-Member Signature $sig
    return $job
}

function Start-SlotJob([string]$Slot, $Job) {
    Write-JsonFile (Join-Path $script:JobsDir "$Slot.json") $Job
    Remove-Item (Join-Path $script:ResultsDir "$Slot.json") -ErrorAction SilentlyContinue
    $cli = Join-Path $script:EngineDir 'lib\cli.ps1'
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$cli`" worker -Project `"$($script:ProjectHome)`" -Slot $Slot"
    $proc = Start-Process powershell.exe -ArgumentList $argLine -WindowStyle Hidden -PassThru
    $null = $proc.Handle
    $script:Running[$Slot] = [pscustomobject]@{ Process = $proc; Job = $Job; Started = Get-Date }
    $script:StartedJobs++
    if ($Job.Kind -eq 'product') { $d = Get-DailyState; $d.productRounds = [int]$d.productRounds + 1; Save-DailyState $d }
    if ($Job.Kind -eq 'polish') { $d = Get-DailyState; $d.polishCount = [int]$d.polishCount + 1; Save-DailyState $d }
    if ($script:ResolverKinds -contains $Job.Kind -and $Job.ItemId) { Set-OverlayState $Job.ItemId 'resolving' }
    Write-Log "started $($Job.Kind) $($Job.Id) in $Slot (PID $($proc.Id))"
}

function Start-WorkJobs {
    $workers = [Math]::Max(1, [int]$script:Config.workers)
    $free = @(1..$workers | ForEach-Object { "w$_" } | Where-Object { -not $script:Running.ContainsKey($_) })
    if (-not $free) { return 0 }
    # Merges and the planner start first, and each is running before new work is chosen, so the
    # selection sees them as in progress.
    $i = 0
    while ($script:MergeQueue.Count -and $i -lt $free.Count) {
        $j = $script:MergeQueue[0]
        $script:MergeQueue.RemoveAt(0)
        Start-SlotJob $free[$i] $j; $i++
    }
    if ($i -lt $free.Count) { $plan = New-PlanJob; if ($plan) { Start-SlotJob $free[$i] $plan; $i++ } }
    if ($i -lt $free.Count) { foreach ($j in (Select-WorkJobs ($free.Count - $i))) { Start-SlotJob $free[$i] $j; $i++ } }
    return $i
}

# ---------------------------------------------------------------- resolver queue

# Queued resolver work, most urgent first: your requests, pipeline health, then failed items.
function Add-ResolverJob([string]$Kind, [string]$Id, [string]$Reason, $Item, [string]$Request) {
    if (@($script:ResolverQueue | Where-Object { $_.Kind -eq $Kind -and $_.Id -eq $Id })) { return }
    $job = [ordered]@{
        Kind = $Kind; Id = $Id; ItemId = ''; Ids = @($Id); Text = ''; TaskText = ''; Phase = ''; Lane = 'resolver'
        Reason = $Reason; Request = $Request; BaseRef = $script:BaseRef; PrMode = $script:PrMode; Deadline = ''; State = ''
    }
    if ($Item) { $job.ItemId = $Item.Id; $job.Text = $Item.Text; $job.TaskText = $Item.TaskText; $job.Phase = $Item.Phase }
    else { $job.Text = Get-ShortReason $(if ($Request) { $Request } else { $Reason }) 100 }
    $prio = @{ maintain = 0; health = 1; resolve = 2 }
    $obj = [pscustomobject]$job
    $at = 0
    while ($at -lt $script:ResolverQueue.Count -and $prio[$script:ResolverQueue[$at].Kind] -le $prio[$Kind]) { $at++ }
    $script:ResolverQueue.Insert($at, $obj)
    Write-Log "queued resolver ($Kind) for $Id"
}

function Add-ResolveForItem([string]$Id, [switch]$Manual) {
    if (-not $script:Config.resolver.enabled -and -not $Manual) { return }
    $o = $script:Overlay[$Id]
    if (-not $Manual -and $o -and [int]$o.passes -ge [int]$script:Config.resolver.maxPerItem) { return }
    $line = Get-ItemLine $Id
    if (-not $line) { return }
    $kind = if ($Id -match '^B\d+$') { 'backlog' } else { 'task' }
    $item = New-TaskItem @([pscustomobject]@{ Id = $line.Id; Text = ($line.Text -replace '\s*<!-- failed .*? -->$', ''); Phase = $line.Phase }) $kind
    $reason = if ($o -and $o.reason) { [string]$o.reason } elseif ($line.Text -match '<!-- failed [\d-]+: (.*?) -->$') { $Matches[1] } else { '(no reason recorded)' }
    $passes = if ($o -and $o.passes) { [int]$o.passes } else { 0 }
    Set-OverlayState $Id $(if ($o) { [string]$o.state } else { 'failed' }) @{ passes = $passes + 1 }
    Add-ResolverJob 'resolve' "resolve-$Id" $reason $item
}

function Start-ResolverJob {
    if ($script:Running.ContainsKey('resolver') -or $script:ResolverQueue.Count -eq 0) { return 0 }
    $job = $script:ResolverQueue[0]
    $script:ResolverQueue.RemoveAt(0)
    $job.BaseRef = $script:BaseRef
    $job.State = Get-QueueSummary
    Start-SlotJob 'resolver' $job
    return 1
}

# Requests dropped by the CLI (ask / retry / resolve) while the daemon runs.
function Read-Inbox {
    foreach ($f in @(Get-ChildItem $script:InboxDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $req = Read-JsonFile $f.FullName
        Remove-Item $f.FullName -ErrorAction SilentlyContinue
        if (-not $req) { continue }
        switch ([string]$req.type) {
            'ask' { Add-ResolverJob 'maintain' ([string]$req.id) '' $null ([string]$req.text); Add-Report "- [ask] $($req.id): $($req.text)" }
            'retry' {
                if ($script:Overlay.ContainsKey([string]$req.item)) { Set-OverlayState ([string]$req.item) 'open' @{ passes = 0 } }
                $script:NoBatch.Remove([string]$req.item)
                Add-Report "- [retry] $($req.item) reopened by you"
            }
            'resolve' {
                $ids = if ($req.item) { @([string]$req.item) } else { @($script:Overlay.Keys | Where-Object { $script:Overlay[$_].state -in @('failed', 'blocked') }) }
                foreach ($id in $ids) { Add-ResolveForItem $id -Manual }
            }
        }
    }
}

# ---------------------------------------------------------------- results

function Update-Workers {
    foreach ($slot in @($script:Running.Keys)) {
        $w = $script:Running[$slot]
        if (-not $w.Process.HasExited) { continue }
        $script:Running.Remove($slot)
        $r = Read-JsonFile (Join-Path $script:ResultsDir "$slot.json")
        if (-not $r) { $r = New-JobResult $w.Job; $r.reason = "worker process exited ($($w.Process.ExitCode)) without a result; see run.log" }
        Remove-Item (Join-Path $script:ResultsDir "$slot.json") -ErrorAction SilentlyContinue
        Complete-JobResult $w.Job $r
    }
}

function Complete-JobResult($Job, $R) {
    Write-Log "finished $($Job.Kind) $($Job.Id): $($R.outcome)$(if ($R.reason -and $R.outcome -ne 'ready') { " - $(Get-ShortReason $R.reason)" })"
    if ($Job.Kind -eq 'plan') { Complete-PlanResult $Job $R; return }
    if ($Job.Kind -eq 'merge') { Complete-MergeResult $Job $R; return }
    $isResolver = $script:ResolverKinds -contains $Job.Kind
    switch ([string]$R.outcome) {
        'ready' { [void]$script:Pending.Add([pscustomobject]@{ Job = $Job; Result = $R }) }
        'done' {
            Invoke-Git "branch -q -D $($R.branch)" -AllowFail | Out-Null
            Complete-Resolution $Job $R.resolution
        }
        'stopped' { Write-Log "$($Job.Id) stopped; its branch resumes next time" }
        'violation' {
            Add-Report "- [guard] the resolver rewrote protected history: $($R.reason). Local refs were restored; Night Shift is paused until you look (nightshift resume)."
            Send-Notice 'Night Shift paused' "The resolver rewrote protected history: $($R.reason)"
            [IO.File]::WriteAllText($script:PauseFile, "guard violation $(Get-Date -Format s)", $script:Utf8)
            if ($Job.ItemId) { Set-OverlayState $Job.ItemId 'failed' }
        }
        'crashed' {
            $n = [int]$script:CrashCounts[$Job.Id] + 1
            $script:CrashCounts[$Job.Id] = $n
            Add-Report "- [crash] $($Job.Id) - $(Get-ShortReason $R.reason)"
            if ($isResolver) { Complete-Resolution $Job $null }
            elseif ($n -ge 2 -and $Job.Kind -in @('task', 'backlog')) { Register-Failure $Job $R }
        }
        default {
            # blocked / failed
            if ($isResolver) {
                Add-Report "- [resolver failed] $($Job.Id) - its own change failed the checks: $(Get-ShortReason $R.reason)"
                Save-FailedBranch $R.branch | Out-Null
                Complete-Resolution $Job $R.resolution -NotIntegrated
            } elseif ($Job.Kind -eq 'product') {
                $d = Get-DailyState; $d.productCooldownUntil = (Get-Date).AddHours([double]$script:Config.product.cooldownHours).ToString('s'); Save-DailyState $d
                Invoke-Git "branch -q -D $($R.branch)" -AllowFail | Out-Null
                Add-Report "- [product] no usable proposals ($(Get-ShortReason $R.reason)); next round in $($script:Config.product.cooldownHours)h"
            } elseif ($Job.Kind -eq 'polish') {
                if ($R.polishExhausted -and $R.outcome -eq 'blocked') { $d = Get-DailyState; $d.polishExhausted = $true; Save-DailyState $d }
                $kept = Save-FailedBranch $R.branch
                $where = if ($kept) { "; branch ``$kept``" } else { '' }
                Add-Report "- [polish] $($Job.Id) - $(Get-ShortReason $R.reason)$where"
            } else { Register-Failure $Job $R }
        }
    }
}

function Complete-PlanResult($Job, $R) {
    $phases = if ($R.outcome -eq 'done' -and $R.plan) { $R.plan } else { [pscustomobject]@{} }
    Write-JsonFile (Join-Path $script:StateDir 'phase-plan.json') ([pscustomobject]@{ signature = $Job.Signature; phases = $phases; planned = (Get-Date).ToString('s') })
    if ($R.outcome -ne 'done') { Add-Report "- [plan] $(Get-ShortReason $R.reason); phases stay in order until the tasks change"; return }
    $free = @($phases.PSObject.Properties | Where-Object { @($_.Value).Count -eq 0 } | ForEach-Object { $_.Name })
    $waits = @($phases.PSObject.Properties | Where-Object { @($_.Value).Count } | ForEach-Object { "$($_.Name) after $(@($_.Value) -join '+')" })
    $freeText = if ($free) { $free -join ', ' } else { '(none)' }
    $waitText = if ($waits) { "; $($waits -join ', ')" } else { '' }
    Add-Report "- [plan] lanes: phases $freeText can run in parallel$waitText"
}

# The original item behind a merge job, as the integrator and failure handling expect it.
function Get-MergeOrigin($Job) {
    $orig = $Job.PSObject.Copy()
    $orig.Kind = $Job.OrigKind
    $orig | Add-Member MergeTried $true -Force
    return $orig
}

function Complete-MergeResult($Job, $R) {
    $orig = Get-MergeOrigin $Job
    if ($R.outcome -eq 'ready') {
        if (-not $R.attempt) { $R.attempt = $Job.Attempt }
        [void]$script:Pending.Add([pscustomobject]@{ Job = $orig; Result = $R })
        Add-Report "- [merged base] $($Job.Id) - conflicts with the newer base reconciled; integrating"
        return
    }
    if ($R.outcome -eq 'stopped') { return }
    Register-IntegrationFailure ([pscustomobject]@{ Job = $orig; Result = $R }) ([pscustomobject]@{ Ok = $false; Conflict = $true; Reason = "$(Get-ShortReason $R.reason) (after a merge attempt)" })
}

function Register-Failure($Job, $R) {
    $short = Get-ShortReason $R.reason
    $kept = Save-FailedBranch $R.branch
    $where = if ($kept) { "; branch ``$kept``" } else { '' }
    # A failed batch is not a verdict on its tasks: retry them one at a time instead.
    if ($Job.Kind -eq 'task' -and @($Job.Ids).Count -gt 1) {
        foreach ($id in $Job.Ids) { [void]$script:NoBatch.Add($id) }
        Add-Report "- [batch retry] $($Job.Id) - $short$where; retrying one task at a time"
        return
    }
    $blocked = ($R.outcome -eq 'blocked')
    $state = if ($blocked) { 'blocked' } else { 'failed' }
    $reason = [string]$R.reason
    if ($reason.Length -gt 3000) { $reason = $reason.Substring(0, 3000) + '...' }
    Set-OverlayState $Job.Id $state @{ reason = $reason; short = $short; branch = $kept }
    if ($blocked) { $script:Stats.Blocked++ } else { $script:Stats.Failed++ }
    Add-Report "- [$state] $($Job.Id) $($Job.Text) - $short$where"

    # Several different items failing the same check usually means the base or the environment
    # is broken, not the items: that's a job for the resolver, once.
    if ($R.gate) {
        if ($script:GateStreak.Gate -eq $R.gate) { $script:GateStreak.Count++ } else { $script:GateStreak = @{ Gate = $R.gate; Count = 1 } }
        if ($script:GateStreak.Count -ge [int]$script:Config.resolver.healthAfterFailures -and -not $script:HealthQueued[$R.gate]) {
            $script:HealthQueued[$R.gate] = $true
            Add-ResolverJob 'health' "check-$($R.gate)" "The last $($script:GateStreak.Count) items all failed the check '$($R.gate)'. Find out whether the base branch itself fails it (run it on this clean branch) or the environment is broken, and fix that. The latest failure:`n$reason"
        }
    }
    Add-ResolveForItem $Job.Id
}

# Applies what the resolver decided. -NotIntegrated: its repo changes didn't make it in.
function Complete-Resolution($Job, $Res, [switch]$NotIntegrated) {
    if (-not $Res) { $Res = [pscustomobject]@{ diagnosis = '(the resolver gave no outcome)'; did = @(); retry = $false; human = ''; hint = '' } }
    $did = if (@($Res.did).Count) { "; did: $(@($Res.did) -join '; ')" } else { '' }
    switch ($Job.Kind) {
        'resolve' {
            $id = $Job.ItemId
            if ($Res.retry -and -not $NotIntegrated) {
                Set-OverlayState $id 'open'
                $hints = Read-StateMap 'unblock-hints.json'
                $hints[$id] = "A previous attempt at this task was blocked: $($Res.diagnosis)" + $(if (@($Res.did).Count) { " Since then: $(@($Res.did) -join '; ')." } else { '' }) + $(if ($Res.hint) { " $($Res.hint)" } else { '' })
                Write-StateMap 'unblock-hints.json' $hints
                $script:NoBatch.Remove($id)
                $script:Stats.Unblocked++
                Add-Report "- [resolved] $id - $($Res.diagnosis)$did; reopened"
            } elseif ($Res.human) {
                Set-OverlayState $id 'human' @{ ask = $Res.human }
                Add-Report "- [needs you] $id - $($Res.human)"
                Send-Notice "Night Shift needs you ($id)" $Res.human
            } else {
                Set-OverlayState $id 'failed'
                Add-Report "- [resolver declined] $id - $($Res.diagnosis)$did"
            }
        }
        default {
            $tag = if ($Job.Kind -eq 'maintain') { 'done' } else { 'health' }
            Add-Report "- [$tag] $($Job.Id) - $($Res.diagnosis)$did$(if ($NotIntegrated) { ' (its repo changes failed the checks and were not merged)' })"
            if ($Res.human) { Add-Report "  - needs you: $($Res.human)"; Send-Notice "Night Shift needs you" $Res.human }
            if ($Job.Kind -eq 'maintain') {
                Write-JsonFile (Join-Path $script:InboxDir "done\$($Job.Id).json") ([pscustomobject]@{ id = $Job.Id; request = $Job.Request; diagnosis = $Res.diagnosis; did = @($Res.did); human = $Res.human; merged = (-not $NotIntegrated) })
            }
            if ($Job.Kind -eq 'health' -and $Job.Id -eq 'base-sync') { $script:SyncConflictQueued = $false }
        }
    }
}

# ---------------------------------------------------------------- integration

function Get-PrBody($P) {
    $r = $P.Result
    $lines = @("Night Shift $($P.Job.Kind) **$($P.Job.Id)**", '', $P.Job.Text, '')
    if ($r.summary) { $lines += "- $($r.summary)" }
    if ($r.attempt) { $lines += "- attempt $($r.attempt) of $($script:Config.maxAttempts)" }
    if (@($r.approved).Count) { $lines += "- auto-approved for building: $(@($r.approved) -join ', ')" }
    if ($r.resolution) { $lines += "- resolver: $($r.resolution.diagnosis)"; foreach ($d in @($r.resolution.did)) { $lines += "  - $d" } }
    $notes = @($r.reviewNotes | Where-Object { $_ -and $_ -ne '(reviewer gave no verdict)' })
    if ($notes) { $lines += '- reviewer notes:'; foreach ($n in $notes) { $lines += "  - $n" } }
    if ($P.Job.Request) { $lines += '', "Request: $($P.Job.Request)" }
    return ($lines -join "`n")
}

function Invoke-Gh([string]$ArgLine, [string]$Label) {
    $log = Join-Path $script:SessionsDir "$(Get-Stamp)-integrate-gh-$Label.log"
    $code = Invoke-Logged "gh $ArgLine" $log $null $null 5
    return [pscustomobject]@{ Ok = ($code -eq 0); Text = $(if (Test-Path $log) { [IO.File]::ReadAllText($log) } else { '' }) }
}

# Push, open (or reuse) the PR, merge it. With required checks, auto-merge and wait.
function Publish-PullRequest($P, [string]$Branch) {
    $safe = Get-SafeId $P.Job.Id
    Invoke-Git "push -q --force-with-lease -u origin $Branch" | Out-Null
    $list = Invoke-Gh "pr list --head `"$Branch`" --state open --json url" "list-$safe"
    $url = ''
    try { $url = [string](@($list.Text | ConvertFrom-Json)[0].url) } catch { }
    if (-not $url) {
        $title = "$($P.Job.Id): $($P.Job.Text)" -replace '"', "'"
        if ($title.Length -gt 100) { $title = $title.Substring(0, 97) + '...' }
        $bodyFile = Join-Path $script:StateDir "pr-body-$PID.md"
        [IO.File]::WriteAllText($bodyFile, (Get-PrBody $P), $script:Utf8)
        $create = Invoke-Gh "pr create --base `"$($script:Base)`" --head `"$Branch`" --title `"$title`" --body-file `"$bodyFile`"" "create-$safe"
        if (-not $create.Ok) { return [pscustomobject]@{ Ok = $false; Reason = "gh pr create failed: $(Get-ShortReason $create.Text)" } }
        $url = ([regex]::Matches($create.Text, 'https://\S+') | Select-Object -Last 1).Value
    }
    $method = switch ([string]$script:Config.pr.mergeMethod) { 'squash' { '--squash' } 'rebase' { '--rebase' } default { '--merge' } }
    $merge = Invoke-Gh "pr merge `"$url`" $method" "merge-$safe"
    if (-not $merge.Ok) {
        if ([string]$script:Config.pr.requireChecks -ne 'never' -and $merge.Text -match '(?i)required|status check|not mergeable|protected|policy|review') {
            $auto = Invoke-Gh "pr merge `"$url`" $method --auto" "automerge-$safe"
            if ($auto.Ok) { return [pscustomobject]@{ Ok = $false; Awaiting = $true; Url = $url } }
        }
        return [pscustomobject]@{ Ok = $false; Reason = "gh pr merge failed: $(Get-ShortReason $merge.Text)"; Url = $url }
    }
    Complete-PrCleanup $Branch
    return [pscustomobject]@{ Ok = $true; Url = $url }
}

function Complete-PrCleanup([string]$Branch) {
    Invoke-Git 'fetch -q --prune origin' -AllowFail | Out-Null
    Invoke-Git "switch -q --detach $($script:BaseRef)" -AllowFail | Out-Null
    Invoke-Git "push -q origin --delete $Branch" -AllowFail | Out-Null
    Invoke-Git "branch -q -D $Branch" -AllowFail | Out-Null
}

# Brings a ready branch up to date with the base (re-running the checks if the base moved), ticks
# its tasks on the branch itself, then lands it.
function Merge-ReadyBranch($P) {
    $job = $P.Job; $r = $P.Result
    $branch = $r.branch
    $safe = Get-SafeId $job.Id
    Set-WorkDir (Get-SlotPath 'integrate')
    if ($script:PrMode) { Invoke-Git 'fetch -q --prune origin' -AllowFail | Out-Null }
    Invoke-Git "switch -q $branch" | Out-Null
    $summary = $r.summary
    $testCount = $r.testCount
    if (-not (Test-GitAncestor $script:BaseRef 'HEAD')) {
        if (-not (Test-Git "merge -q --no-edit --no-verify $($script:BaseRef)")) {
            $files = (Get-ConflictedPaths) -join ', '
            Invoke-Git 'merge --abort' -AllowFail | Out-Null
            return [pscustomobject]@{ Ok = $false; Conflict = $true; Reason = "merge conflict with the newer $($script:BaseRef) in: $files" }
        }
        if ($job.Kind -ne 'product') {
            $changed = @(Invoke-Git "diff --name-only $($script:BaseRef)...HEAD" | Where-Object { $_.Trim() })
            Write-Log "base moved since $($job.Id) was checked; re-running the checks"
            $g = Invoke-Gates "$safe-int" $changed -AllowTestDrop:(Test-TestDropAllowed $job.TaskText @($job.Ids).Count)
            if (-not $g.Pass) { return [pscustomobject]@{ Ok = $false; Reason = $g.Feedback; Gate = $g.Gate } }
            $summary = $g.Summary; $testCount = $g.TestCount
        }
    }
    try {
        switch ($job.Kind) {
            'task' {
                foreach ($id in $job.Ids) { Set-TaskStatus $script:TasksPath $id 'x' }
                New-Commit "chore(tasks): complete $(@($job.Ids) -join ', ')" @($script:Config.files.tasks) | Out-Null
            }
            'backlog' {
                Set-TaskStatus $script:BacklogPath $job.Id 'x'
                New-Commit "chore(backlog): complete $($job.Id)" @($script:Config.files.backlog) | Out-Null
            }
        }
    } catch { Write-Log "could not tick $($job.Id): $($_.Exception.Message)" }
    if ($null -ne $testCount -and "$testCount" -ne '') { Set-TestBaseline ([int]$testCount) }
    $r.summary = $summary

    if ($script:PrMode) {
        $pr = Publish-PullRequest $P $branch
        $pr | Add-Member Summary $summary -Force
        return $pr
    }
    Invoke-Git "switch -q $(Get-IntegrationBranch)" | Out-Null
    $msgFile = Join-Path $script:StateDir "merge-msg-$PID.txt"
    [IO.File]::WriteAllText($msgFile, "merge($($job.Id)): $($job.Text)", $script:Utf8)
    Invoke-Git "merge -q --no-ff --no-verify -F `"$msgFile`" $branch" | Out-Null
    Invoke-Git "branch -q -D $branch" -AllowFail | Out-Null
    return [pscustomobject]@{ Ok = $true; Url = ''; Summary = $summary }
}

function Invoke-NextIntegration {
    if ($script:AwaitingPr) { Update-AwaitingPr; return }
    if ($script:Pending.Count -eq 0) { return }
    $p = $script:Pending[0]
    $script:Pending.RemoveAt(0)
    try { $res = Merge-ReadyBranch $p }
    catch {
        $msg = $_.Exception.Message
        if ($msg -like 'STOP_NIGHT:*') { throw }
        $res = [pscustomobject]@{ Ok = $false; Reason = "integration error: $msg" }
    }
    if ($res.Ok) { Complete-Integrated $p $res }
    elseif ($res.Awaiting) {
        $script:AwaitingPr = [pscustomobject]@{ Item = $p; Url = $res.Url; Since = Get-Date; Checked = Get-Date }
        Add-Report "- [pr] $($p.Job.Id) waiting for required checks: $($res.Url)"
    } else { Register-IntegrationFailure $p $res }
    Reset-IntegrateWorktree
}

# A PR set to auto-merge after required checks: merged -> done; closed or failing checks -> back to work.
function Update-AwaitingPr {
    $a = $script:AwaitingPr
    if (((Get-Date) - $a.Checked).TotalMinutes -lt 2) { return }
    $a.Checked = Get-Date
    $view = Invoke-Gh "pr view `"$($a.Url)`" --json state,statusCheckRollup" 'view'
    if (-not $view.Ok) { return }
    $info = try { $view.Text | ConvertFrom-Json } catch { $null }
    if (-not $info) { return }
    if ($info.state -eq 'MERGED') {
        $script:AwaitingPr = $null
        Set-WorkDir (Get-SlotPath 'integrate')
        Complete-PrCleanup $a.Item.Result.branch
        Complete-Integrated $a.Item ([pscustomobject]@{ Ok = $true; Url = $a.Url; Summary = $a.Item.Result.summary })
        return
    }
    $failing = @($info.statusCheckRollup | Where-Object { $_.conclusion -in @('FAILURE', 'TIMED_OUT', 'CANCELLED', 'ACTION_REQUIRED') } | ForEach-Object { if ($_.name) { $_.name } else { $_.context } })
    if ($info.state -eq 'CLOSED' -or $failing) {
        $script:AwaitingPr = $null
        $why = if ($failing) { "required checks failed on the PR: $($failing -join ', ') ($($a.Url))" } else { "the PR was closed ($($a.Url))" }
        if ($failing) { Invoke-Gh "pr merge `"$($a.Url)`" --disable-auto" 'disable-auto' | Out-Null }
        Register-IntegrationFailure $a.Item ([pscustomobject]@{ Ok = $false; Reason = $why })
    }
}

function Complete-Integrated($P, $Res) {
    $job = $P.Job; $r = $P.Result
    if ($job.Kind -in @('task', 'backlog')) { foreach ($id in @($job.Ids)) { if ($script:Overlay.ContainsKey($id)) { $script:Overlay.Remove($id) } } }
    Save-Overlay
    $hints = Read-StateMap 'unblock-hints.json'
    if (@($job.Ids | Where-Object { $hints.ContainsKey($_) })) { foreach ($id in $job.Ids) { $hints.Remove($id) }; Write-StateMap 'unblock-hints.json' $hints }
    $script:IntegrationFails.Remove($job.Id)
    $script:GateStreak = @{ Gate = ''; Count = 0 }
    $script:Stats.Merged++
    $via = if ($Res.Url) { "; $($Res.Url)" } else { '' }
    switch ($job.Kind) {
        'product' { Add-Report "- [product] new proposals in $($script:Config.files.backlog)$(if (@($r.approved).Count) { "; auto-approved, building now: $(@($r.approved) -join ', ')" })$via" }
        'polish' {
            $d = Get-DailyState; $d.polishDone = @(@($d.polishDone) + @($r.polishDone) | Where-Object { $_ }); Save-DailyState $d
            Add-Report "- [merged] $($job.Id) $($r.polishDone) - $($Res.Summary)$via"
        }
        { $script:ResolverKinds -contains $_ } { Add-Report "- [merged] resolver changes for $($job.Id)$via"; Complete-Resolution $job $r.resolution }
        default { Add-Report "- [merged] $($job.Id) $($job.Text) - attempt $($r.attempt); $($Res.Summary)$via" }
    }
    Write-Log "integrated $($job.Id)"
    Sync-BaseBranch
}

function Register-IntegrationFailure($P, $Res) {
    $job = $P.Job; $r = $P.Result
    $n = [int]$script:IntegrationFails[$job.Id] + 1
    $script:IntegrationFails[$job.Id] = $n
    Write-Log "integration of $($job.Id) failed: $(Get-ShortReason $Res.Reason)"
    if ($script:ResolverKinds -contains $job.Kind) {
        Save-FailedBranch $r.branch | Out-Null
        Complete-Resolution $job $r.resolution -NotIntegrated
        return
    }
    if ($Res.Conflict -and -not $job.MergeTried -and $r.branch -and $job.Kind -in @('task', 'backlog', 'polish', 'product')) {
        $m = $job.PSObject.Copy()
        $m | Add-Member OrigKind $job.Kind -Force
        $m | Add-Member Branch $r.branch -Force
        $m | Add-Member Attempt $r.attempt -Force
        $m.Kind = 'merge'
        $m.BaseRef = $script:BaseRef
        [void]$script:MergeQueue.Add($m)
        $script:IntegrationFails[$job.Id] = $n - 1
        Add-Report "- [conflict] $($job.Id) - $($Res.Reason); a merger reconciles it"
        return
    }
    if ($job.Kind -in @('product', 'polish')) {
        Save-FailedBranch $r.branch | Out-Null
        Add-Report "- [$($job.Kind)] $($job.Id) could not be integrated: $(Get-ShortReason $Res.Reason)"
        return
    }
    if ($Res.Conflict) {
        Save-FailedBranch $r.branch | Out-Null
        Add-Report "- [conflict] $($job.Id) - $($Res.Reason); rebuilding on the new base"
    } else {
        Add-Report "- [recheck] $($job.Id) - $(Get-ShortReason $Res.Reason); back to the fixer"
    }
    if ($n -ge 2) {
        $R2 = [pscustomobject]@{ outcome = 'failed'; branch = ''; reason = $Res.Reason; gate = $Res.Gate }
        Register-Failure $job $R2
    }
}

# ---------------------------------------------------------------- daemon lifecycle

function Write-DaemonState([string]$Note) {
    Write-JsonFile (Join-Path $script:StateDir 'daemon.json') ([pscustomobject]@{
            pid = $PID; updated = (Get-Date).ToString('s'); mode = $(if ($script:PrMode) { 'pr' } else { 'local' }); baseRef = $script:BaseRef
            pending = @($script:Pending | ForEach-Object { $_.Job.Id }); awaitingPr = $(if ($script:AwaitingPr) { $script:AwaitingPr.Url } else { '' })
            resolverQueue = @($script:ResolverQueue | ForEach-Object { "$($_.Kind) $($_.Id)" }); note = $Note
        })
}

# Worker processes left by a daemon that died: their work is resumable, so stop them cleanly.
function Stop-OrphanWorkers {
    foreach ($f in @(Get-ChildItem $script:SlotsDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $s = Read-JsonFile $f.FullName
        if ($s -and $s.pid -and (Get-Process -Id $s.pid -ErrorAction SilentlyContinue)) {
            Write-Log "stopping orphaned worker $($s.slot) (PID $($s.pid))"
            & $env:ComSpec /d /c "taskkill /T /F /PID $($s.pid) >nul 2>&1"
        }
        Remove-Item $f.FullName -ErrorAction SilentlyContinue
    }
    Get-ChildItem $script:ResultsDir -File -ErrorAction SilentlyContinue | Remove-Item -ErrorAction SilentlyContinue
    # A killed worker leaves its branch checked out in its slot, and git won't check a branch out
    # in two worktrees: keep any leftovers as a WIP commit and detach, so the branch can be resumed
    # from any slot.
    $root = Get-WorktreeRoot
    foreach ($dir in @(Get-ChildItem $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'integrate' })) {
        if (-not (Test-Path (Join-Path $dir.FullName '.git'))) { continue }
        $branch = Get-CurrentBranch $dir.FullName
        if (-not $branch) { continue }
        Set-WorkDir $dir.FullName
        try {
            if (Get-GitSha 'MERGE_HEAD') { Invoke-Git 'merge --abort' -AllowFail | Out-Null }
            if (Test-TreeDirty) { New-Commit 'wip: state left by an interrupted worker' | Out-Null }
            Invoke-Git 'switch -q --detach' -AllowFail | Out-Null
            Write-Log "released $branch from $($dir.Name)"
        } catch { Write-Log "could not release $branch from $($dir.Name): $($_.Exception.Message)" }
    }
    Set-WorkDir $script:ProjectHome
}

function Write-Summary {
    $tasks = Merge-TaskOverlay (Read-TaskList $script:TasksPath) $script:Overlay
    $open = @($tasks | Where-Object { $_.Status -eq ' ' }).Count
    $done = @($tasks | Where-Object { $_.Status -eq 'x' }).Count
    $cost = 0.0
    $today = Get-Date -Format 'yyyy-MM-dd'
    $costLog = Join-Path $script:StateDir 'cost.log'
    if (Test-Path $costLog) { foreach ($l in (Get-Content $costLog)) { $f = $l -split "`t"; if ($f[0] -eq $today) { $cost += [double]$f[2] } } }
    Add-Report ''
    Add-Report "### Summary ($(Get-Date -Format 'HH:mm'))"
    Add-Report ''
    Add-Report "- merged: $($script:Stats.Merged), failed: $($script:Stats.Failed), blocked: $($script:Stats.Blocked), unblocked: $($script:Stats.Unblocked)"
    Add-Report "- $($script:Config.files.tasks): $done done, $open open"
    Add-Report ("- notional API-equivalent cost of today's sessions: `${0:N2} (covered by the subscription)" -f $cost)
    $failed = @($script:Overlay.Keys | Where-Object { $script:Overlay[$_].state -in @('failed', 'blocked') })
    if ($failed) { Add-Report "- failed, resolver passes used up: $($failed -join ', ') (nightshift retry -Task <id> / nightshift ask ...)" }
    $human = @($script:Overlay.Keys | Where-Object { $script:Overlay[$_].state -eq 'human' })
    $userTasks = Get-PendingUserTasks (Read-TaskList $script:TasksPath)
    if ($human -or $userTasks) {
        Add-Report '- waiting on you:'
        foreach ($h in $human) { Add-Report "  - $h $($script:Overlay[$h].ask)" }
        foreach ($u in $userTasks) { Add-Report "  - $($u.Id) $($u.Text)" }
    }
    if (Test-Path $script:BacklogPath) {
        $backlogList = Read-TaskList $script:BacklogPath
        $proposed = @($backlogList | Where-Object { $_.Status -eq ' ' -and $_.Text -match 'status:\s*proposed' })
        if ($proposed) {
            Add-Report "- proposals awaiting approval ($($script:Config.files.backlog)):"
            foreach ($p in $proposed) { Add-Report "  - $($p.Id) $($p.Text)" }
        }
    }
    $notesPath = Join-Path $script:Repo $script:Config.files.notes
    if (Test-Path $notesPath) {
        $notesLines = @(Get-Content $notesPath).Count
        if ($notesLines -gt [int]$script:Config.notesMaxLines) {
            Add-Report "- $($script:Config.files.notes) is $notesLines lines (limit $($script:Config.notesMaxLines)): every session reads it; prune it (or: nightshift ask ""condense NOTES.md"")"
        }
    }
    Add-Report "- promote when happy: open a PR $($script:Base) -> main (or git switch main && git merge $($script:Base))"
}

# The daemon. -Once: one item, then stop. -Task: that item first. -UrgentOnly: only the resolver
# queue and your requests (ask / resolve without a running daemon), then stop.
function Start-Daemon([switch]$Once, [string]$Task, [switch]$UrgentOnly) {
    $running = Get-RunningPid
    if ($running) { Write-Host "Night Shift is already running for $($script:Config.name) (PID $running)."; return 0 }
    [IO.File]::WriteAllText($script:LockFile, "$PID", $script:Utf8)
    if (Test-Path $script:StopFile) { Remove-Item $script:StopFile -Force }
    Disable-ConsoleQuickEdit

    Add-Type -Namespace NightShift -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);' -ErrorAction SilentlyContinue
    [NightShift.Power]::SetThreadExecutionState([uint32]2147483649) | Out-Null  # ES_CONTINUOUS | ES_SYSTEM_REQUIRED
    $env:ECC_GATEGUARD = 'off'

    $script:Running = @{}
    $script:Pending = New-Object System.Collections.ArrayList
    $script:AwaitingPr = $null
    $script:ResolverQueue = New-Object System.Collections.ArrayList
    $script:MergeQueue = New-Object System.Collections.ArrayList
    $script:NoBatch = New-Object System.Collections.ArrayList
    $script:Stats = @{ Merged = 0; Failed = 0; Blocked = 0; Unblocked = 0 }
    $script:GateStreak = @{ Gate = ''; Count = 0 }
    $script:HealthQueued = @{}
    $script:CrashCounts = @{}
    $script:IntegrationFails = @{}
    $script:ForcedTask = $Task
    $script:ForcedTaskUsed = $false
    $script:StartedJobs = 0
    $script:SyncConflictQueued = $false
    $script:Overlay = Read-StateMap 'queue.json'
    $exitCode = 0
    $loopCrashes = @{}
    $idleLogged = $false

    try {
        if (-not (Test-Path (Join-Path $script:ProjectHome '.git'))) { Stop-Night 'not a git repository' }
        $selfTestLog = Join-Path $script:SessionsDir "$(Get-Stamp)-main-engine-selftest.log"
        $selfTest = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $script:EngineDir 'tests\run-tests.ps1')`""
        if ((Invoke-Logged $selfTest $selfTestLog $null $null 5) -ne 0) { Stop-Night "engine self-tests failed (see $selfTestLog)" }
        Stop-OrphanWorkers
        Initialize-Integration
        Update-Overlay

        $mode = if ($script:PrMode) { "a PR per item into $($script:Base)" } else { "local merges into $($script:BaseRef)" }
        $until = if ($script:Deadline -lt [datetime]::MaxValue) { "until $($script:Deadline.ToString('ddd HH:mm'))" } else { 'until stopped' }
        Add-Report ''
        Add-Report "## Run $(Get-Date -Format 'HH:mm') - $until; $($script:Config.workers) workers; $mode"
        Add-Report ''
        Write-Log "daemon started for $($script:Config.name): $until, $mode, base $($script:BaseRef)"

        # [!] work left from earlier gets its resolver pass(es) first.
        if (-not $Task -and -not $UrgentOnly) {
            $fileTasks = Read-TaskList $script:TasksPath
            $fileBacklog = if (Test-Path $script:BacklogPath) { Read-TaskList $script:BacklogPath } else { @() }
            foreach ($t in @(@($fileTasks) + @($fileBacklog) | Where-Object { $_.Status -eq '!' })) {
                if (-not $script:Overlay.ContainsKey($t.Id)) { Add-ResolveForItem $t.Id }
            }
            foreach ($k in @($script:Overlay.Keys)) {
                if ($script:Overlay[$k].state -in @('failed', 'blocked', 'resolving')) {
                    if ($script:Overlay[$k].state -eq 'resolving') { Set-OverlayState $k 'failed' }
                    Add-ResolveForItem $k
                }
            }
        }

        while ($true) {
            try {
                $stopping = Test-Path $script:StopFile
                Update-Workers
                if (-not $stopping -and ((Get-Date) - $script:LastSync).TotalMinutes -ge 2 -and $script:Pending.Count -eq 0) { Sync-Integration; Update-Overlay }
                Read-Inbox
                Invoke-NextIntegration

                $draining = $stopping -or (Get-Date) -ge $script:Deadline -or ($Once -and $script:StartedJobs -ge 1)
                $paused = Test-Path $script:PauseFile
                $limit = Read-LimitState
                $limited = $limit -and (Get-Date) -lt [datetime]$limit.until
                $active = Test-InActiveHours $script:Config.schedule.activeHours (Get-Date)
                $started = 0
                if (-not $draining -and (-not $paused -or $UrgentOnly) -and -not $limited) {
                    $started += Start-ResolverJob
                    if ($active -and -not $UrgentOnly) { $started += Start-WorkJobs }
                }

                $busy = $script:Running.Count + $script:Pending.Count + $(if ($script:AwaitingPr) { 1 } else { 0 })
                if ($busy -eq 0 -and $started -eq 0) {
                    if ($draining) { break }
                    if ($UrgentOnly -and $script:ResolverQueue.Count -eq 0 -and -not @(Get-ChildItem $script:InboxDir -Filter '*.json' -File)) { break }
                    if ($Once -and $script:ResolverQueue.Count -eq 0) { Write-Log 'nothing to do'; break }
                    $why = if ($paused) { 'paused (nightshift resume)' } elseif ($limited) { "usage limit until $($limit.until)" } elseif (-not $active) { "outside active hours; next start $(Get-NextActiveStart $script:Config.schedule.activeHours (Get-Date))" } else { 'nothing to do' }
                    if (-not $idleLogged) {
                        Write-Log "idle: $why"
                        if ($why -eq 'nothing to do') { Add-Report "- [idle] $(Get-Date -Format HH:mm) nothing left to do; checking again every $($script:Config.schedule.idleMinutes) min"; Write-Summary }
                        $idleLogged = $true
                    }
                    Write-DaemonState "idle: $why"
                    # Sleep, but wake for a stop, your requests, or the next sync.
                    $wake = (Get-Date).AddMinutes($(if ($why -eq 'nothing to do') { [int]$script:Config.schedule.idleMinutes } else { 1 }))
                    while ((Get-Date) -lt $wake -and -not (Test-Path $script:StopFile) -and -not @(Get-ChildItem $script:InboxDir -Filter '*.json' -File)) { Start-Sleep -Seconds 10 }
                    $script:LastSync = [datetime]::MinValue
                    continue
                }
                $idleLogged = $false
                Write-DaemonState ''
                Start-Sleep -Seconds 10
            } catch {
                $msg = $_.Exception.Message
                if ($msg -like 'STOP_NIGHT:*') { throw }
                $n = [int]$loopCrashes[$msg] + 1
                $loopCrashes[$msg] = $n
                Write-Log "CRASH (loop, $n): $msg`n$($_.ScriptStackTrace)"
                Add-Report "- [crash] $(Get-ShortReason $msg) (see .nightshift/state/run.log); continuing"
                if ($n -eq 3) { Add-ResolverJob 'health' "crash-$((Get-Date).ToString('HHmmss'))" "The Night Shift daemon keeps failing with this error (3 times so far):`n$msg`n$($_.ScriptStackTrace)`nFind the cause in the repository or the environment and fix it. If the engine itself is wrong, say so under human." }
                try { Reset-IntegrateWorktree } catch { }
                $pause = @(1, 5, 15)[[Math]::Min($n, 3) - 1]
                $until = (Get-Date).AddMinutes($pause)
                while ((Get-Date) -lt $until -and -not (Test-Path $script:StopFile)) { Start-Sleep -Seconds 10 }
            }
        }
    } catch {
        $msg = $_.Exception.Message
        if ($msg -like 'STOP_NIGHT:*') {
            Write-Log $msg
            Add-Report "- [stop] $($msg.Substring(12).Trim())"
        } else {
            $exitCode = 1
            Write-Log "CRASH: $msg`n$($_.ScriptStackTrace)"
            Add-Report "- [crash] $msg (see .nightshift/state/run.log)"
        }
    } finally {
        try {
            if ($script:Running -and $script:Running.Count) {
                Write-Log "waiting for $($script:Running.Count) worker(s) to stop"
                foreach ($w in $script:Running.Values) { $w.Process.WaitForExit([int]$script:Config.agentTimeoutMinutes * 60000) | Out-Null }
            }
            if (Test-Path (Get-SlotPath 'integrate')) { Write-Summary }
            Write-DaemonState 'stopped'
        } catch { Write-Log "finalize failed: $($_.Exception.Message)" }
        [NightShift.Power]::SetThreadExecutionState([uint32]2147483648) | Out-Null
        Remove-Item $script:LockFile -ErrorAction SilentlyContinue
        if (Test-Path $script:StopFile) { Remove-Item $script:StopFile -Force }
        Write-Log 'daemon stopped'
    }
    return $exitCode
}
