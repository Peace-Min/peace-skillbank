<#
.SYNOPSIS
    feature-flow state helper. Deterministic parts of the workflow live here so the
    orchestrating model never has to "remember" state: work-folder creation, the event
    log, the mechanical gates, the round diff, and loop/send-back counting.

.DESCRIPTION
    Commands:
      init        Create work/<stamp>-<slug>/ with the standard layout; record the git base.
      event       Append one line to events.log. Exit 3 on loop limit or send-back limit.
      check-todo  Gate for TODO items (see -Prefix, -AllowOpen, -FormatOnly).
      diff        Save the round diff vs the recorded base (tracked + untracked, work/ excluded).
      wiki-check  Verify docs/wiki/index.md exists and every relative .md link in docs/wiki resolves.
      status      Print stage, round/send-back counts, TODO progress and the next action.

    Exit codes: 0 ok, 1 check failed, 2 usage/input error, 3 limit reached.
    ASCII-only on purpose: Windows PowerShell 5.1 misreads BOM-less UTF-8 scripts.
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("init", "event", "check-todo", "diff", "wiki-check", "status")]
    [string]$Command,
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
$validStatus = @("START", "PASS", "FAIL", "BLOCKED_ENV", "BLOCKED_PERMISSION", "NEEDS_DECISION", "LOOP_LIMIT", "RESUME")
$utf8 = New-Object System.Text.UTF8Encoding($false)

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
    # 0. Run git in the project root; return stdout lines and the exit code without throwing.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $out = & git -C $Root @GitArgs 2>$null
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
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

function Get-FailCount([object[]]$Events, [string]$ForStage) {
    # 0. Count FAILs for the stage since its last START/PASS/RESUME.
    $count = 0
    foreach ($e in $Events) {
        if ($e.Stage -ne $ForStage) { continue }
        if ($e.Status -eq "FAIL") { $count++ }
        elseif ($e.Status -in @("START", "PASS", "RESUME")) { $count = 0 }
    }
    return $count
}

function Get-SendBackCount([object[]]$Events) {
    # 0. QA send-backs are FAIL events on stage qa whose note starts with "sendback=".
    return @($Events | Where-Object { $_.Stage -eq "qa" -and $_.Status -eq "FAIL" -and $_.Note -match '^sendback=' }).Count
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

function Resolve-InProject([string]$Rel, [string]$Dir) {
    foreach ($base in @($Root, $Dir)) {
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
    }
    return ""
}

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
        $spec = "# Spec: $Title`n`n## Goal`n`n## In scope`n`n## Out of scope`n`n## Constraints / cautions`n`n## Acceptance criteria`n`n## Verify commands`n- build:`n- test:`n"
        [System.IO.File]::WriteAllText((Join-Path $dir "00-context.md"), $context, $utf8)
        [System.IO.File]::WriteAllText((Join-Path $dir "01-spec.md"), $spec, $utf8)
        [System.IO.File]::WriteAllText((Join-Path $dir "events.log"), "", $utf8)
        Write-Output $dir
        exit 0
    }

    "event" {
        $dir = Resolve-WorkDir
        if ($Stage -notin $validStages) { Fail-Usage "-Stage must be one of: $($validStages -join ', ')" }
        if ($Status -notin $validStatus) { Fail-Usage "-Status must be one of: $($validStatus -join ', ')" }
        $clean = (($Note -replace '[\r\n|]+', ' ') -replace '\s+', ' ').Trim()
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
                $t = $token.Trim().Trim('`')
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
        exit 0
    }

    "wiki-check" {
        $wiki = Join-Path $Root "docs\wiki"
        $index = Join-Path $wiki "index.md"
        if (-not (Test-Path -LiteralPath $index)) { Write-Output "MISSING   docs/wiki/index.md"; exit 1 }
        $bad = 0; $pages = 0
        foreach ($page in (Get-ChildItem -LiteralPath $wiki -Filter "*.md" -File -Recurse)) {
            $pages++
            $text = [System.IO.File]::ReadAllText($page.FullName)
            foreach ($m in [regex]::Matches($text, '\]\(([^)#\s]+\.md)(#[^)]*)?\)')) {
                $target = $m.Groups[1].Value
                if ($target -match '^[a-z]+://') { continue }
                if (-not (Test-Path -LiteralPath (Join-Path $page.DirectoryName $target))) {
                    Write-Output "BROKEN    $($page.FullName.Substring($Root.Length).TrimStart('\')) -> $target"; $bad++
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
        Write-Output "FAILS     $fails since last PASS/START/RESUME (max $MaxRounds)"
        Write-Output "SENDBACKS $(Get-SendBackCount $events) (max $MaxQaCycles)"
        $items = Get-TodoItems $dir
        if ($null -ne $items) {
            foreach ($p in @("D", "Q")) {
                $group = @($items | Where-Object { $_.Id -like "$p*" })
                if ($group.Count -gt 0) { Write-Output ("TODO-{0}    {1}/{2} checked" -f $p, @($group | Where-Object { $_.Checked }).Count, $group.Count) }
            }
        }

        # 0. Next action, so a resumed (or weak) orchestrator does not have to infer it.
        $order = @("intake", "plan", "dev", "qa", "wiki", "done")
        $next = switch ($last.Status) {
            "PASS" { $i = [array]::IndexOf($order, $last.Stage); if ($i -lt $order.Count - 1) { "$($order[$i + 1]) START" } else { "finished" } }
            "FAIL" { "$($last.Stage) round $($fails + 1)" }
            "START" { "$($last.Stage) round 1" }
            "RESUME" { "$($last.Stage) round $($fails + 1)" }
            default { "escalated ($($last.Status)); wait for the user, then log RESUME" }
        }
        Write-Output "NEXT      $next"
        Write-Output "RECENT"
        $events | Select-Object -Last 5 | ForEach-Object { Write-Output "  $($_.Time) $($_.Stage) $($_.Status) $($_.Round) $($_.Note)" }
        exit 0
    }
}
