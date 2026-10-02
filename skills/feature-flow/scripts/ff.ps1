<#
.SYNOPSIS
    feature-flow state helper. Deterministic parts of the workflow live here so the
    orchestrating model never has to "remember" state: work-folder creation, the event
    log, the mechanical gates, the round diff, and loop/send-back counting.

.DESCRIPTION
    Commands:
      init        Create work/<stamp>-<slug>/ with the standard layout; record the git base and settings.
      event       Append one line to events.log. Exit 3 on loop limit or send-back limit.
      check-todo  Gate for TODO items (see -Prefix, -AllowOpen, -FormatOnly).
      diff        Save the round diff vs the recorded base (tracked + untracked, work/ excluded).
      wiki-check  Verify docs/wiki/index.md exists and every relative .md link in docs/wiki resolves.
      status      Print stage, round/send-back counts, TODO progress and the next action.
      pick-model  Choose the subagent model alias for a role from stage, size, risk and failures.
      auto-check  Decide whether an unattended (scheduled) resume should run now; logs the auto RESUME itself.
      heartbeat   Touch <dir>/lock so a scheduled firing sees the run as active.
      verify      Run the spec build and test commands (-Build, -Test) for a round, save the full log, exit 1 if any fails.

    MaxRounds, MaxQaCycles and MaxModel are written to <dir>/settings.txt by init and read from
    there whenever a later call does not pass them, so every call (including scheduled firings)
    uses the same limits.

    Exit codes: 0 ok, 1 check failed, 2 usage/input error, 3 limit reached.
    ASCII-only on purpose: Windows PowerShell 5.1 misreads BOM-less UTF-8 scripts.
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("init", "event", "check-todo", "diff", "wiki-check", "status", "pick-model", "auto-check", "heartbeat", "verify")]
    [string]$Command,
    [ValidateSet("", "planner", "developer", "qa", "reviewer", "wiki")]
    [string]$Role = "",
    [ValidateSet("haiku", "sonnet", "opus", "fable", "inherit")]
    [string]$MaxModel = "fable",
    [ValidateSet("", "IMPL", "SPEC")]
    [string]$SendBack = "",
    [string]$Build = "",
    [string]$Test = "",
    [string]$Model = "",
    [string]$ReviewerModel = "",
    [int]$IdleMinutes = 45,
    [int]$MaxAutoPerDay = 3,
    [string]$Root = (Get-Location).Path,
    [string]$WorkDir,
    [string]$Title,
    [string]$Stage,
    [string]$Status,
    [int]$Round = 0,
    [string]$Note = "",
    [string]$Prefix = "",
    [switch]$AllowOpen,
    [switch]$FormatOnly,
    [int]$MaxRounds = 3,
    [int]$MaxQaCycles = 2
)

$ErrorActionPreference = "Stop"
$validStages = @("intake", "plan", "dev", "qa", "wiki", "done")
$validStatus = @("START", "PASS", "FAIL", "BLOCKED_ENV", "BLOCKED_PERMISSION", "NEEDS_DECISION", "LOOP_LIMIT", "PAUSE", "RESUME")
$haltStatus = @("BLOCKED_ENV", "BLOCKED_PERMISSION", "NEEDS_DECISION", "LOOP_LIMIT", "PAUSE")
$utf8 = New-Object System.Text.UTF8Encoding($false)
$BoundNames = @($PSBoundParameters.Keys)

function Import-WorkSettings {
    # 0. Limits come from <dir>/settings.txt unless the caller passed them explicitly.
    if ([string]::IsNullOrWhiteSpace($WorkDir)) { return }
    $dirPath = $WorkDir
    if (-not [System.IO.Path]::IsPathRooted($dirPath)) { $dirPath = Join-Path $Root $dirPath }
    $file = Join-Path $dirPath "settings.txt"
    if (-not (Test-Path -LiteralPath $file)) { return }
    foreach ($line in [System.IO.File]::ReadAllLines($file)) {
        $m = [regex]::Match($line, '^\s*(MaxRounds|MaxQaCycles|MaxModel)\s*=\s*(\S+)\s*$')
        if (-not $m.Success -or $script:BoundNames -contains $m.Groups[1].Value) { continue }
        switch ($m.Groups[1].Value) {
            "MaxRounds" { $script:MaxRounds = [int]$m.Groups[2].Value }
            "MaxQaCycles" { $script:MaxQaCycles = [int]$m.Groups[2].Value }
            "MaxModel" { if ($m.Groups[2].Value -in @("haiku", "sonnet", "opus", "fable", "inherit")) { $script:MaxModel = $m.Groups[2].Value } }
        }
    }
}

function Fail-Usage([string]$Message) {
    Write-Output "ERROR: $Message"
    exit 2
}

function Resolve-WorkDir {
    if ([string]::IsNullOrWhiteSpace($WorkDir)) { Fail-Usage "-WorkDir is required for '$Command'." }
    $candidate = $WorkDir
    if (-not [System.IO.Path]::IsPathRooted($candidate)) { $candidate = Join-Path $Root $candidate }
    if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { Fail-Usage "Work folder not found: $candidate" }
    return (Resolve-Path -LiteralPath $candidate).Path
}

function Invoke-Git([string[]]$GitArgs) {
    # 0. Run git in the project root as UTF-8 with unquoted paths, so non-ASCII names and content survive.
    $prev = $ErrorActionPreference
    $prevEnc = [Console]::OutputEncoding
    $ErrorActionPreference = "Continue"
    [Console]::OutputEncoding = $utf8
    try { $out = & git -C $Root -c core.quotePath=false @GitArgs 2>$null; $code = $LASTEXITCODE }
    finally { [Console]::OutputEncoding = $prevEnc; $ErrorActionPreference = $prev }
    return [pscustomobject]@{ Out = @($out); Code = $code }
}

function Read-Events([string]$Dir) {
    $log = Join-Path $Dir "events.log"
    $events = @()
    if (-not (Test-Path -LiteralPath $log)) { return $events }
    foreach ($line in [System.IO.File]::ReadAllLines($log)) {
        $parts = $line -split '\s\|\s'
        if ($parts.Count -lt 4) { continue }
        $events += [pscustomobject]@{ Time = $parts[0]; Stage = $parts[1]; Status = $parts[2]; Round = $parts[3]; Note = ($(if ($parts.Count -ge 5) { $parts[4] } else { "" })) }
    }
    return $events
}

function Test-UserResume($E) {
    # 0. Only a RESUME whose note starts with "user" resets counters; "auto" or any other note never does.
    return ($E.Status -eq "RESUME" -and $E.Note -match '^user')
}

function Get-FailCount([object[]]$Events, [string]$ForStage) {
    # 0. Count FAILs for the stage since its last START/PASS or user RESUME; send-backs are counted separately.
    $count = 0
    foreach ($e in $Events) {
        if (Test-UserResume $e) { $count = 0; continue }
        if ($e.Stage -ne $ForStage) { continue }
        if ($e.Status -eq "FAIL" -and $e.Note -notmatch '^sendback=') { $count++ }
        elseif ($e.Status -in @("START", "PASS")) { $count = 0 }
    }
    return $count
}

function Get-SendBackCount([object[]]$Events) {
    # 0. QA send-backs (qa FAIL with note "sendback=...") since the last user RESUME.
    $count = 0
    foreach ($e in $Events) {
        if (Test-UserResume $e) { $count = 0 }
        elseif ($e.Stage -eq "qa" -and $e.Status -eq "FAIL" -and $e.Note -match '^sendback=') { $count++ }
    }
    return $count
}

function Get-MaxRound([object[]]$Events, [string]$ForStage) {
    # 0. Round numbers never restart inside a work folder, so files like diff-r<N>.patch are never overwritten.
    $max = 0
    foreach ($e in $Events) {
        if ($e.Stage -ne $ForStage) { continue }
        $m = [regex]::Match($e.Round, '^r(\d+)$')
        if ($m.Success -and [int]$m.Groups[1].Value -gt $max) { $max = [int]$m.Groups[1].Value }
    }
    return $max
}

function Get-TodoItems([string]$Dir) {
    $todo = Join-Path $Dir "02-todo.md"
    if (-not (Test-Path -LiteralPath $todo)) { return $null }
    $items = @()
    $current = $null
    foreach ($line in [System.IO.File]::ReadAllLines($todo)) {
        $m = [regex]::Match($line, '^\s*-\s*\[( |x|X)\]\s*([A-Za-z]+\d+)\s*[:.)-]?\s*(.*)$')
        if ($m.Success) {
            $current = [pscustomobject]@{ Id = $m.Groups[2].Value; Checked = ($m.Groups[1].Value -ne " "); Text = $m.Groups[3].Value; HasEvidenceLine = $false; Evidence = "" }
            $items += $current
            continue
        }
        if ($null -ne $current) {
            $ev = [regex]::Match($line, '^\s+-?\s*evidence\s*:\s*(.*)$', 'IgnoreCase')
            if ($ev.Success) { $current.HasEvidenceLine = $true; $current.Evidence = $ev.Groups[1].Value.Trim() }
        }
    }
    return $items
}

function Get-NextAction([object[]]$Events) {
    # 0. Next action, so a resumed, scheduled or weak orchestrator does not have to infer it.
    if ($Events.Count -eq 0) { return "intake: interview and spec approval" }

    # 1. RESUME events are markers, not progress: decide from the last real event, and let a
    #    user RESUME after it lift a halt (block, decision, loop limit, pause).
    $idx = $Events.Count - 1
    $resumedByUser = $false
    while ($idx -ge 0 -and $Events[$idx].Status -eq "RESUME") {
        if (Test-UserResume $Events[$idx]) { $resumedByUser = $true }
        $idx--
    }
    if ($idx -lt 0) { return "intake: interview and spec approval" }
    $last = $Events[$idx]
    $order = @("intake", "plan", "dev", "qa", "wiki", "done")
    $fails = Get-FailCount -Events $Events -ForStage $last.Stage
    $nextRound = (Get-MaxRound -Events $Events -ForStage $last.Stage) + 1
    $wait = "; wait for the user, then resume"
    if ($last.Status -in $haltStatus) {
        if ($resumedByUser) {
            # 2. A user RESUME lifts the halt: continue as if the halt never happened, from the last
            #    real event before it (so a PASS, a QA send-back or intake keep their meaning), with
            #    the user's RESUME applied so counters are reset; round numbers keep counting up.
            $j = $idx - 1
            while ($j -ge 0 -and ($Events[$j].Status -eq "RESUME" -or $Events[$j].Status -in $haltStatus)) { $j-- }
            if ($j -lt 0) { return "intake: interview and spec approval" }
            $r = Get-NextAction (@($Events[0..$j]) + @($Events[$Events.Count - 1]))
            if ($r -match '^(\w+) round \d+$') { return "$($Matches[1]) round $((Get-MaxRound -Events $Events -ForStage $Matches[1]) + 1)" }
            return $r
        }
        if ($last.Status -eq "PAUSE") { return "paused$wait" }
        return "escalated ($($last.Status))$wait"
    }
    switch ($last.Status) {
        "PASS" {
            if ($last.Stage -eq "wiki") { return "done PASS (log it, delete the schedule, report)" }
            $i = [array]::IndexOf($order, $last.Stage)
            if ($i -lt $order.Count - 2) { return "$($order[$i + 1]) START" }
            return "finished"
        }
        "FAIL" {
            if ($last.Note -match '^sendback=(IMPL|SPEC)') {
                $kind = $Matches[1]
                if ((Get-SendBackCount $Events) -gt $MaxQaCycles) { return "escalated (QA send-back limit)$wait" }
                if ($kind -eq "IMPL") { return "dev START (QA send-back; fix list = latest reviews/qa-r*.md)" }
                return "plan START (QA send-back; fix list = latest reviews/qa-r*.md)"
            }
            if ($fails -ge $MaxRounds) { return "escalated (loop limit)$wait" }
            return "$($last.Stage) round $nextRound"
        }
        "START" {
            if ($last.Stage -eq "intake") { return "intake: interview and spec approval" }
            return "$($last.Stage) round $nextRound"
        }
    }
    return "escalated ($($last.Status))$wait"
}

function Get-PickedModel([string]$ForRole, [string]$ForStage, [object[]]$Events, [string]$Risk, [int]$DCount) {
    # 0. Base model per role: start cheap, strengthen for high-risk work.
    $tiers = @("haiku", "sonnet", "opus", "fable")
    $reasons = @("risk=$Risk")
    switch ($ForRole) {
        "planner" { $base = $(if ($Risk -eq "high") { "fable" } else { "opus" }) }
        "developer" {
            if ($Risk -eq "high") { $base = "opus" }
            elseif ($DCount -ge 1 -and $DCount -le 3) { $base = "sonnet" }
            else { $base = "opus" }
            $reasons += "D=$DCount"
        }
        "qa" { $base = $(if ($Risk -eq "high") { "opus" } else { "sonnet" }) }
        "wiki" { $base = "sonnet" }
        "reviewer" { $base = $(if ($Risk -eq "high") { "opus" } else { "sonnet" }) }
    }
    $want = [array]::IndexOf($tiers, $base)

    # 1. Workers go one tier up after 2 FAILs in their stage, the developer also after a QA IMPL send-back
    #    (since the last user RESUME). The reviewer is never weaker than the worker it judges.
    if ($ForRole -ne "reviewer") {
        $fails = Get-FailCount -Events $Events -ForStage $ForStage
        if ($fails -ge 2) { $want++; $reasons += "fails=$fails" }
        if ($ForRole -eq "developer") {
            $impl = 0
            foreach ($e in $Events) {
                if (Test-UserResume $e) { $impl = 0 }
                elseif ($e.Status -eq "FAIL" -and $e.Note -match '^sendback=IMPL') { $impl++ }
            }
            if ($impl -ge 1) { $want++; $reasons += "qa-sendback" }
        }
    }
    else {
        $workerRole = @{ plan = "planner"; dev = "developer"; qa = "qa"; wiki = "wiki" }[$ForStage]
        $worker = Get-PickedModel -ForRole $workerRole -ForStage $ForStage -Events $Events -Risk $Risk -DCount $DCount
        $workerIndex = [array]::IndexOf($tiers, $worker.Model)
        if ($workerIndex -gt $want) { $want = $workerIndex; $reasons += "match worker ($($worker.Model))" }
    }

    # 2. Cap at MAX_MODEL and say exactly what happened.
    $cap = [array]::IndexOf($tiers, $MaxModel)
    $baseIndex = [array]::IndexOf($tiers, $base)
    $final = [Math]::Min($want, $cap)
    if ($final -gt $baseIndex) { $reasons += "escalated from $base" }
    if ($want -gt $cap) { $reasons += "capped at $MaxModel" }
    return [pscustomobject]@{ Model = $tiers[$final]; Reasons = $reasons }
}

function Get-RiskLevel([string]$Dir) {
    # 0. "## Risk" section, "- level: high|normal|low"; anything missing or unknown counts as normal.
    $spec = Join-Path $Dir "01-spec.md"
    if (-not (Test-Path -LiteralPath $spec)) { return "normal" }
    $m = [regex]::Match([System.IO.File]::ReadAllText($spec), '(?im)^\s*-?\s*level\s*:\s*(high|normal|low)\b')
    if ($m.Success) { return $m.Groups[1].Value.ToLowerInvariant() }
    return "normal"
}

function Parse-EventTime([string]$Text) {
    $t = [datetime]::MinValue
    if ([datetime]::TryParseExact($Text, "yyyy-MM-ddTHH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$t)) { return $t }
    return $null
}

function Resolve-InProject([string]$Rel, [string]$Dir) {
    # 0. "evidence/..." always means the work folder; a copy written to the project root does not count.
    $bases = @($Root, $Dir)
    if ($Rel -match '^evidence[\\/]') { $bases = @($Dir) }
    foreach ($base in $bases) {
        $p = $Rel
        if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $base $Rel }
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    return $null
}

function Test-EvidenceRef([string]$Token, [string]$Dir) {
    # 0. Returns $null when the token is prose, "" when it is a valid ref, or a problem string.
    $m = [regex]::Match($Token, '^(?<path>[^:*?"<>|\s]+?\.[A-Za-z][A-Za-z0-9]*)(:(?<start>\d+)(-(?<end>\d+))?)?$')
    if (-not $m.Success) { return $null }
    $rel = $m.Groups["path"].Value
    $explicit = ($rel -match '[\\/]') -or $m.Groups["start"].Success
    $resolved = Resolve-InProject -Rel $rel -Dir $Dir

    # 1. A bare name without folder or line is only a ref when it exists; otherwise treat it as prose.
    if ($null -eq $resolved) {
        if ($explicit) { return "missing file: $rel" }
        return $null
    }
    if ($m.Groups["start"].Success) {
        $lineCount = [System.IO.File]::ReadAllLines($resolved).Length
        $last = [int]$m.Groups["start"].Value
        if ($m.Groups["end"].Success) { $last = [int]$m.Groups["end"].Value }
        if ($last -gt $lineCount) { return "line $last beyond end of $rel ($lineCount lines)" }
        if ($m.Groups["end"].Success -and [int]$m.Groups["end"].Value -lt [int]$m.Groups["start"].Value) { return "range $($m.Groups['start'].Value)-$($m.Groups['end'].Value) is reversed in $rel" }
    }
    return ""
}

Import-WorkSettings

switch ($Command) {
    "init" {
        if ([string]::IsNullOrWhiteSpace($Title)) { Fail-Usage "-Title is required for init." }
        $slug = ([regex]::Replace($Title.ToLowerInvariant(), '[^\p{L}\p{Nd}]+', '-')).Trim('-')
        if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40).Trim('-') }
        if ([string]::IsNullOrWhiteSpace($slug)) { $slug = "task" }
        $dir = Join-Path $Root ("work\" + (Get-Date -Format "yyyyMMdd-HHmm") + "-" + $slug)
        if (Test-Path -LiteralPath $dir) { Fail-Usage "Work folder already exists: $dir" }

        # 0. Standard layout; every hand-off between stages is a file in here.
        foreach ($sub in @("reviews", "evidence\dev", "evidence\qa", "raw")) {
            New-Item -ItemType Directory -Force -Path (Join-Path $dir $sub) | Out-Null
        }

        # 1. Record the git base so round diffs contain only this work item's changes.
        $git = Invoke-Git @("rev-parse", "--is-inside-work-tree")
        $base = "none"
        if ($git.Code -eq 0) {
            $head = Invoke-Git @("rev-parse", "HEAD")
            if ($head.Code -eq 0) { $base = $head.Out[0] } else { $base = "4b825dc642cb6eb9a060e54bf8d69288fbee4904" }
            $dirty = Invoke-Git @("status", "--porcelain", "--", ".", ":(exclude)work")
            if (@($dirty.Out | Where-Object { $_ }).Count -gt 0) { Write-Output "WARN: uncommitted changes exist; they will appear in round diffs. Commit or stash first." }
            $ignored = Invoke-Git @("check-ignore", "-q", "work/x")
            if ($ignored.Code -ne 0) { Write-Output "WARN: work/ is not in .gitignore." }
        }
        else { Write-Output "WARN: not a git repository; 'diff' will not work. Ask the user to git init." }
        [System.IO.File]::WriteAllText((Join-Path $dir "base.txt"), $base, $utf8)

        $context = "# Project context (seed)`n`n- Build command:`n- Test command:`n- Run/launch:`n- Key folders:`n- Conventions (from CLAUDE.md/AGENTS.md):`n- Wiki index: docs/wiki/index.md`n"
        $spec = "# Spec: $Title`n`n## Goal`n`n## In scope`n`n## Out of scope`n`n## Constraints / cautions`n`n## Acceptance criteria`n`n## Verify commands`n- build:`n- test:`n`n## Risk`n- level: normal`n"
        [System.IO.File]::WriteAllText((Join-Path $dir "00-context.md"), $context, $utf8)
        [System.IO.File]::WriteAllText((Join-Path $dir "01-spec.md"), $spec, $utf8)
        [System.IO.File]::WriteAllText((Join-Path $dir "events.log"), "", $utf8)
        $settings = "MaxRounds=$MaxRounds`nMaxQaCycles=$MaxQaCycles`nMaxModel=$MaxModel`n"
        [System.IO.File]::WriteAllText((Join-Path $dir "settings.txt"), $settings, $utf8)
        Write-Output "SETTINGS  MaxRounds=$MaxRounds MaxQaCycles=$MaxQaCycles MaxModel=$MaxModel"
        Write-Output "WORKDIR   $dir"
        exit 0
    }

    "event" {
        $dir = Resolve-WorkDir
        if ($Stage -notin $validStages) { Fail-Usage "-Stage must be one of: $($validStages -join ', ')" }
        if ($Status -notin $validStatus) { Fail-Usage "-Status must be one of: $($validStatus -join ', ')" }
        $clean = (($Note -replace '[\r\n|]+', ' ') -replace '\s+', ' ').Trim()
        if ($SendBack) {
            if ($Status -ne "FAIL" -or $Stage -ne "qa") { Fail-Usage "-SendBack is only valid with -Stage qa -Status FAIL." }
            $clean = ("sendback=$SendBack $clean").Trim()
        }
        if ($Model) { $clean = ("$clean [model=$Model]").Trim() }
        if ($ReviewerModel) { $clean = ("$clean [reviewer=$ReviewerModel]").Trim() }
        $line = "{0} | {1} | {2} | r{3} | {4}" -f (Get-Date -Format "yyyy-MM-ddTHH:mm:ss"), $Stage, $Status, $Round, $clean
        [System.IO.File]::AppendAllText((Join-Path $dir "events.log"), $line + "`n", $utf8)
        Write-Output $line

        # 1. Loop guards: the orchestrator must stop and escalate when either trips.
        $events = @(Read-Events $dir)
        if ($Status -eq "FAIL" -and $clean -match '^sendback=') {
            $sendBacks = Get-SendBackCount $events
            if ($sendBacks -gt $MaxQaCycles) {
                Write-Output "LOOP_LIMIT: QA sent work back $sendBacks time(s) (max $MaxQaCycles). Stop and escalate to the user."
                exit 3
            }
            exit 0
        }
        $fails = Get-FailCount -Events $events -ForStage $Stage
        if ($Status -eq "FAIL" -and $fails -ge $MaxRounds) {
            Write-Output "LOOP_LIMIT: stage '$Stage' failed $fails time(s) (max $MaxRounds). Stop and escalate to the user."
            exit 3
        }
        exit 0
    }

    "check-todo" {
        $dir = Resolve-WorkDir
        $items = Get-TodoItems $dir
        if ($null -eq $items) { Fail-Usage "02-todo.md not found in $dir" }

        # 0. -FormatOnly: plan-stage gate. Needs D and Q items, unique IDs, an evidence line each.
        if ($FormatOnly) {
            $bad = 0
            if (@($items | Where-Object { $_.Id -like "D*" }).Count -eq 0) { Write-Output "FORMAT    no D items"; $bad++ }
            if (@($items | Where-Object { $_.Id -like "Q*" }).Count -eq 0) { Write-Output "FORMAT    no Q items"; $bad++ }
            foreach ($dup in ($items | Group-Object Id | Where-Object { $_.Count -gt 1 })) { Write-Output "FORMAT    duplicate id $($dup.Name)"; $bad++ }
            foreach ($item in $items) { if (-not $item.HasEvidenceLine) { Write-Output "FORMAT    $($item.Id) has no '  - evidence:' line"; $bad++ } }
            Write-Output ("SUMMARY   {0} item(s), {1} problem(s)" -f $items.Count, $bad)
            if ($bad -gt 0) { exit 1 }
            exit 0
        }

        if ($Prefix) { $items = @($items | Where-Object { $_.Id -like "$Prefix*" }) }
        if ($items.Count -eq 0) { Fail-Usage "No TODO items found (prefix '$Prefix'). Expected lines like '- [ ] D1: ...'." }

        $bad = 0
        foreach ($item in $items) {
            if (-not $item.Checked) {
                # 1. -AllowOpen (QA gate): an open item is acceptable only with a proof file, so the reviewer can judge CAUSE.
                if ($AllowOpen) {
                    $proof = @(Get-ChildItem -LiteralPath (Join-Path $dir "evidence\qa") -Filter "$($item.Id)-*" -File -ErrorAction SilentlyContinue)
                    if ($proof.Count -gt 0) { Write-Output "OPEN-OK   $($item.Id)  failing, proof: $($proof[0].Name)"; continue }
                    Write-Output "OPEN      $($item.Id)  unchecked and no evidence/qa/$($item.Id)-* proof file"; $bad++; continue
                }
                Write-Output "OPEN      $($item.Id)  $($item.Text)"; $bad++; continue
            }
            if (-not $item.HasEvidenceLine) { Write-Output "NO-EVID   $($item.Id)  checked without an 'evidence:' line"; $bad++; continue }
            if ([string]::IsNullOrWhiteSpace($item.Evidence)) { Write-Output "NO-EVID   $($item.Id)  checked but the 'evidence:' line is empty"; $bad++; continue }

            # 2. At least one token must be a verifiable file ref; every explicit file ref must resolve.
            $refs = 0; $problems = @()
            foreach ($token in ($item.Evidence -split '[|;,\s]+')) {
                $t = $token.Trim().Trim('`').TrimStart('(', '[').TrimEnd('.', ',', ')', ']', ':')
                if (-not $t) { continue }
                $result = Test-EvidenceRef -Token $t -Dir $dir
                if ($null -eq $result) { continue }
                $refs++
                if ($result) { $problems += $result }
            }
            if ($problems.Count -gt 0) { Write-Output "BAD-REF   $($item.Id)  $($problems -join '; ')"; $bad++ }
            elseif ($refs -eq 0) { Write-Output "NO-REF    $($item.Id)  evidence has no file ref (path or path:line)"; $bad++ }
            else { Write-Output "OK        $($item.Id)" }
        }
        Write-Output ("SUMMARY   {0} item(s), {1} problem(s)" -f $items.Count, $bad)
        if ($bad -gt 0) { exit 1 }
        exit 0
    }

    "diff" {
        $dir = Resolve-WorkDir
        if ($Round -lt 1) { Fail-Usage "-Round <N> is required for diff." }
        $baseFile = Join-Path $dir "base.txt"
        $base = if (Test-Path -LiteralPath $baseFile) { ([System.IO.File]::ReadAllText($baseFile)).Trim() } else { "none" }
        if ($base -eq "none") { Fail-Usage "No git base recorded (not a git repository at init). Treat as BLOCKED_ENV." }

        # 0. Tracked changes vs base, then each untracked file as a new-file diff; work/ is always excluded.
        $parts = New-Object System.Collections.Generic.List[string]
        $tracked = Invoke-Git @("diff", $base, "--", ".", ":(exclude)work")
        if ($tracked.Code -ne 0) { Fail-Usage "git diff failed against base $base" }
        foreach ($l in $tracked.Out) { $parts.Add([string]$l) }
        $untracked = Invoke-Git @("ls-files", "--others", "--exclude-standard", "--", ".", ":(exclude)work")
        foreach ($f in ($untracked.Out | Where-Object { $_ })) {
            $nd = Invoke-Git @("diff", "--no-index", "--", "/dev/null", $f)
            foreach ($l in $nd.Out) { $parts.Add([string]$l) }
        }
        $outFile = Join-Path $dir ("evidence\dev\diff-r{0}.patch" -f $Round)
        [System.IO.File]::WriteAllText($outFile, (($parts -join "`n") + "`n"), $utf8)
        Write-Output ("DIFF      {0} ({1} untracked file(s))" -f $outFile, @($untracked.Out | Where-Object { $_ }).Count)

        # 1. Line-ending rewrites: files whose diff shrinks when CR at EOL is ignored were re-saved with other line endings.
        $plain = @{}
        foreach ($l in (Invoke-Git @("diff", "--numstat", $base, "--", ".", ":(exclude)work")).Out) {
            $c = ([string]$l) -split "`t"
            if ($c.Count -ge 3 -and $c[0] -match '^\d+$') { $plain[$c[2]] = [int]$c[0] + [int]$c[1] }
        }
        $eolFiles = @()
        $ignoring = @{}
        foreach ($l in (Invoke-Git @("diff", "--numstat", "--ignore-cr-at-eol", $base, "--", ".", ":(exclude)work")).Out) {
            $c = ([string]$l) -split "`t"
            if ($c.Count -ge 3 -and $c[0] -match '^\d+$') { $ignoring[$c[2]] = [int]$c[0] + [int]$c[1] }
        }
        foreach ($file in $plain.Keys) {
            $without = 0
            if ($ignoring.ContainsKey($file)) { $without = $ignoring[$file] }
            if ($plain[$file] - $without -ge 4) { $eolFiles += $file }
        }
        if ($eolFiles.Count -gt 0) {
            foreach ($file in ($eolFiles | Sort-Object)) { Write-Output "EOL       $file  line endings rewritten (diff $($plain[$file]) lines, $(if ($ignoring.ContainsKey($file)) { $ignoring[$file] } else { 0 }) without CR changes)" }
            Write-Output "GATE      FAIL  restore the original line endings of the files above"
            exit 1
        }
        exit 0
    }

    "wiki-check" {
        $wiki = Join-Path $Root "docs\wiki"
        $index = Join-Path $wiki "index.md"
        if (-not (Test-Path -LiteralPath $index)) { Write-Output "MISSING   docs/wiki/index.md"; exit 1 }
        $bad = 0; $pages = 0
        foreach ($page in (Get-ChildItem -LiteralPath $wiki -Filter "*.md" -File -Recurse)) {
            $pages++
            # 0. Ignore fenced code; collect inline links (optional <...> and "title") and reference definitions.
            $text = [regex]::Replace([System.IO.File]::ReadAllText($page.FullName), '(?ms)^\s*```.*?^\s*```', '')
            $targets = @()
            foreach ($m in [regex]::Matches($text, '\]\(\s*<?([^)>\s]+?\.md)(#[^)>\s]*)?>?(\s+"[^"]*")?\s*\)')) { $targets += $m.Groups[1].Value }
            foreach ($m in [regex]::Matches($text, '(?m)^\s*\[[^\]]+\]:\s*<?([^>\s]+?\.md)(#\S*)?>?')) { $targets += $m.Groups[1].Value }
            foreach ($raw in $targets) {
                if ($raw -match '^[a-z]+://') { continue }
                $target = [uri]::UnescapeDataString($raw)
                $full = if ($target.StartsWith("/")) { Join-Path $Root $target.TrimStart("/") } else { Join-Path $page.DirectoryName $target }
                if (-not (Test-Path -LiteralPath $full)) {
                    Write-Output "BROKEN    $($page.FullName.Substring($Root.Length).TrimStart('\')) -> $raw"; $bad++
                }
            }
        }
        Write-Output ("SUMMARY   {0} page(s), {1} broken link(s)" -f $pages, $bad)
        if ($bad -gt 0) { exit 1 }
        exit 0
    }

    "status" {
        $dir = Resolve-WorkDir
        $events = @(Read-Events $dir)
        Write-Output "WORKDIR   $dir"
        if ($events.Count -eq 0) { Write-Output "STAGE     (no events yet)"; Write-Output "NEXT      intake"; exit 0 }
        $last = $events[$events.Count - 1]
        $fails = Get-FailCount -Events $events -ForStage $last.Stage
        Write-Output "STAGE     $($last.Stage)  last=$($last.Status) $($last.Round)"
        Write-Output "FAILS     $fails since last PASS/START/user RESUME (max $MaxRounds)"
        Write-Output "SENDBACKS $(Get-SendBackCount $events) (max $MaxQaCycles)"
        $items = Get-TodoItems $dir
        if ($null -ne $items) {
            foreach ($p in @("D", "Q")) {
                $group = @($items | Where-Object { $_.Id -like "$p*" })
                if ($group.Count -gt 0) { Write-Output ("TODO-{0}    {1}/{2} checked" -f $p, @($group | Where-Object { $_.Checked }).Count, $group.Count) }
            }
        }

        Write-Output "NEXT      $(Get-NextAction $events)"
        Write-Output "RECENT"
        $events | Select-Object -Last 5 | ForEach-Object { Write-Output "  $($_.Time) $($_.Stage) $($_.Status) $($_.Round) $($_.Note)" }
        exit 0
    }

    "pick-model" {
        $dir = Resolve-WorkDir
        if (-not $Role) { Fail-Usage "-Role is required for pick-model (planner, developer, qa, reviewer, wiki)." }
        $stageOfRole = @{ planner = "plan"; developer = "dev"; qa = "qa"; wiki = "wiki"; reviewer = $Stage }
        $forStage = $stageOfRole[$Role]
        if ($Role -eq "reviewer" -and $forStage -notin @("plan", "dev", "qa", "wiki")) { Fail-Usage "-Stage (plan, dev, qa, wiki) is required for the reviewer." }
        $items = Get-TodoItems $dir
        $dCount = 0
        if ($null -ne $items) { $dCount = @($items | Where-Object { $_.Id -like "D*" }).Count }
        if ($MaxModel -eq "inherit") {
            # 0. Gateways that do not map every alias (or one model for all): do not pass a model at all.
            Write-Output "MODEL     inherit"
            Write-Output "REASON    MaxModel=inherit; omit the Agent call's model parameter"
            exit 0
        }
        $pick = Get-PickedModel -ForRole $Role -ForStage $forStage -Events @(Read-Events $dir) -Risk (Get-RiskLevel $dir) -DCount $dCount
        Write-Output "MODEL     $($pick.Model)"
        Write-Output "REASON    $($pick.Reasons -join ', ')"
        exit 0
    }

    "heartbeat" {
        $dir = Resolve-WorkDir
        [System.IO.File]::WriteAllText((Join-Path $dir "lock"), (Get-Date -Format "yyyy-MM-ddTHH:mm:ss"), $utf8)
        Write-Output "HEARTBEAT $dir"
        exit 0
    }

    "verify" {
        $dir = Resolve-WorkDir
        if ($Stage -notin @("dev", "qa")) { Fail-Usage "-Stage dev or qa is required for verify." }
        if ($Round -lt 1) { Fail-Usage "-Round <N> is required for verify." }
        $commands = @(@($Build, $Test) | Where-Object { $_ -and $_.Trim() -and $_.Trim() -ne "none" })
        if ($commands.Count -eq 0) { Fail-Usage "-Build and/or -Test (spec Verify commands) are required for verify." }

        # 0. Run each command through cmd.exe from the project root; the log and exit codes decide, not a model.
        $log = Join-Path $dir ("evidence\{0}\verify-r{1}.log" -f $Stage, $Round)
        $text = New-Object System.Text.StringBuilder
        $failed = 0
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        Push-Location -LiteralPath $Root
        try {
            foreach ($c in $commands) {
                $out = & cmd.exe /d /c "$c 2>&1"
                $code = $LASTEXITCODE
                [void]$text.AppendLine("### $c")
                foreach ($l in @($out)) { [void]$text.AppendLine([string]$l) }
                [void]$text.AppendLine("EXIT $code")
                [void]$text.AppendLine("")
                $verdict = $(if ($code -eq 0) { "PASS" } else { "FAIL" })
                if ($code -ne 0) { $failed++ }
                Write-Output ("VERIFY    {0}  exit {1}  {2}" -f $verdict, $code, $c)
            }
        }
        finally { Pop-Location; $ErrorActionPreference = $prevEap }
        [System.IO.File]::WriteAllText($log, $text.ToString(), $utf8)
        Write-Output "LOG       $log"
        if ($failed -gt 0) { Write-Output "GATE      FAIL  $failed command(s) failed"; exit 1 }
        exit 0
    }

    "auto-check" {
        $dir = Resolve-WorkDir
        $events = @(Read-Events $dir)
        Write-Output "WORKDIR   $dir"
        $deleteSchedule = "delete the schedule (CronDelete the id in schedule.txt, then delete schedule.txt); do nothing else"
        if ($events.Count -eq 0) { Write-Output "DECISION  STOP  no events yet; intake needs the user"; Write-Output "ACTION    $deleteSchedule"; exit 0 }
        $next = Get-NextAction $events

        # 0. Never resume what needs a human: unfinished intake, escalations, pause, limits, or a finished run.
        $stopReason = $null
        if ($next -eq "finished") { $stopReason = "finished" }
        elseif ($next -like "intake*") { $stopReason = "spec not approved yet; intake needs the user" }
        elseif ($next -like "escalated*" -or $next -like "paused*") { $stopReason = $next }
        if ($stopReason) { Write-Output "DECISION  STOP  $stopReason"; Write-Output "ACTION    $deleteSchedule"; exit 0 }

        # 1. Cap unattended resumes per 24h (any RESUME not marked "user" counts) so a broken run cannot burn the budget.
        $since = (Get-Date).AddHours(-24)
        $autoCount = @($events | Where-Object { $_.Status -eq "RESUME" -and $_.Note -notmatch '^user' -and ($t = Parse-EventTime $_.Time) -and $t -gt $since }).Count
        if ($autoCount -ge $MaxAutoPerDay) {
            Write-Output "DECISION  LIMIT  $autoCount automatic resumes in 24h (max $MaxAutoPerDay)"
            Write-Output "ACTION    delete the schedule (CronDelete the id in schedule.txt, then delete schedule.txt); write a short report for the user (what stage, why it keeps stopping); stop"
            exit 0
        }

        # 2. Recent activity (event log or master heartbeat) means the run is still going, here or in another session.
        $last = $events[$events.Count - 1]
        $lastTime = Parse-EventTime $last.Time
        foreach ($f in @("events.log", "lock")) {
            $path = Join-Path $dir $f
            if (Test-Path -LiteralPath $path) {
                $mtime = (Get-Item -LiteralPath $path).LastWriteTime
                if ($null -eq $lastTime -or $mtime -gt $lastTime) { $lastTime = $mtime }
            }
        }
        $idle = [int]((Get-Date) - $lastTime).TotalMinutes
        if ($idle -lt $IdleMinutes) { Write-Output "DECISION  WAIT  last activity $idle min ago (< $IdleMinutes)"; Write-Output "ACTION    do nothing"; exit 0 }

        # 3. Resume: log the auto RESUME here so the decision and the record cannot drift apart.
        $realStage = ($events | Where-Object { $_.Status -ne "RESUME" } | Select-Object -Last 1).Stage
        if (-not $realStage) { $realStage = $last.Stage }
        $line = "{0} | {1} | RESUME | r0 | auto idle={2}min" -f (Get-Date -Format "yyyy-MM-ddTHH:mm:ss"), $realStage, $idle
        [System.IO.File]::AppendAllText((Join-Path $dir "events.log"), $line + "`n", $utf8)
        Write-Output "DECISION  RESUME  idle $idle min; auto resumes in 24h: $($autoCount + 1)/$MaxAutoPerDay (logged)"
        Write-Output "NEXT      $next"
        Write-Output "ACTION    print '[feature-flow] auto resume of $dir', continue from NEXT without asking the user; tell the worker the previous round was interrupted and to inspect the current diff first"
        exit 0
    }
}
