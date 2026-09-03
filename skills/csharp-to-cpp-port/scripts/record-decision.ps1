param(
    [string]$CppRoot,
    [string]$WorkDir,

    # Short stable id (e.g. "ui", "config", "color"). Existing ids are updated, new ids appended.
    [string]$Id,

    [string]$Topic,
    # What was actually decided ("Win32", "std::wstring", "App.ini + GetPrivateProfileStringW", ...).
    [string]$Decision,
    # human  = the user answered a question; default = the skill's standing default was applied;
    # skill  = the mapping table already fixed it (no judgment involved).
    [ValidateSet("human", "default", "skill")]
    [string]$Source = "human",
    [string]$Rationale,
    [string]$Review,     # why this may need revisiting
    [string]$Affects,    # "all units" or a unit/directory list
    [ValidateSet("pending", "accepted", "revisit")]
    [string]$Status = "pending",
    [switch]$List,
    # Re-render DECISIONS.md from decisions.json without changing anything.
    [switch]$Render
)

# Appends or updates one project-level decision in port-work\decisions.json and re-renders DECISIONS.md.
# Every question the model asks the human MUST end here, so the whole set can be reviewed later.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0
$utf8 = New-Object System.Text.UTF8Encoding($false)

if (-not $WorkDir) {
    if ($CppRoot) { $WorkDir = Join-Path $CppRoot "port-work" }
    else { $WorkDir = Join-Path (Get-Location).Path "port-work" }
}
$jsonPath = Join-Path $WorkDir "decisions.json"
$mdPath = Join-Path $WorkDir "DECISIONS.md"
if (-not (Test-Path -LiteralPath $WorkDir)) { [Console]::Error.WriteLine("record-decision: work dir not found: $WorkDir (pass -CppRoot <C++ root>). Run inventory-csharp.ps1 first."); exit 2 }

$doc = $null
if (Test-Path -LiteralPath $jsonPath) { $doc = Get-Content -Raw -LiteralPath $jsonPath | ConvertFrom-Json }
if ($null -eq $doc) { $doc = [pscustomobject]@{ generatedAt = [DateTimeOffset]::Now.ToString("o"); decisions = @() } }
$items = @($doc.decisions)

if ($List) {
    Write-Host "record-decision: $($items.Count) decision(s) in $jsonPath"
    foreach ($d in $items) { Write-Host ("  [{0}] {1}`t{2}`t(source={3}, status={4})" -f $d.id, $d.topic, $d.decision, $d.source, $d.status) }
    exit 0
}

if ($Render) {
    if ($items.Count -eq 0) { Write-Host "record-decision: nothing to render"; exit 0 }
    $action = "rendered"
    $entry = $null
}
elseif (-not $Id) { [Console]::Error.WriteLine("record-decision: -Id is required (or use -List / -Render)"); exit 2 }
$hit = @()
if (-not $Render) { $hit = @($items | Where-Object { $_.id -ieq $Id }) }
if (-not $Render -and $hit.Count -eq 0) {
    $entry = [pscustomobject]@{
        id = $Id; topic = $(if ($Topic) { $Topic } else { $Id }); decision = $Decision; source = $Source
        rationale = $Rationale; review = $Review; affects = $(if ($Affects) { $Affects } else { "all units" })
        status = $Status; updatedAt = [DateTimeOffset]::Now.ToString("s")
    }
    $items += $entry
    $action = "added"
}
elseif (-not $Render) {
    $entry = $hit[0]
    if ($PSBoundParameters.ContainsKey("Topic")) { $entry.topic = $Topic }
    if ($PSBoundParameters.ContainsKey("Decision")) { $entry.decision = $Decision }
    if ($PSBoundParameters.ContainsKey("Source")) { $entry.source = $Source }
    if ($PSBoundParameters.ContainsKey("Rationale")) { $entry.rationale = $Rationale }
    if ($PSBoundParameters.ContainsKey("Review")) { $entry.review = $Review }
    if ($PSBoundParameters.ContainsKey("Affects")) { $entry.affects = $Affects }
    if ($PSBoundParameters.ContainsKey("Status")) { $entry.status = $Status }
    $entry.updatedAt = [DateTimeOffset]::Now.ToString("s")
    $action = "updated"
}

$doc.decisions = $items
if (-not $Render) { [System.IO.File]::WriteAllText($jsonPath, ($doc | ConvertTo-Json -Depth 5), $utf8) }

# Re-render the human-readable table (pending first, then revisit, then accepted).
$rank = @{ "pending" = 0; "revisit" = 1; "accepted" = 2 }
$sorted = @($items | Sort-Object @{ Expression = { $rank[$_.status] } }, @{ Expression = { $_.id } })
$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine("# DECISIONS")
[void]$md.AppendLine("")
[void]$md.AppendLine('Every project-level choice this port depends on. Rows with source=default were applied by the')
[void]$md.AppendLine('skill without asking; source=human rows are answers you gave. Nothing here is checked by a')
[void]$md.AppendLine('compiler: review every row before the port is considered finished.')
[void]$md.AppendLine("")
$pending = @($items | Where-Object { $_.status -eq "pending" }).Count
[void]$md.AppendLine("Pending review: $pending of $($items.Count)")
[void]$md.AppendLine("")
[void]$md.AppendLine("| Status | Id | Topic | Decision | Source | Why it may need review | Affects |")
[void]$md.AppendLine("|--------|----|-------|----------|--------|------------------------|---------|")
foreach ($d in $sorted) {
    [void]$md.AppendLine("| $($d.status) | ``$($d.id)`` | $($d.topic) | $($d.decision) | $($d.source) | $($d.review) | $($d.affects) |")
}
[void]$md.AppendLine("")
[void]$md.AppendLine("## Rationale")
[void]$md.AppendLine("")
foreach ($d in $sorted) {
    if ($d.rationale) { [void]$md.AppendLine("- ``$($d.id)``: $($d.rationale)") }
}
[void]$md.AppendLine("")
[void]$md.AppendLine("Mark a row reviewed with:")
[void]$md.AppendLine("")
[void]$md.AppendLine('```powershell')
[void]$md.AppendLine('record-decision.ps1 -CppRoot <C++ root> -Id <id> -Status accepted')
[void]$md.AppendLine('```')
[System.IO.File]::WriteAllText($mdPath, $md.ToString(), $utf8)

if ($Render) { Write-Host "record-decision: $action DECISIONS.md" }
else { Write-Host "record-decision: $action [$Id] $($entry.decision) (source=$($entry.source), status=$($entry.status))" }
Write-Host "  $mdPath ($pending pending of $($items.Count))"
exit 0
