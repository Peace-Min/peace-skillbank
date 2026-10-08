<#
.SYNOPSIS
    feature-flow state helper. Deterministic parts of the workflow live here so the
    orchestrating model never has to "remember" state: work-folder creation, the event
    log, the mechanical gates, the round diff, and loop/send-back counting.

.DESCRIPTION
    Commands:
      init        Create work/<stamp>-<slug>/ with the standard layout; record the git base and settings
                  (<Root>/.claude/feature-flow-settings.txt, if present, overrides the passed values).
      event       Append one line to events.log. Exit 3 on loop limit or send-back limit.
      check-todo  Gate for TODO items (see -Prefix, -AllowOpen, -FormatOnly; Q method lines, [regression], [fix]).
      diff        Save the round diff vs the recorded base (tracked + untracked, work/ excluded).
      wiki-check  Verify docs/wiki/index.md exists and every relative .md link in docs/wiki resolves.
      status      Print stage, round/send-back counts, TODO progress and the next action.
      pick-model  Choose the subagent model alias for a role from stage, size, risk and failures.
      auto-check  Decide whether an unattended (scheduled) resume should run now; logs the auto RESUME itself.
      heartbeat   Touch <dir>/lock so a scheduled firing sees the run as active.
      verify      Run the spec build, test and ui-test commands (-Build, -Test) for a round, each with a
                  timeout (VerifyTimeoutMin), save the full log, exit 1 if any fails or times out.
      manual-check  Check evidence/qa/manual-checklist.md: every "### Q<n>" item names the automation tried.
      proposed-check  Gate step: the round's saved worker reply exists, and every DECISIONS-PROPOSED entry
                  in it is recorded in the spec's "## Decisions" (so open choices a worker made get reviewed).
      gate        Run the whole mechanical gate of a stage round; on failure write the review file and log FAIL.
      merge-evidence  Fold evidence/dev/group-*.md (parallel developers) into 02-todo.md.
      decision    Append a master-decided / master-created / user entry to the spec's "## Decisions" and log DECIDED.

    MaxRounds, MaxGateFails, MaxQaCycles, MaxFixes, MaxDecisions, MaxModel and VerifyTimeoutMin are written to <dir>/settings.txt by init and read from
    there whenever a later call does not pass them, so every call (including scheduled firings)
    uses the same limits.

    Exit codes: 0 ok, 1 check failed, 2 usage/input error, 3 limit reached.
    ASCII-only on purpose: Windows PowerShell 5.1 misreads BOM-less UTF-8 scripts.
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("init", "event", "check-todo", "diff", "wiki-check", "status", "pick-model", "auto-check", "heartbeat", "verify", "gate", "merge-evidence", "decision", "manual-check", "proposed-check")]
    [string]$Command,
    [ValidateSet("", "planner", "developer", "qa", "reviewer", "second", "wiki")]
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
    [switch]$FromSpec,
    [int]$MaxRounds = 3,
    [int]$MaxGateFails = 3,
    [int]$MaxQaCycles = 2,
    [int]$MaxFixes = 1,
    [int]$MaxDecisions = 5,
    [double]$VerifyTimeoutMin = 20,
    [int]$MaxStageRounds = 6,
    [ValidateSet("", "decided", "created", "user", "upheld")]
    [string]$Kind = "",
    [string]$Overrides = ""
)

$ErrorActionPreference = "Stop"
$validStages = @("intake", "plan", "dev", "qa", "wiki", "done")
$validStatus = @("START", "PASS", "FAIL", "MASTER_FIX", "DECIDED", "BLOCKED_ENV", "BLOCKED_PERMISSION", "NEEDS_DECISION", "LOOP_LIMIT", "PAUSE", "RESUME")
$haltStatus = @("BLOCKED_ENV", "BLOCKED_PERMISSION", "NEEDS_DECISION", "LOOP_LIMIT", "PAUSE")
$utf8 = New-Object System.Text.UTF8Encoding($false)
$qaMethods = @("auto", "ui", "measure", "review", "manual")
$BoundNames = @($PSBoundParameters.Keys)

function Import-WorkSettings {
    # 0. Limits come from <dir>/settings.txt unless the caller passed them explicitly.
    if ([string]::IsNullOrWhiteSpace($WorkDir)) { return }
    $dirPath = $WorkDir
    if (-not [System.IO.Path]::IsPathRooted($dirPath)) { $dirPath = Join-Path $Root $dirPath }
    $file = Join-Path $dirPath "settings.txt"
    if (-not (Test-Path -LiteralPath $file)) { return }
    foreach ($line in [System.IO.File]::ReadAllLines($file)) {
        $m = [regex]::Match($line, '^\s*(MaxRounds|MaxGateFails|MaxQaCycles|MaxFixes|MaxDecisions|MaxModel|VerifyTimeoutMin|MaxStageRounds)\s*=\s*(\S+)\s*$')
        if (-not $m.Success -or $script:BoundNames -contains $m.Groups[1].Value) { continue }
        switch ($m.Groups[1].Value) {
            "MaxRounds" { $script:MaxRounds = [int]$m.Groups[2].Value }
            "MaxQaCycles" { $script:MaxQaCycles = [int]$m.Groups[2].Value }
            "MaxGateFails" { $script:MaxGateFails = [int]$m.Groups[2].Value }
            "MaxFixes" { $script:MaxFixes = [int]$m.Groups[2].Value }
            "MaxDecisions" { $script:MaxDecisions = [int]$m.Groups[2].Value }
            "MaxStageRounds" { $script:MaxStageRounds = [int]$m.Groups[2].Value }
            "VerifyTimeoutMin" { $script:VerifyTimeoutMin = [double]::Parse($m.Groups[2].Value, [System.Globalization.CultureInfo]::InvariantCulture) }
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
    $resolved = (Resolve-Path -LiteralPath $candidate).Path
    # 0. The work folder must sit under the project root; a call from another folder would run builds,
    #    diffs and evidence checks against the wrong tree and record a bogus FAIL. Refuse it as a usage
    #    error instead (exit 2, nothing logged).
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + '\'
    if (-not $resolved.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        Fail-Usage "Work folder $resolved is not under the project root $Root. Run ff.ps1 from the project root (or pass -Root <project root>)."
    }
    return $resolved
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

function Get-FailCount([object[]]$Events, [string]$ForStage, [string]$Kind = "all", [switch]$KeepAcrossFix) {
    # 0. Count FAILs for the stage since its last START/PASS, loop MASTER_FIX or user RESUME.
    #    Kind: "gate" (note starts with "gate"), "review" (any other FAIL), "all"; send-backs never count.
    #    -KeepAcrossFix (model escalation): a MASTER_FIX does not reset, so the model never drops after it.
    $count = 0
    foreach ($e in $Events) {
        if (Test-UserResume $e) { $count = 0; continue }
        if ($e.Stage -ne $ForStage) { continue }
        if ($e.Status -in @("START", "PASS")) { $count = 0; continue }
        if ($e.Status -eq "MASTER_FIX") { if (-not $KeepAcrossFix -and $e.Note -match '^loop') { $count = 0 }; continue }
        if ($e.Status -ne "FAIL" -or $e.Note -match '^sendback=') { continue }
        # 1. A FAIL that only records a second opinion upholding a master entry is not a defect round.
        if ($e.Note -match '^review: master entry upheld') { continue }
        $isGate = ($e.Note -match '^gate')
        if ($Kind -eq "all" -or ($Kind -eq "gate" -and $isGate) -or ($Kind -eq "review" -and -not $isGate)) { $count++ }
    }
    return $count
}

function Get-FixCount([object[]]$Events, [string]$ForStage, [string]$Kind) {
    # 0. Master interventions of one kind ("block" or "loop") in the stage since its START or the last user RESUME.
    $count = 0
    foreach ($e in $Events) {
        if (Test-UserResume $e) { $count = 0; continue }
        if ($e.Stage -ne $ForStage) { continue }
        if ($e.Status -eq "START") { $count = 0 }
        elseif ($e.Status -eq "MASTER_FIX" -and $e.Note -match "^$Kind") { $count++ }
    }
    return $count
}

function Get-MatchText([string]$Text) {
    # 0. Text compared when matching a quoted proposal: letters and digits only, lower case, so quotes,
    #    backticks, spaces and punctuation the master changed while copying do not matter.
    return ([regex]::Replace($Text, '[^\p{L}\p{Nd}]', '')).ToLowerInvariant()
}

function Get-StageRoundCount([object[]]$Events, [string]$ForStage) {
    # 0. Every round that did not pass (gate or review FAIL, NEEDS_DECISION) since the stage's START or
    #    the user's last RESUME. A MASTER_FIX does not reset it: this caps the whole stage, so a stage
    #    cannot loop for ever through consolidated fix lists.
    $count = 0
    foreach ($e in $Events) {
        if (Test-UserResume $e) { $count = 0; continue }
        if ($e.Stage -ne $ForStage) { continue }
        if ($e.Status -eq "START") { $count = 0; continue }
        if ($e.Status -eq "NEEDS_DECISION") { $count++; continue }
        if ($e.Status -ne "FAIL" -or $e.Note -match '^sendback=' -or $e.Note -match '^review: master entry upheld') { continue }
        $count++
    }
    return $count
}

function Test-StageRoundCap([object[]]$Events, [string]$ForStage) {
    $n = Get-StageRoundCount -Events $Events -ForStage $ForStage
    if ($n -ge $MaxStageRounds) { return "stage '$ForStage' has had $n rounds that did not pass (MaxStageRounds=$MaxStageRounds)" }
    return $null
}

function Test-StageOverLimit([object[]]$Events, [string]$ForStage) {
    # 0. Loop limit: reviewer FAILs and gate FAILs have separate budgets.
    if ((Get-FailCount -Events $Events -ForStage $ForStage -Kind "review") -ge $MaxRounds) { return "reviewer FAILs reached MaxRounds=$MaxRounds" }
    if ((Get-FailCount -Events $Events -ForStage $ForStage -Kind "gate") -ge $MaxGateFails) { return "gate FAILs reached MaxGateFails=$MaxGateFails" }
    return $null
}

function Get-StandingMasterEntries([string]$Dir) {
    # 0. Master entries a reviewer must judge: not overridden by a user entry and not upheld by a
    #    second opinion. Matching is on the first 20 characters of the entry text, case-insensitive.
    $spec = Join-Path $Dir "01-spec.md"
    if (-not (Test-Path -LiteralPath $spec)) { return @() }
    $lines = [System.IO.File]::ReadAllLines($spec)
    $closers = @()
    foreach ($l in $lines) {
        $mu = [regex]::Match($l, '^\s*-\s*user\s*\([^)]*\):.*\(overrides:\s*(.+)\)\s*$')
        if ($mu.Success) { $closers += $mu.Groups[1].Value.ToLowerInvariant() }
        $mh = [regex]::Match($l, '^\s*-\s*upheld\s*\([^)]*\):\s*(.+)$')
        if ($mh.Success) { $closers += $mh.Groups[1].Value.ToLowerInvariant() }
    }
    $standing = @()
    foreach ($l in $lines) {
        $mm = [regex]::Match($l, '^\s*-\s*master-(decided|created)\s*\([^)]*\):\s*(.+)$')
        if (-not $mm.Success) { continue }
        $text = $mm.Groups[2].Value.Trim()
        $key = $text.ToLowerInvariant()
        if ($key.Length -gt 20) { $key = $key.Substring(0, 20) }
        if (@($closers | Where-Object { $_.Contains($key) }).Count -gt 0) { continue }
        $standing += [pscustomobject]@{ Line = $l.Trim(); Key = $key }
    }
    return $standing
}

function Test-ReviewMatches([string]$Dir, [string]$ForStage, [int]$ForRound, [string]$ForStatus) {
    # 0. A PASS or NEEDS_DECISION may be logged only as the round's review file says; the master
    #    copies verdicts, it does not make them. Returns $null when it matches, else the problem.
    if ($ForRound -lt 1) { return "-Round must be the reviewed round N (reviews/$ForStage-r<N>.md)" }
    $review = Join-Path $Dir ("reviews\{0}-r{1}.md" -f $ForStage, $ForRound)
    if (-not (Test-Path -LiteralPath $review)) { return "no reviews/$ForStage-r$ForRound.md; save the reviewer's (or worker's) reply first" }
    $text = [System.IO.File]::ReadAllText($review)
    $mv = [regex]::Match($text, '(?m)^\s*VERDICT:\s*(PASS|FAIL|NEEDS_DECISION)\b')
    $verdict = $(if ($mv.Success) { $mv.Groups[1].Value } else { "" })
    if ($ForStatus -eq "PASS" -and $verdict -ne "PASS") { return "reviews/$ForStage-r$ForRound.md says VERDICT: $(if ($verdict) { $verdict } else { '(none)' }), not PASS" }
    if ($ForStatus -eq "NEEDS_DECISION" -and $verdict -ne "NEEDS_DECISION" -and $text -notmatch '(?m)^\s*RESULT:\s*NEEDS_DECISION') { return "reviews/$ForStage-r$ForRound.md does not say NEEDS_DECISION" }
    # A worker's (or the master's decision-cap) RESULT: NEEDS_DECISION is not a reviewer verdict: no
    # reviewer ran, so there is no DECISIONS: list to check.
    if (-not $verdict -or ($ForStatus -eq "NEEDS_DECISION" -and $text -match '(?m)^\s*RESULT:\s*NEEDS_DECISION')) { return $null }

    # 1. A reviewer's file must judge every standing master entry under DECISIONS:, and a PASS must not
    #    carry a NEEDS_DECISION verdict on one of them.
    $section = ""
    $md = [regex]::Match($text, '(?ms)^\s*DECISIONS:(.*)\z')
    if ($md.Success) { $section = $md.Groups[1].Value.ToLowerInvariant() }
    foreach ($entry in @(Get-StandingMasterEntries $Dir)) {
        if (-not $section.Contains($entry.Key)) { return "the reviewer did not judge '$($entry.Line)' under DECISIONS:; dispatch a fresh reviewer" }
    }
    if ($ForStatus -eq "PASS" -and $section -match '\[needs_decision\]') { return "a master entry is marked [NEEDS_DECISION] under DECISIONS:; log NEEDS_DECISION, not PASS" }
    return $null
}

function Get-DecisionCount([string]$Dir, [string]$Which) {
    # 0. Entries "- master-decided ..." / "- master-created ..." anywhere in the spec.
    $spec = Join-Path $Dir "01-spec.md"
    if (-not (Test-Path -LiteralPath $spec)) { return 0 }
    return @([System.IO.File]::ReadAllLines($spec) | Where-Object { $_ -match "^\s*-\s*master-$Which\b" }).Count
}

function Get-VerifyCommands([string]$Dir, [string]$ForStage = "dev") {
    # 0. "- build: <cmd>" / "- test: <cmd>" / "- ui-test: <cmd>" inside the spec's "## Verify commands"
    #    section only; empty values and "none" are skipped. [ \t] keeps an empty value from swallowing
    #    the next line. ui-test (the project's GUI harness) runs in the dev and QA gates.
    $spec = Join-Path $Dir "01-spec.md"
    if (-not (Test-Path -LiteralPath $spec)) { return @() }
    $inSection = $false
    $found = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($spec)) {
        if ($line -match '^\s*##\s') { $inSection = ($line -match '^\s*##\s+Verify commands\s*$'); continue }
        if (-not $inSection) { continue }
        $m = [regex]::Match($line, '^[ \t]*-[ \t]*(build|test|ui-test)[ \t]*:[ \t]*(.*?)[ \t]*$', 'IgnoreCase')
        if ($m.Success) { $found[$m.Groups[1].Value.ToLowerInvariant()] = $m.Groups[2].Value.Trim().Trim('`').Trim() }
    }
    $kinds = @("build", "test", "ui-test")
    $commands = @()
    foreach ($kind in $kinds) {
        if ($found.ContainsKey($kind) -and $found[$kind] -and $found[$kind] -ne "none") {
            $commands += , ([pscustomobject]@{ Kind = $kind; Cmd = $found[$kind] })
        }
    }
    return $commands
}

function Invoke-WithTimeout([string]$CommandLine, [double]$Minutes, [string]$EvidenceDir) {
    # 0. Run one verify command through cmd.exe from the project root; on timeout kill its whole
    #    process tree (a GUI harness stuck on a modal must not hang the gate) and report exit 124.
    #    FF_EVIDENCE_DIR tells a harness where to write screenshots (evidence/<stage>/gate-r<N>/, so a
    #    gate run never overwrites the screenshots a worker saved as proof).
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "cmd.exe"
    $psi.Arguments = '/d /c "' + $CommandLine + ' 2>&1"'
    $psi.WorkingDirectory = $Root
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    if ($EvidenceDir) { $psi.EnvironmentVariables["FF_EVIDENCE_DIR"] = $EvidenceDir }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Close()
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $timedOut = $false
    if (-not $proc.WaitForExit([int][Math]::Max(1000, $Minutes * 60000))) {
        $timedOut = $true
        & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null
        [void]$proc.WaitForExit(10000)
    }
    else { $proc.WaitForExit() }
    $text = ""
    if ($outTask.Wait(10000)) { $text += $outTask.Result }
    if ($errTask.Wait(2000)) { $text += $errTask.Result }
    $code = $(if ($timedOut) { 124 } else { $proc.ExitCode })
    return [pscustomobject]@{ Out = $text; Code = $code; TimedOut = $timedOut }
}

$SelfExit = 0
function Invoke-Self([string[]]$SelfArgs) {
    # 0. Run another ff.ps1 command in a child process; never let its stderr abort this one.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @SelfArgs 2>&1 | ForEach-Object { "$_" } | Out-String
        $script:SelfExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $prev }
    return $out
}

function Touch-Lock([string]$Dir) {
    # 0. Every working call refreshes the heartbeat, so a scheduled firing sees an active run.
    try { [System.IO.File]::WriteAllText((Join-Path $Dir "lock"), (Get-Date -Format "yyyy-MM-ddTHH:mm:ss"), $utf8) } catch { }
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

function Test-RevertLog([string]$Evidence, [string]$Dir) {
    # 0. A [fix] item's revert log must exist in the work folder and record the reverted run failing
    #    ("EXIT <non-zero>" line); whether the right test failed is still the reviewer's call.
    $m = [regex]::Match($Evidence, 'evidence/dev/revert-[^\s|;,:]+')
    if (-not $m.Success) { return $false }
    $path = Join-Path $Dir ($m.Value -replace '/', '\')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    return ([System.IO.File]::ReadAllText($path) -match '(?m)^\s*EXIT\s+-?[1-9]\d*\s*$')
}

function Get-TodoItems([string]$Dir) {
    return (Read-TodoFile (Join-Path $Dir "02-todo.md"))
}

function Read-TodoFile([string]$todo) {
    if (-not (Test-Path -LiteralPath $todo)) { return $null }
    $items = @()
    $current = $null
    foreach ($line in [System.IO.File]::ReadAllLines($todo)) {
        $m = [regex]::Match($line, '^\s*-\s*\[( |x|X)\]\s*([A-Za-z]+\d+)\s*[:.)-]?\s*(.*)$')
        if ($m.Success) {
            $current = [pscustomobject]@{ Id = $m.Groups[2].Value; Checked = ($m.Groups[1].Value -ne " "); Text = $m.Groups[3].Value; HasEvidenceLine = $false; Evidence = ""; Method = ""; MethodWhy = "" }
            $items += $current
            continue
        }
        if ($null -ne $current) {
            $ev = [regex]::Match($line, '^\s*-?\s*evidence[ \t]*:[ \t]*(.*)$', 'IgnoreCase')
            if ($ev.Success) { $current.HasEvidenceLine = $true; $current.Evidence = $ev.Groups[1].Value.Trim() }
            $mt = [regex]::Match($line, '^\s*-?\s*method[ \t]*:[ \t]*([A-Za-z]+)[ \t]*(?:-[ \t]*(.*))?$', 'IgnoreCase')
            if ($mt.Success) { $current.Method = $mt.Groups[1].Value.ToLowerInvariant(); $current.MethodWhy = $mt.Groups[2].Value.Trim() }
        }
    }
    return $items
}

function Get-NextAction([object[]]$Events) {
    # 0. Next action, so a resumed or scheduled orchestrator does not have to infer it.
    #    DECIDED lines only record a decision; they never change where the run is.
    $Events = @($Events | Where-Object { $_.Status -ne "DECIDED" })
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
            if (Test-StageRoundCap -Events $Events -ForStage $last.Stage) { return "escalated (stage round cap MaxStageRounds=$MaxStageRounds; no MASTER_FIX)$wait" }
            if (Test-StageOverLimit -Events $Events -ForStage $last.Stage) { return "escalated (loop limit; one MASTER_FIX may be tried first)$wait" }
            return "$($last.Stage) round $nextRound"
        }
        "MASTER_FIX" { return "$($last.Stage) round $nextRound" }
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
    }
    $want = [array]::IndexOf($tiers, $base)

    # 1. Workers go one tier up after 2 FAILs in their stage, the developer also after a QA IMPL send-back
    #    (since the last user RESUME). The reviewer always runs a different model than the worker it
    #    judges: one tier above it, or one tier below when the worker is already at MAX_MODEL.
    $cap = [array]::IndexOf($tiers, $MaxModel)
    if ($ForRole -eq "reviewer") {
        $workerRole = @{ plan = "planner"; dev = "developer"; qa = "qa"; wiki = "wiki" }[$ForStage]
        $worker = Get-PickedModel -ForRole $workerRole -ForStage $ForStage -Events $Events -Risk $Risk -DCount $DCount
        $workerIndex = [array]::IndexOf($tiers, $worker.Model)
        $pick = $workerIndex + 1
        if ($Risk -eq "high" -and $pick -lt 2) { $pick = 2 }
        if ($pick -gt $cap) { $pick = $workerIndex - 1; $reasons += "worker at cap" }
        if ($pick -lt 0) { $pick = $workerIndex; $reasons += "no other tier available" }
        $reasons += "worker=$($worker.Model)"
        $direction = $(if ($pick -gt $workerIndex) { "above" } elseif ($pick -lt $workerIndex) { "below" } else { "same as" })
        $reasons += "reviewer $direction worker"
        return [pscustomobject]@{ Model = $tiers[$pick]; Reasons = $reasons }
    }
    $fails = Get-FailCount -Events $Events -ForStage $ForStage -KeepAcrossFix
    if ($fails -ge 2) { $want++; $reasons += "fails=$fails" }
    if ($ForRole -eq "developer") {
        $impl = 0
        foreach ($e in $Events) {
            if (Test-UserResume $e) { $impl = 0 }
            elseif ($e.Status -eq "FAIL" -and $e.Note -match '^sendback=IMPL') { $impl++ }
        }
        if ($impl -ge 1) { $want++; $reasons += "qa-sendback" }
    }

    # 2. Cap at MAX_MODEL and say exactly what happened.
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
    $m = [regex]::Match($Token, '^(?<path>(?:[A-Za-z]:[\\/])?[^:*?"<>|\s]+?\.[A-Za-z][A-Za-z0-9]*)(:(?<start>\d+)(-(?<end>\d+))?)?$')
    if (-not $m.Success) { return $null }
    $rel = $m.Groups["path"].Value
    $explicit = ($rel -match '[\\/]') -or $m.Groups["start"].Success

    # 1. Absolute paths are accepted only inside the project root or the work folder.
    if ([System.IO.Path]::IsPathRooted($rel)) {
        $full = [System.IO.Path]::GetFullPath($rel)
        $inside = $false
        foreach ($base in @($Root, $Dir)) {
            $prefix = [System.IO.Path]::GetFullPath($base).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
            if ($full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { $inside = $true }
        }
        if (-not $inside) { return "outside the project: $rel" }
    }
    $resolved = Resolve-InProject -Rel $rel -Dir $Dir

    # 2. A bare name without folder or line is only a ref when it exists; otherwise treat it as prose.
    if ($null -eq $resolved) {
        if ($explicit) { return "missing file: $rel" }
        return $null
    }

    # 3. Whatever the spelling ("..", mixed slashes), the file must sit inside the project or the work
    #    folder, and never in an agent worktree that is cleaned up after the merge.
    $resolvedFull = [System.IO.Path]::GetFullPath($resolved)
    $insideResolved = $false
    $relativePart = $null
    foreach ($base in @($Root, $Dir)) {
        $prefix = [System.IO.Path]::GetFullPath($base).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        if ($resolvedFull.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $insideResolved = $true
            if ($null -eq $relativePart) { $relativePart = $resolvedFull.Substring($prefix.Length) }
        }
    }
    if (-not $insideResolved) { return "outside the project: $rel" }
    # 4. Only the part below the project root counts: the project itself may live in a worktree
    #    (Claude Code desktop sessions do), but evidence must not point into a nested agent worktree.
    if ($relativePart -match '(^|[\\/])\.claude[\\/]worktrees[\\/]') { return "points into an agent worktree (use a path relative to the project root): $rel" }

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
        # 0. Project override: a plugin install cannot edit the skill's own defaults, so
        #    .claude/feature-flow-settings.txt (key=value) wins over the values the master passes.
        $Parallel = "on"
        $AutoResume = "on"
        $settingsSource = "skill defaults"
        $projectSettings = Join-Path $Root ".claude\feature-flow-settings.txt"
        if (Test-Path -LiteralPath $projectSettings) {
            $settingsSource = ".claude/feature-flow-settings.txt"
            foreach ($line in [System.IO.File]::ReadAllLines($projectSettings)) {
                if ($line -match '^\s*(#|$)') { continue }
                $m = [regex]::Match($line, '^\s*([A-Za-z]+)\s*=\s*(\S+)\s*$')
                if (-not $m.Success) { Fail-Usage "Bad line in .claude/feature-flow-settings.txt: '$line' (expected Key=value)" }
                $key = $m.Groups[1].Value; $val = $m.Groups[2].Value
                $intKeys = @("MaxRounds", "MaxGateFails", "MaxQaCycles", "MaxFixes", "MaxDecisions", "MaxStageRounds")
                if ($key -in $intKeys) {
                    if ($val -notmatch '^[1-9]\d*$') { Fail-Usage "$key must be a positive integer in .claude/feature-flow-settings.txt (got '$val')" }
                    Set-Variable -Scope Script -Name $key -Value ([int]$val)
                }
                elseif ($key -eq "VerifyTimeoutMin") {
                    $d = 0.0
                    if (-not [double]::TryParse($val, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d) -or $d -le 0) { Fail-Usage "VerifyTimeoutMin must be a positive number (got '$val')" }
                    $script:VerifyTimeoutMin = $d
                }
                elseif ($key -eq "MaxModel") {
                    if ($val -notin @("haiku", "sonnet", "opus", "fable", "inherit")) { Fail-Usage "MaxModel must be haiku, sonnet, opus, fable or inherit (got '$val')" }
                    $script:MaxModel = $val
                }
                elseif ($key -in @("Parallel", "AutoResume")) {
                    if ($val -notin @("on", "off")) { Fail-Usage "$key must be on or off (got '$val')" }
                    Set-Variable -Name $key -Value $val
                }
                else { Fail-Usage "Unknown key '$key' in .claude/feature-flow-settings.txt (MaxRounds, MaxGateFails, MaxQaCycles, MaxFixes, MaxDecisions, MaxStageRounds, MaxModel, VerifyTimeoutMin, Parallel, AutoResume)" }
            }
        }
        $slug = ([regex]::Replace($Title.ToLowerInvariant(), '[^\p{L}\p{Nd}]+', '-')).Trim('-')
        if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40).Trim('-') }
        if ([string]::IsNullOrWhiteSpace($slug)) { $slug = "task" }
        $openDirs = @()
        foreach ($wd in @(Get-ChildItem -LiteralPath (Join-Path $Root "work") -Directory -ErrorAction SilentlyContinue)) {
            $evf = Join-Path $wd.FullName "events.log"
            if (-not (Test-Path -LiteralPath $evf)) { continue }
            if ([System.IO.File]::ReadAllText($evf) -notmatch '\| done \| PASS \|') { $openDirs += $wd.Name }
        }
        foreach ($od in $openDirs) { Write-Output "INFO: unfinished work folder work/$od (continue it only with 'resume work/$od'; never reuse it for a new request)" }
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
            $dirty = Invoke-Git @("status", "--porcelain", "--", ".", ":(exclude)work", ":(exclude).claude/worktrees")
            if (@($dirty.Out | Where-Object { $_ }).Count -gt 0) { Write-Output "WARN: uncommitted changes exist; they will appear in round diffs. Commit or stash first." }
            $ignored = Invoke-Git @("check-ignore", "-q", "work/x")
            if ($ignored.Code -ne 0) { Write-Output "WARN: work/ is not in .gitignore." }
        }
        else { Write-Output "WARN: not a git repository; 'diff' will not work. Ask the user to git init." }
        [System.IO.File]::WriteAllText((Join-Path $dir "base.txt"), $base, $utf8)

        $context = "# Project context (seed)`n`n- Build command:`n- Test command:`n- Run/launch:`n- UI technology (none / WPF / WinForms / WebView2 / Electron / web / other):`n- UI test harness command (none / to be built: <method> / <command>):`n- Key folders:`n- Conventions (from CLAUDE.md/AGENTS.md):`n- Secrets (how credentials are provided: env var names or a prompt; never the values):`n- Wiki index: docs/wiki/index.md`n"
        $spec = "# Spec: $Title`n`n## Goal`n`n## In scope`n`n## Out of scope`n`n## Constraints / cautions`n`n## Acceptance criteria`n`n## Verify commands`n- build:`n- test:`n- ui-test: none`n`n## Risk`n- level: normal`n"
        [System.IO.File]::WriteAllText((Join-Path $dir "00-context.md"), $context, $utf8)
        [System.IO.File]::WriteAllText((Join-Path $dir "01-spec.md"), $spec, $utf8)
        [System.IO.File]::WriteAllText((Join-Path $dir "events.log"), "", $utf8)
        $settings = "MaxRounds=$MaxRounds`nMaxGateFails=$MaxGateFails`nMaxQaCycles=$MaxQaCycles`nMaxFixes=$MaxFixes`nMaxDecisions=$MaxDecisions`nMaxModel=$MaxModel`nVerifyTimeoutMin=$VerifyTimeoutMin`nMaxStageRounds=$MaxStageRounds`nParallel=$Parallel`nAutoResume=$AutoResume`n"
        [System.IO.File]::WriteAllText((Join-Path $dir "settings.txt"), $settings, $utf8)
        Write-Output "SETTINGS  MaxRounds=$MaxRounds MaxGateFails=$MaxGateFails MaxQaCycles=$MaxQaCycles MaxFixes=$MaxFixes MaxDecisions=$MaxDecisions MaxModel=$MaxModel VerifyTimeoutMin=$VerifyTimeoutMin MaxStageRounds=$MaxStageRounds Parallel=$Parallel AutoResume=$AutoResume (from $settingsSource)"
        Write-Output "WORKDIR   $dir"
        exit 0
    }

    "event" {
        $dir = Resolve-WorkDir
        Touch-Lock $dir
        if ($Stage -notin $validStages) { Fail-Usage "-Stage must be one of: $($validStages -join ', ')" }
        if ($Status -notin $validStatus) { Fail-Usage "-Status must be one of: $($validStatus -join ', ')" }
        $clean = (($Note -replace '[\r\n|]+', ' ') -replace '\s+', ' ').Trim()
        if ($SendBack) {
            if ($Status -ne "FAIL" -or $Stage -ne "qa") { Fail-Usage "-SendBack is only valid with -Stage qa -Status FAIL." }
            $clean = ("sendback=$SendBack $clean").Trim()
        }
        if ($Model) { $clean = ("$clean [model=$Model]").Trim() }
        if ($ReviewerModel) { $clean = ("$clean [reviewer=$ReviewerModel]").Trim() }

        # 0. A PASS or NEEDS_DECISION of a stage round must match the round's review file, and a FAIL
        #    may not be logged over a review that says PASS (gate FAILs write their own review file).
        if ($Status -in @("PASS", "NEEDS_DECISION") -and $Stage -in @("plan", "dev", "qa", "wiki")) {
            $mismatch = Test-ReviewMatches -Dir $dir -ForStage $Stage -ForRound $Round -ForStatus $Status
            if ($mismatch) { Write-Output "REJECTED  $Status not logged: $mismatch"; exit 2 }
        }
        if ($Status -eq "FAIL" -and $Stage -in @("plan", "dev", "qa", "wiki") -and $Round -ge 1 -and $clean -notmatch '^gate') {
            $reviewPath = Join-Path $dir ("reviews\{0}-r{1}.md" -f $Stage, $Round)
            if ((Test-Path -LiteralPath $reviewPath) -and ([System.IO.File]::ReadAllText($reviewPath) -match '(?m)^\s*VERDICT:\s*PASS\b')) {
                Write-Output "REJECTED  FAIL not logged: reviews/$Stage-r$Round.md says VERDICT: PASS"
                exit 2
            }
        }

        # 0b. MASTER_FIX is checked before it is written: kind "block:" or "loop:", each with its own budget.
        #    Over budget, the halt is logged instead, so no later reader sees an unpaid fix.
        if ($Status -eq "MASTER_FIX") {
            $mk = [regex]::Match($clean, '^(block|loop)\s*:')
            if (-not $mk.Success) { Fail-Usage "MASTER_FIX needs a note starting with 'block:' (fixed a blocker) or 'loop:' (consolidated reviews at the loop limit)." }
            $used = Get-FixCount -Events @(Read-Events $dir) -ForStage $Stage -Kind $mk.Groups[1].Value
            $capHit = $(if ($mk.Groups[1].Value -eq "loop") { Test-StageRoundCap -Events @(Read-Events $dir) -ForStage $Stage } else { $null })
            if ($capHit) {
                $halt = "{0} | {1} | LOOP_LIMIT | r{2} | {3}; not applied: {4}" -f (Get-Date -Format "yyyy-MM-ddTHH:mm:ss"), $Stage, $Round, $capHit, $clean
                [System.IO.File]::AppendAllText((Join-Path $dir "events.log"), $halt + "`n", $utf8)
                Write-Output $halt
                Write-Output "LOOP_LIMIT: $capHit; no more loop fixes. Escalate to the user."
                exit 3
            }
            if ($used -ge $MaxFixes) {
                $haltName = $(if ($mk.Groups[1].Value -eq "block") { "BLOCKED_ENV" } else { "LOOP_LIMIT" })
                $halt = "{0} | {1} | {2} | r{3} | master fix budget used ({4} {5}/{6}); not applied: {7}" -f (Get-Date -Format "yyyy-MM-ddTHH:mm:ss"), $Stage, $haltName, $Round, $mk.Groups[1].Value, $used, $MaxFixes, $clean
                [System.IO.File]::AppendAllText((Join-Path $dir "events.log"), $halt + "`n", $utf8)
                Write-Output $halt
                Write-Output "LOOP_LIMIT: stage '$Stage' already used its $($mk.Groups[1].Value) master fix (max $MaxFixes); logged $haltName. Escalate to the user."
                exit 3
            }
        }
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
        if ($Status -eq "FAIL") {
            $cap = Test-StageRoundCap -Events $events -ForStage $Stage
            if ($cap) {
                $halt = "{0} | {1} | LOOP_LIMIT | r{2} | {3}" -f (Get-Date -Format "yyyy-MM-ddTHH:mm:ss"), $Stage, $Round, $cap
                [System.IO.File]::AppendAllText((Join-Path $dir "events.log"), $halt + "`n", $utf8)
                Write-Output $halt
                Write-Output "LOOP_LIMIT: $cap. Logged LOOP_LIMIT; no MASTER_FIX; escalate to the user."
                exit 3
            }
            $over = Test-StageOverLimit -Events $events -ForStage $Stage
            if ($over) {
                Write-Output "LOOP_LIMIT: stage '$Stage' $over. Try one MASTER_FIX if allowed, otherwise escalate to the user."
                exit 3
            }
        }
        exit 0
    }

    "check-todo" {
        $dir = Resolve-WorkDir
        Touch-Lock $dir
        $items = Get-TodoItems $dir
        if ($null -eq $items) { Fail-Usage "02-todo.md not found in $dir" }

        # 0. -FormatOnly: plan-stage gate. Needs D and Q items, unique IDs, an evidence line each; every Q
        #    item names how it will be verified (the method is the model's choice, the reviewer judges it),
        #    and at least one Q item checks that existing behavior still works ([regression]).
        if ($FormatOnly) {
            $bad = 0
            $qItems = @($items | Where-Object { $_.Id -like "Q*" })
            if (@($items | Where-Object { $_.Id -like "D*" }).Count -eq 0) { Write-Output "FORMAT    no D items"; $bad++ }
            if ($qItems.Count -eq 0) { Write-Output "FORMAT    no Q items"; $bad++ }
            foreach ($dup in ($items | Group-Object Id | Where-Object { $_.Count -gt 1 })) { Write-Output "FORMAT    duplicate id $($dup.Name)"; $bad++ }
            foreach ($item in $items) { if (-not $item.HasEvidenceLine) { Write-Output "FORMAT    $($item.Id) has no '  - evidence:' line"; $bad++ } }
            foreach ($item in $qItems) {
                if ($item.Method -notin $qaMethods) { Write-Output "FORMAT    $($item.Id) has no '  - method: <$($qaMethods -join '|')> - <why>' line"; $bad++ }
                elseif (-not $item.MethodWhy) { Write-Output "FORMAT    $($item.Id) method '$($item.Method)' gives no reason ('- <why>')"; $bad++ }
            }
            if ($qItems.Count -gt 0 -and @($qItems | Where-Object { $_.Text -match '\[regression\]' }).Count -eq 0) { Write-Output "FORMAT    no [regression] Q item (existing behavior that must keep working)"; $bad++ }
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
            # 3. A bug fix is proven by its test failing without the fix; a manual item is closed only by
            #    the user's report the master saved.
            elseif ($item.Id -like "D*" -and $item.Text -match '\[fix\]' -and -not (Test-RevertLog $item.Evidence $dir)) { Write-Output "NO-REVERT $($item.Id)  [fix] item needs evidence/dev/revert-<n>.log ending with the failing run's 'EXIT <non-zero>' (the test fails with the fix reverted)"; $bad++ }
            elseif ($item.Id -like "Q*" -and $item.Method -eq "manual" -and $item.Evidence -notmatch ('evidence/qa/' + [regex]::Escape($item.Id) + '-manual\.log')) { Write-Output "NO-MANUAL $($item.Id)  manual item is closed only by evidence/qa/$($item.Id)-manual.log (the user's report)"; $bad++ }
            else { Write-Output "OK        $($item.Id)" }
        }
        Write-Output ("SUMMARY   {0} item(s), {1} problem(s)" -f $items.Count, $bad)
        if ($bad -gt 0) { exit 1 }
        exit 0
    }

    "diff" {
        $dir = Resolve-WorkDir
        Touch-Lock $dir
        if ($Round -lt 1) { Fail-Usage "-Round <N> is required for diff." }
        $baseFile = Join-Path $dir "base.txt"
        $base = if (Test-Path -LiteralPath $baseFile) { ([System.IO.File]::ReadAllText($baseFile)).Trim() } else { "none" }
        if ($base -eq "none") { Fail-Usage "No git base recorded (not a git repository at init). Treat as BLOCKED_ENV." }

        # 0. Tracked changes vs base, then each untracked file as a new-file diff; work/ is always excluded.
        $parts = New-Object System.Collections.Generic.List[string]
        $tracked = Invoke-Git @("diff", $base, "--", ".", ":(exclude)work", ":(exclude).claude/worktrees")
        if ($tracked.Code -ne 0) { Fail-Usage "git diff failed against base $base" }
        foreach ($l in $tracked.Out) { $parts.Add([string]$l) }
        $untracked = Invoke-Git @("ls-files", "--others", "--exclude-standard", "--", ".", ":(exclude)work", ":(exclude).claude/worktrees")
        foreach ($f in ($untracked.Out | Where-Object { $_ })) {
            $nd = Invoke-Git @("diff", "--no-index", "--", "/dev/null", $f)
            foreach ($l in $nd.Out) { $parts.Add([string]$l) }
        }
        $outFile = Join-Path $dir ("evidence\dev\diff-r{0}.patch" -f $Round)
        [System.IO.File]::WriteAllText($outFile, (($parts -join "`n") + "`n"), $utf8)
        Write-Output ("DIFF      {0} ({1} untracked file(s))" -f $outFile, @($untracked.Out | Where-Object { $_ }).Count)

        # 1. Line-ending rewrites: files whose diff shrinks when CR at EOL is ignored were re-saved with other line endings.
        $plain = @{}
        foreach ($l in (Invoke-Git @("diff", "--numstat", $base, "--", ".", ":(exclude)work", ":(exclude).claude/worktrees")).Out) {
            $c = ([string]$l) -split "`t"
            if ($c.Count -ge 3 -and $c[0] -match '^\d+$') { $plain[$c[2]] = [int]$c[0] + [int]$c[1] }
        }
        $eolFiles = @()
        $ignoring = @{}
        foreach ($l in (Invoke-Git @("diff", "--numstat", "--ignore-cr-at-eol", $base, "--", ".", ":(exclude)work", ":(exclude).claude/worktrees")).Out) {
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
        $reviewFails = Get-FailCount -Events $events -ForStage $last.Stage -Kind "review"
        $gateFails = Get-FailCount -Events $events -ForStage $last.Stage -Kind "gate"
        Write-Output "STAGE     $($last.Stage)  last=$($last.Status) $($last.Round)"
        Write-Output "FAILS     $reviewFails review (max $MaxRounds), $gateFails gate (max $MaxGateFails); master fixes block $(Get-FixCount -Events $events -ForStage $last.Stage -Kind "block"), loop $(Get-FixCount -Events $events -ForStage $last.Stage -Kind "loop") (max $MaxFixes each); stage rounds $(Get-StageRoundCount -Events $events -ForStage $last.Stage)/$MaxStageRounds"
        Write-Output "SENDBACKS $(Get-SendBackCount $events) (max $MaxQaCycles)"
        Write-Output "DECISIONS $(Get-DecisionCount $dir "decided") master-decided (max $MaxDecisions), $(Get-DecisionCount $dir "created") master-created"
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
        Touch-Lock $dir
        if (-not $Role) { Fail-Usage "-Role is required for pick-model (planner, developer, qa, reviewer, wiki)." }
        $stageOfRole = @{ planner = "plan"; developer = "dev"; qa = "qa"; wiki = "wiki"; reviewer = $Stage; second = $Stage }
        $forStage = $stageOfRole[$Role]
        if ($Role -in @("reviewer", "second") -and $forStage -notin @("plan", "dev", "qa", "wiki")) { Fail-Usage "-Stage (plan, dev, qa, wiki) is required for the reviewer and the second opinion." }
        $items = Get-TodoItems $dir
        $dCount = 0
        if ($null -ne $items) { $dCount = @($items | Where-Object { $_.Id -like "D*" }).Count }
        if ($MaxModel -eq "inherit") {
            # 0. MaxModel=inherit: do not pass a model at all; the agent file's model applies.
            Write-Output "MODEL     inherit"
            Write-Output "REASON    MaxModel=inherit; omit the Agent call's model parameter"
            exit 0
        }
        if ($Role -eq "second") {
            # 1. Second opinion on a disputed master entry: one tier above the stage reviewer, at most MAX_MODEL.
            $tiers = @("haiku", "sonnet", "opus", "fable")
            $first = Get-PickedModel -ForRole "reviewer" -ForStage $forStage -Events @(Read-Events $dir) -Risk (Get-RiskLevel $dir) -DCount $dCount
            $idx = [Math]::Min([array]::IndexOf($tiers, $first.Model) + 1, [array]::IndexOf($tiers, $MaxModel))
            $note = $(if ($tiers[$idx] -eq $first.Model) { "same tier as the first reviewer (MAX_MODEL), fresh context" } else { "one tier above the first reviewer ($($first.Model))" })
            Write-Output "MODEL     $($tiers[$idx])"
            Write-Output "REASON    second opinion, $note"
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
        Touch-Lock $dir
        if ($Stage -notin @("dev", "qa")) { Fail-Usage "-Stage dev or qa is required for verify." }
        if ($Round -lt 1) { Fail-Usage "-Round <N> is required for verify." }
        if ($FromSpec) { $commands = @(Get-VerifyCommands $dir $Stage) }
        else {
            $commands = @()
            if ($Build -and $Build.Trim() -and $Build.Trim() -ne "none") { $commands += , ([pscustomobject]@{ Kind = "build"; Cmd = $Build.Trim() }) }
            if ($Test -and $Test.Trim() -and $Test.Trim() -ne "none") { $commands += , ([pscustomobject]@{ Kind = "test"; Cmd = $Test.Trim() }) }
        }
        if ($commands.Count -eq 0) { Fail-Usage "No build/test command: pass -Build/-Test or fill the spec's Verify commands (-FromSpec)." }

        # 0. Run each command through cmd.exe from the project root, each with a timeout; the log and
        #    exit codes decide, not a model. A ui-test exit 2 means "no verdict" and is not a pass.
        $log = Join-Path $dir ("evidence\{0}\verify-r{1}.log" -f $Stage, $Round)
        $text = New-Object System.Text.StringBuilder
        $failed = 0
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            foreach ($c in $commands) {
                $gateOut = Join-Path $dir ("evidence\{0}\gate-r{1}" -f $Stage, $Round)
                if ($c.Kind -eq "ui-test") { New-Item -ItemType Directory -Force -Path $gateOut | Out-Null }
                $run = Invoke-WithTimeout $c.Cmd $VerifyTimeoutMin $gateOut
                $code = $run.Code
                [void]$text.AppendLine("### [$($c.Kind)] $($c.Cmd)")
                foreach ($l in ($run.Out -split "\r?\n")) { [void]$text.AppendLine($l) }
                if ($run.TimedOut) { [void]$text.AppendLine("TIMEOUT after $VerifyTimeoutMin min; process tree killed") }
                [void]$text.AppendLine("EXIT $code")
                [void]$text.AppendLine("")
                $verdict = "PASS"
                if ($run.TimedOut) { $verdict = "TIMEOUT" }
                elseif ($code -eq 2 -and $c.Kind -eq "ui-test") { $verdict = "NO-VERDICT" }
                elseif ($code -ne 0) { $verdict = "FAIL" }
                if ($verdict -ne "PASS") { $failed++ }
                Write-Output ("VERIFY    {0}  exit {1}  [{2}] {3}" -f $verdict, $code, $c.Kind, $c.Cmd)
            }
        }
        finally { $ErrorActionPreference = $prevEap }
        [System.IO.File]::WriteAllText($log, $text.ToString(), $utf8)
        Write-Output "LOG       $log"
        if ($failed -gt 0) { Write-Output "GATE      FAIL  $failed command(s) failed"; exit 1 }
        exit 0
    }

    "gate" {
        $dir = Resolve-WorkDir
        Touch-Lock $dir
        if ($Stage -notin @("plan", "dev", "qa", "wiki")) { Fail-Usage "-Stage plan, dev, qa or wiki is required for gate." }
        if ($Round -lt 1) { Fail-Usage "-Round <N> is required for gate." }

        # 0. The stage's checks, each run as its own ff.ps1 call so the logic is shared with the single
        #    commands; verify reads the build/test commands from the spec itself (-FromSpec), so no
        #    command text ever passes through a command line.
        $hasVerify = (@(Get-VerifyCommands $dir $Stage).Count -gt 0)
        $steps = @()
        if ($Stage -in @("plan", "dev", "qa")) { $steps += , @("proposed-check", "-Stage", $Stage, "-Round", "$Round") }
        switch ($Stage) {
            "plan" { $steps += , @("check-todo", "-FormatOnly") }
            "dev" {
                if ($hasVerify) { $steps += , @("verify", "-Stage", "dev", "-Round", "$Round", "-FromSpec") }
                $steps += , @("check-todo", "-Prefix", "D")
                $steps += , @("diff", "-Round", "$Round")
            }
            "qa" {
                if ($hasVerify) { $steps += , @("verify", "-Stage", "qa", "-Round", "$Round", "-FromSpec") }
                $steps += , @("check-todo", "-Prefix", "Q", "-AllowOpen")
                if (Test-Path -LiteralPath (Join-Path $dir "evidence\qa\manual-checklist.md")) { $steps += , @("manual-check") }
            }
            "wiki" { $steps += , @("wiki-check") }
        }
        if ($Stage -in @("dev", "qa") -and -not $hasVerify) { Write-Output "SKIP      verify (spec has no build/test command)" }

        $report = New-Object System.Text.StringBuilder
        $failedSteps = @()
        foreach ($step in $steps) {
            $out = Invoke-Self (@($step) + @("-WorkDir", $dir, "-Root", $Root))
            $code = $script:SelfExit
            $name = $step[0]
            Write-Output ("STEP      {0}  exit {1}" -f $name, $code)
            [void]$report.AppendLine("## $name (exit $code)")
            foreach ($l in ($out -split "`r?`n")) { if ($l.Trim()) { [void]$report.AppendLine("    $l") } }
            if ($code -ne 0) { $failedSteps += $name }
        }
        if ($failedSteps.Count -eq 0) { Write-Output "GATE      PASS  call the reviewer next"; exit 0 }

        # 2. Failed gate: write the round's review file and log the FAIL, so the master only reacts.
        $review = Join-Path $dir ("reviews\{0}-r{1}.md" -f $Stage, $Round)
        $body = "VERDICT: FAIL (gate)`nFAILED: $($failedSteps -join ', ')`n`n" + $report.ToString()
        [System.IO.File]::WriteAllText($review, $body, $utf8)
        Write-Output "REVIEW    $review"
        $ev = Invoke-Self @("event", "-WorkDir", $dir, "-Root", $Root, "-Stage", $Stage, "-Status", "FAIL", "-Round", "$Round", "-Note", ("gate: " + ($failedSteps -join ",")))
        $evCode = $script:SelfExit
        foreach ($l in ($ev -split "`r?`n")) { if ($l.Trim()) { Write-Output "EVENT     $l" } }
        Write-Output "GATE      FAIL  $($failedSteps -join ', ')"
        if ($evCode -eq 3) { exit 3 }
        exit 1
    }

    "proposed-check" {
        $dir = Resolve-WorkDir
        Touch-Lock $dir
        if ($Stage -notin @("plan", "dev", "qa")) { Fail-Usage "-Stage plan, dev or qa is required for proposed-check." }
        if ($Round -lt 1) { Fail-Usage "-Round <N> is required for proposed-check." }
        # 0. The master saves each worker reply as evidence/<stage>/worker-r<N>[-X].md. A choice the spec
        #    left open that a worker made on its own (DECISIONS-PROPOSED) must be recorded with
        #    "decision -Kind decided" (or answered by the user) before the gate passes, so it counts toward
        #    MaxDecisions and the reviewer judges it. Matching: first 20 characters, case-insensitive.
        $replies = @(Get-ChildItem -LiteralPath (Join-Path $dir ("evidence\" + $Stage)) -Filter ("worker-r{0}*.md" -f $Round) -File -ErrorAction SilentlyContinue)
        if ($replies.Count -eq 0) { Write-Output ("PROPOSED  FAIL  no evidence/{0}/worker-r{1}.md: save the worker's reply verbatim (or 'worker skipped: <why>')" -f $Stage, $Round); exit 1 }
        $recorded = @()
        $spec = Join-Path $dir "01-spec.md"
        if (Test-Path -LiteralPath $spec) {
            foreach ($l in [System.IO.File]::ReadAllLines($spec)) {
                $md = [regex]::Match($l, '^\s*-\s*(master-decided|user|upheld)\s*\([^)]*\):\s*(.+)$')
                if ($md.Success) { $recorded += (Get-MatchText $md.Groups[2].Value) }
            }
        }
        $missing = @(); $count = 0
        foreach ($f in $replies) {
            $inList = $false
            foreach ($l in [System.IO.File]::ReadAllLines($f.FullName)) {
                if ($l -match '^\s*DECISIONS-PROPOSED:\s*(none)?\s*$') { $inList = -not $Matches[1]; continue }
                if (-not $inList) { continue }
                $mi = [regex]::Match($l, '^\s*-\s*(.+?)\s*$')
                if (-not $mi.Success) { $inList = $false; continue }
                $count++
                $key = Get-MatchText $mi.Groups[1].Value
                if ($key.Length -gt 20) { $key = $key.Substring(0, 20) }
                if (@($recorded | Where-Object { $_.Contains($key) }).Count -eq 0) { $missing += ("{0}: {1}" -f $f.Name, $mi.Groups[1].Value) }
            }
        }
        foreach ($m in $missing) { Write-Output "PROPOSED  NOT RECORDED  $m" }
        if ($missing.Count -gt 0) { Write-Output "PROPOSED  FAIL  record each with: decision -Kind decided -Note `"<the proposal, quoted>`" (or escalate if it changes scope)"; exit 1 }
        Write-Output ("PROPOSED  PASS  {0} worker reply file(s), {1} proposed decision(s), all recorded" -f $replies.Count, $count)
        exit 0
    }

    "manual-check" {
        $dir = Resolve-WorkDir
        Touch-Lock $dir
        # 0. A Q item may go to a human only after automation was tried: every "### Q<n>" section of the
        #    checklist needs a non-empty "- automation tried:" line naming the method and why it failed,
        #    and every Q id must exist in 02-todo.md.
        $file = Join-Path $dir "evidence\qa\manual-checklist.md"
        if (-not (Test-Path -LiteralPath $file)) { Write-Output "MANUAL    FAIL  evidence/qa/manual-checklist.md not found"; exit 1 }
        $todoIds = @{}
        foreach ($it in @(Get-TodoItems $dir)) { $todoIds[$it.Id] = $true }
        $problems = @()
        $current = $null
        $tried = @{}
        $order = @()
        foreach ($line in [System.IO.File]::ReadAllLines($file)) {
            $h = [regex]::Match($line, '^\s*###\s+(Q\d+)\b')
            if ($h.Success) { $current = $h.Groups[1].Value; $order += $current; $tried[$current] = $false; continue }
            if ($line -match '^\s*##?\s') { $current = $null; continue }
            if ($current -and $line -match '^\s*-\s*automation tried\s*:\s*\S') { $tried[$current] = $true }
        }
        if ($order.Count -eq 0) { $problems += "no '### Q<n>' item sections" }
        foreach ($id in $order) {
            if (-not $todoIds.ContainsKey($id)) { $problems += "$id is not a Q item in 02-todo.md" }
            if (-not $tried[$id]) { $problems += "$id has no '- automation tried: <method> - <why it failed>' line" }
        }
        foreach ($p in $problems) { Write-Output "MANUAL    $p" }
        if ($problems.Count -gt 0) { Write-Output "MANUAL    FAIL  $($problems.Count) problem(s)"; exit 1 }
        Write-Output "MANUAL    PASS  $($order.Count) item(s) with automation attempts recorded"
        exit 0
    }

    "decision" {
        $dir = Resolve-WorkDir
        Touch-Lock $dir
        if (-not $Kind) { Fail-Usage "-Kind decided (an in-scope choice the master made), created (a file a MASTER_FIX created), user (the user's answer to an escalation) or upheld (a second opinion kept a disputed master entry; -Note quotes the entry) is required." }
        if ($Stage -notin $validStages) { Fail-Usage "-Stage must be one of: $($validStages -join ', ')" }
        $text = (($Note -replace '[\r\n]+', ' ') -replace '\s+', ' ').Trim()
        if (-not $text) { Fail-Usage "-Note with the decision text is required." }
        $spec = Join-Path $dir "01-spec.md"
        if (-not (Test-Path -LiteralPath $spec)) { Fail-Usage "01-spec.md not found in $dir" }

        # 0. Cap: the master may decide only a few things on its own per work item; beyond that the user decides.
        if ($Kind -eq "decided") {
            $already = Get-DecisionCount $dir "decided"
            if ($already -ge $MaxDecisions) {
                Write-Output "LIMIT     $already master decisions already (max $MaxDecisions); not recorded. Log NEEDS_DECISION and escalate to the user."
                exit 3
            }
        }

        # 1. Append under "## Decisions" (created at the end of the spec if missing), before the next section.
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($l in [System.IO.File]::ReadAllLines($spec)) { $lines.Add($l) }
        $label = $(if ($Kind -in @("user", "upheld")) { $Kind } else { "master-$Kind" })
        $entry = "- {0} ({1}, {2}): {3}" -f $label, (Get-Date -Format "yyyy-MM-dd"), $Stage, $text
        if ($Overrides) { $entry += " (overrides: " + (($Overrides -replace '[\r\n]+', ' ').Trim()) + ")" }
        $start = -1
        for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*##\s+Decisions\s*$') { $start = $i; break } }
        if ($start -lt 0) {
            if ($lines.Count -gt 0 -and $lines[$lines.Count - 1].Trim()) { $lines.Add("") }
            $lines.Add("## Decisions")
            $lines.Add($entry)
        }
        else {
            $insert = $lines.Count
            for ($i = $start + 1; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*##\s') { $insert = $i; break } }
            while ($insert -gt $start + 1 -and -not $lines[$insert - 1].Trim()) { $insert-- }
            $lines.Insert($insert, $entry)
        }
        [System.IO.File]::WriteAllText($spec, (($lines -join "`n") + "`n"), $utf8)
        # 2. One DECIDED line in the timeline, so the decision is visible there too (it never changes NEXT).
        $short = $(if ($text.Length -gt 120) { $text.Substring(0, 120) + "..." } else { $text })
        $evLine = "{0} | {1} | DECIDED | r0 | {2}: {3}" -f (Get-Date -Format "yyyy-MM-ddTHH:mm:ss"), $Stage, $label, ($short -replace '\|', '/')
        [System.IO.File]::AppendAllText((Join-Path $dir "events.log"), $evLine + "`n", $utf8)
        Write-Output "DECISION  $entry"
        Write-Output ("COUNT     {0} master-decided (max {1})" -f (Get-DecisionCount $dir "decided"), $MaxDecisions)
        exit 0
    }

    "merge-evidence" {
        $dir = Resolve-WorkDir
        Touch-Lock $dir
        $todoPath = Join-Path $dir "02-todo.md"
        if (-not (Test-Path -LiteralPath $todoPath)) { Fail-Usage "02-todo.md not found in $dir" }
        $groupFiles = @(Get-ChildItem -LiteralPath (Join-Path $dir "evidence\dev") -Filter "group-*.md" -File -ErrorAction SilentlyContinue | Sort-Object Name)
        if ($groupFiles.Count -eq 0) { Fail-Usage "No evidence/dev/group-*.md files to merge." }

        # 0. Collect each parallel developer's checks and evidence; an id may appear in one group file only.
        $updates = @{}
        $bad = 0
        foreach ($gf in $groupFiles) {
            foreach ($item in @(Read-TodoFile $gf.FullName)) {
                if ($null -eq $item) { continue }
                if ($updates.ContainsKey($item.Id)) { Write-Output "DUPLICATE $($item.Id) in $($gf.Name) and $($updates[$item.Id].File)"; $bad++; continue }
                $updates[$item.Id] = [pscustomobject]@{ Checked = $item.Checked; Evidence = $item.Evidence; HasEvidence = $item.HasEvidenceLine; File = $gf.Name }
            }
        }

        # 1. Rewrite 02-todo.md in place: checkbox and evidence line of every updated item.
        $lines = [System.IO.File]::ReadAllLines($todoPath)
        $current = $null
        $seen = @{}
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $mi = [regex]::Match($lines[$i], '^(\s*-\s*\[)( |x|X)(\]\s*)([A-Za-z]+\d+)(.*)$')
            if ($mi.Success) {
                $current = $mi.Groups[4].Value
                if ($updates.ContainsKey($current)) {
                    $mark = $(if ($updates[$current].Checked) { "x" } else { " " })
                    $lines[$i] = $mi.Groups[1].Value + $mark + $mi.Groups[3].Value + $current + $mi.Groups[5].Value
                    $seen[$current] = $true
                }
                continue
            }
            if ($current -and $updates.ContainsKey($current) -and $updates[$current].HasEvidence) {
                $me = [regex]::Match($lines[$i], '^(\s+-?\s*evidence\s*:)(.*)$', 'IgnoreCase')
                if ($me.Success) { $lines[$i] = $me.Groups[1].Value + " " + $updates[$current].Evidence; $lines[$i] = $lines[$i].TrimEnd() }
            }
        }
        foreach ($id in $updates.Keys) { if (-not $seen.ContainsKey($id)) { Write-Output "UNKNOWN   $id (in $($updates[$id].File)) is not in 02-todo.md"; $bad++ } }
        [System.IO.File]::WriteAllText($todoPath, (($lines -join "`n") + "`n"), $utf8)
        Write-Output ("MERGED    {0} item(s) from {1} group file(s)" -f $seen.Count, $groupFiles.Count)
        if ($bad -gt 0) { exit 1 }
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
        $realStage = ($events | Where-Object { $_.Status -notin @("RESUME", "DECIDED") } | Select-Object -Last 1).Stage
        if (-not $realStage) { $realStage = $last.Stage }
        $line = "{0} | {1} | RESUME | r0 | auto idle={2}min" -f (Get-Date -Format "yyyy-MM-ddTHH:mm:ss"), $realStage, $idle
        [System.IO.File]::AppendAllText((Join-Path $dir "events.log"), $line + "`n", $utf8)
        Write-Output "DECISION  RESUME  idle $idle min; auto resumes in 24h: $($autoCount + 1)/$MaxAutoPerDay (logged)"
        Write-Output "NEXT      $next"
        Write-Output "ACTION    print '[feature-flow] auto resume of $dir', continue from NEXT without asking the user; tell the worker the previous round was interrupted and to inspect the current diff first"
        exit 0
    }
}
