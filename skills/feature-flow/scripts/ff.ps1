<#
.SYNOPSIS
    feature-flow state helper. Deterministic parts of the workflow live here so the
    orchestrating model never has to "remember" state: work-folder creation, the event
    log, the evidence gate for checked TODO items, and loop-limit counting.

.DESCRIPTION
    Commands:
      init        Create work/<stamp>-<slug>/ with the standard layout and templates.
      event       Append one line to events.log. Exit 3 when the stage hit -MaxRounds FAILs.
      check-todo  Verify every checked TODO item carries at least one resolvable evidence ref.
      status      Print the current stage, round count and TODO progress (for resume).

    Exit codes: 0 ok, 1 check failed, 2 usage/input error, 3 loop limit reached.
    ASCII-only on purpose: Windows PowerShell 5.1 misreads BOM-less UTF-8 scripts.
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("init", "event", "check-todo", "status")]
    [string]$Command,
    [string]$Root = (Get-Location).Path,
    [string]$WorkDir,
    [string]$Title,
    [string]$Stage,
    [string]$Status,
    [int]$Round = 0,
    [string]$Note = "",
    [string]$Prefix = "",
    [int]$MaxRounds = 3
)

$ErrorActionPreference = "Stop"
$validStages = @("intake", "plan", "dev", "qa", "wiki", "done")
$validStatus = @("START", "PASS", "FAIL", "BLOCKED_ENV", "BLOCKED_PERMISSION", "NEEDS_DECISION", "LOOP_LIMIT", "RESUME")

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

function Read-Events([string]$Dir) {
    $log = Join-Path $Dir "events.log"
    $events = @()
    if (-not (Test-Path -LiteralPath $log)) { return $events }
    foreach ($line in (Get-Content -LiteralPath $log -Encoding UTF8)) {
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

function Get-TodoItems([string]$Dir) {
    $todo = Join-Path $Dir "02-todo.md"
    if (-not (Test-Path -LiteralPath $todo)) { return $null }
    $items = @()
    $current = $null
    foreach ($line in (Get-Content -LiteralPath $todo -Encoding UTF8)) {
        $m = [regex]::Match($line, '^\s*-\s*\[( |x|X)\]\s*([A-Za-z]+\d+)\s*[:.)-]?\s*(.*)$')
        if ($m.Success) {
            $current = [pscustomobject]@{ Id = $m.Groups[2].Value; Checked = ($m.Groups[1].Value -ne " "); Text = $m.Groups[3].Value; Evidence = "" }
            $items += $current
            continue
        }
        if ($null -ne $current) {
            $ev = [regex]::Match($line, '^\s+-?\s*evidence\s*:\s*(.*)$', 'IgnoreCase')
            if ($ev.Success) { $current.Evidence = $ev.Groups[1].Value.Trim() }
        }
    }
    return $items
}

function Test-EvidenceRef([string]$Token, [string]$Dir) {
    # 0. A ref is "path" or "path:line" or "path:start-end"; resolved against the project root, then the work folder.
    $m = [regex]::Match($Token, '^(?<path>[^:*?"<>|]+?\.[A-Za-z0-9]+)(:(?<start>\d+)(-(?<end>\d+))?)?$')
    if (-not $m.Success) { return $null }
    $rel = $m.Groups["path"].Value.Trim().Trim('`')
    $resolved = $null
    foreach ($base in @($Root, $Dir)) {
        $p = $rel
        if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $base $rel }
        if (Test-Path -LiteralPath $p -PathType Leaf) { $resolved = $p; break }
    }
    if ($null -eq $resolved) { return "missing file: $rel" }
    if ($m.Groups["start"].Success) {
        $lineCount = (Get-Content -LiteralPath $resolved | Measure-Object -Line).Lines
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
        $utf8 = New-Object System.Text.UTF8Encoding($false)
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
        [System.IO.File]::AppendAllText((Join-Path $dir "events.log"), $line + "`n", (New-Object System.Text.UTF8Encoding($false)))
        Write-Output $line

        # 1. Loop guard: the orchestrator must stop and escalate when this trips.
        $fails = Get-FailCount -Events (Read-Events $dir) -ForStage $Stage
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
        if ($Prefix) { $items = @($items | Where-Object { $_.Id -like "$Prefix*" }) }
        if ($items.Count -eq 0) { Fail-Usage "No TODO items found (prefix '$Prefix'). Expected lines like '- [ ] D1: ...'." }

        $bad = 0
        foreach ($item in $items) {
            if (-not $item.Checked) { Write-Output "OPEN      $($item.Id)  $($item.Text)"; $bad++; continue }
            if ([string]::IsNullOrWhiteSpace($item.Evidence)) { Write-Output "NO-EVID   $($item.Id)  checked without an 'evidence:' line"; $bad++; continue }

            # 0. At least one token must be a verifiable file ref; every file ref must resolve.
            $refs = 0; $problems = @()
            foreach ($token in ($item.Evidence -split '[|;,\s]+')) {
                $t = $token.Trim().Trim('`')
                if (-not $t) { continue }
                $result = Test-EvidenceRef -Token $t -Dir $dir
                if ($null -eq $result) { continue }
                $refs++
                if ($result) { $problems += $result }
            }
            if ($refs -eq 0) { Write-Output "NO-REF    $($item.Id)  evidence has no file ref (path or path:line)"; $bad++ }
            elseif ($problems.Count -gt 0) { Write-Output "BAD-REF   $($item.Id)  $($problems -join '; ')"; $bad++ }
            else { Write-Output "OK        $($item.Id)" }
        }
        Write-Output ("SUMMARY   {0} item(s), {1} problem(s)" -f $items.Count, $bad)
        if ($bad -gt 0) { exit 1 }
        exit 0
    }

    "status" {
        $dir = Resolve-WorkDir
        $events = @(Read-Events $dir)
        Write-Output "WORKDIR   $dir"
        if ($events.Count -eq 0) { Write-Output "STAGE     (no events yet)"; exit 0 }
        $last = $events[$events.Count - 1]
        Write-Output "STAGE     $($last.Stage)  last=$($last.Status) $($last.Round)"
        Write-Output "FAILS     $(Get-FailCount -Events $events -ForStage $last.Stage) since last PASS/START (max $MaxRounds)"
        $items = Get-TodoItems $dir
        if ($null -ne $items) {
            foreach ($p in @("D", "Q")) {
                $group = @($items | Where-Object { $_.Id -like "$p*" })
                if ($group.Count -gt 0) { Write-Output ("TODO-{0}    {1}/{2} checked" -f $p, @($group | Where-Object { $_.Checked }).Count, $group.Count) }
            }
        }
        Write-Output "RECENT"
        $events | Select-Object -Last 5 | ForEach-Object { Write-Output "  $($_.Time) $($_.Stage) $($_.Status) $($_.Round) $($_.Note)" }
        exit 0
    }
}
