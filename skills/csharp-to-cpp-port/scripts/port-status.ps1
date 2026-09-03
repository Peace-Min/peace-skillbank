param(
    # Either -CppRoot (work dir = <CppRoot>\port-work) or -WorkDir.
    [string]$CppRoot,
    [string]$WorkDir,
    # Unit path from PORT_ORDER.txt, a member file of a partial unit, or the "a.cs+b.Designer.cs" form.
    [string]$Unit,
    [ValidateSet("todo", "translated", "builds", "verified", "blocked", "skipped")]
    [string]$State,
    [string]$Note,
    # With -Unit/-State: also set every already-built dependent of the unit back to todo (its header changed).
    [switch]$StaleDependents,
    # Print the units that depend on -Unit (from inventory.json) and their states; no change.
    [switch]$DependentsOf,
    # Print the next unit to port (first todo in PORT_ORDER.txt order); no change.
    [switch]$Next,
    [switch]$Show
)

# Tracks per-unit porting progress in status.json and renders PORT_STATUS.md.
# States: todo -> translated (files written) -> builds (build-check PASS) -> verified (parity/human);
# blocked = needs a human (or waits on a blocked dependency); skipped = generated/metadata file, never ported.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0
$utf8 = New-Object System.Text.UTF8Encoding($false)

if (-not $WorkDir) {
    if ($CppRoot) { $WorkDir = Join-Path $CppRoot "port-work" }
    else { $WorkDir = Join-Path (Get-Location).Path "port-work" }
}
$statusJson = Join-Path $WorkDir "status.json"
$statusMd = Join-Path $WorkDir "PORT_STATUS.md"
$inventoryPath = Join-Path $WorkDir "inventory.json"
$orderPath = Join-Path $WorkDir "PORT_ORDER.txt"
if (-not (Test-Path -LiteralPath $statusJson)) { [Console]::Error.WriteLine("port-status: status.json not found in $WorkDir (pass -CppRoot <C++ root> or -WorkDir). Run inventory-csharp.ps1 first."); exit 2 }
$status = Get-Content -Raw -LiteralPath $statusJson | ConvertFrom-Json
$units = @($status.units)
$orderUnits = @()
if (Test-Path -LiteralPath $orderPath) { $orderUnits = @(Get-Content -LiteralPath $orderPath | ForEach-Object { ($_ -split "`t")[1] }) }

function Find-Unit {
    param([string]$Name)
    $norm = $Name.Replace('/', '\')
    if ($norm.Contains('+')) { $norm = ($norm -split '\+')[0] }
    $hit = @($units | Where-Object { $_.unit -ieq $norm })
    if ($hit.Count -eq 0 -and (Test-Path -LiteralPath $inventoryPath)) {
        $inv = Get-Content -Raw -LiteralPath $inventoryPath | ConvertFrom-Json
        $iu = @($inv.units | Where-Object { @($_.files) -contains $norm })
        if ($iu.Count -gt 0) { $hit = @($units | Where-Object { $_.unit -ieq $iu[0].path }) }
    }
    return $hit
}
function Get-Dependents {
    param([string]$UnitPath)
    if (-not (Test-Path -LiteralPath $inventoryPath)) { return @() }
    $inv = Get-Content -Raw -LiteralPath $inventoryPath | ConvertFrom-Json
    return @($inv.units | Where-Object { @($_.deps) -contains $UnitPath } | ForEach-Object { $_.path })
}
function Get-NextUnit {
    # First todo in work-list order (PORT_ORDER.txt), falling back to status order.
    $todo = @{}
    foreach ($u in $units) { if ($u.state -eq "todo") { $todo[$u.unit] = $true } }
    foreach ($o in $orderUnits) { if ($todo.ContainsKey($o)) { return $o } }
    foreach ($u in $units) { if ($u.state -eq "todo" -and ($orderUnits.Count -eq 0)) { return $u.unit } }
    return $null
}

if ($DependentsOf) {
    if (-not $Unit) { [Console]::Error.WriteLine("port-status: -DependentsOf needs -Unit"); exit 2 }
    $hit = @(Find-Unit $Unit)
    if ($hit.Count -eq 0) { [Console]::Error.WriteLine("port-status: unit not in inventory: $Unit"); exit 2 }
    $deps = @(Get-Dependents $hit[0].unit)
    Write-Host "port-status: $($deps.Count) unit(s) depend on $($hit[0].unit)"
    foreach ($d in $deps) { $s = @($units | Where-Object { $_.unit -ieq $d }); Write-Host ("  {0}`t{1}" -f $d, $(if ($s.Count -gt 0) { $s[0].state } else { "?" })) }
    exit 0
}
if ($Next) {
    $n = Get-NextUnit
    if ($n) { Write-Host "NEXT: $n" } else { Write-Host "NEXT: (none: all units past todo)" }
    exit 0
}

$changed = @()
if ($Unit) {
    if (-not $State) { [Console]::Error.WriteLine("port-status: -State is required with -Unit"); exit 2 }
    $hit = @(Find-Unit $Unit)
    if ($hit.Count -eq 0) {
        [Console]::Error.WriteLine("port-status: unit not in inventory: $Unit")
        [Console]::Error.WriteLine("  known units: " + (($units | ForEach-Object { $_.unit }) -join ', '))
        exit 2
    }
    $hit[0].state = $State
    $hit[0].updatedAt = [DateTimeOffset]::Now.ToString("s")
    if ($PSBoundParameters.ContainsKey("Note")) { $hit[0].note = $Note }
    $changed += "$($hit[0].unit) -> $State"
    if ($StaleDependents) {
        foreach ($d in @(Get-Dependents $hit[0].unit)) {
            $s = @($units | Where-Object { $_.unit -ieq $d })
            if ($s.Count -gt 0 -and $s[0].state -in @("builds", "verified", "translated")) {
                $s[0].state = "todo"; $s[0].updatedAt = [DateTimeOffset]::Now.ToString("s"); $s[0].note = "stale: $($hit[0].unit) re-ported; rebuild"
                $changed += "$d -> todo (stale)"
            }
        }
    }
    $status.updatedAt = [DateTimeOffset]::Now.ToString("o")
    [System.IO.File]::WriteAllText($statusJson, ($status | ConvertTo-Json -Depth 4), $utf8)
}

$counts = [ordered]@{ todo = 0; translated = 0; builds = 0; verified = 0; blocked = 0; skipped = 0 }
foreach ($u in $units) { if ($counts.Contains($u.state)) { $counts[$u.state]++ } }
$nextUnit = Get-NextUnit
$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine("# PORT_STATUS"); [void]$md.AppendLine("")
[void]$md.AppendLine("Updated: $($status.updatedAt)"); [void]$md.AppendLine("")
[void]$md.AppendLine("Totals: " + (($counts.Keys | ForEach-Object { "$_=$($counts[$_])" }) -join ", ") + " (of $($units.Count))"); [void]$md.AppendLine("")
$nextCell = if ($nextUnit) { '`' + $nextUnit + '`' } else { "(none: all units past todo)" }
[void]$md.AppendLine("Next unit (work-list order): $nextCell"); [void]$md.AppendLine("")
[void]$md.AppendLine("| # | Unit | State | Updated | Note |"); [void]$md.AppendLine("|---|------|-------|---------|------|")
$i = 0
foreach ($u in $units) { $i++; [void]$md.AppendLine("| $i | ``$($u.unit)`` | $($u.state) | $($u.updatedAt) | $($u.note) |") }
[System.IO.File]::WriteAllText($statusMd, $md.ToString(), $utf8)

if ($changed.Count -gt 0) { foreach ($c in $changed) { Write-Host "port-status: $c" } }
if ($Show -or -not $Unit) { Write-Host ("port-status: " + (($counts.Keys | ForEach-Object { "$_=$($counts[$_])" }) -join ", ")) }
if ($nextUnit) { Write-Host "NEXT: $nextUnit" } else { Write-Host "NEXT: (none: all units past todo)" }
exit 0
