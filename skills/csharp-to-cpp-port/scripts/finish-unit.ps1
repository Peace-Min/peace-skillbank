param(
    [Parameter(Mandatory = $true)]
    [string]$CppRoot,

    # Unit path from PORT_ORDER.txt (or a member file / "a.cs+b.Designer.cs").
    [Parameter(Mandatory = $true)]
    [string]$Unit,

    [int]$MaxRounds = 3,
    [string]$WorkDir,
    [string[]]$IncludeDir,
    [string]$Standard = "c++17"
)

# One command the model runs after writing a unit's files: forbidden scan -> build check -> status.
# Prints a single RESULT line and a NEXT line so a weak model never has to decide what comes next.
#   RESULT: PASS                       unit marked builds; NEXT: <unit>
#   RESULT: FORBIDDEN (N)              fix the listed constructs, run finish-unit again (no round used)
#   RESULT: FAIL (round k of N)        re-run make-unit-prompt (errors embedded), fix only those, run finish-unit again
#   RESULT: BLOCKED                    N failed rounds; unit marked blocked; NEXT: <unit>
#   RESULT: MISSING <file>             the model did not write the file(s)
# Exit codes: 0 PASS, 1 FAIL/FORBIDDEN/BLOCKED, 2 environment/input problem.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0
$utf8 = New-Object System.Text.UTF8Encoding($false)
$scripts = $PSScriptRoot
function Write-Fail { param([string]$Message) [Console]::Error.WriteLine("finish-unit: $Message"); exit 2 }
function Invoke-Sibling {
    param([string]$Name, [string[]]$Arguments)
    $global:LASTEXITCODE = 0
    $ErrorActionPreference = "Continue"
    $text = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scripts $Name) @Arguments 2>&1 | ForEach-Object { "$_" }) -join "`n"
    return @{ code = $LASTEXITCODE; text = $text }
}

if (-not (Test-Path -LiteralPath $CppRoot -PathType Container)) { Write-Fail "CppRoot is not an existing directory: $CppRoot" }
$CppRoot = (Resolve-Path -LiteralPath $CppRoot).Path.TrimEnd('\')
if (-not $WorkDir) { $WorkDir = Join-Path $CppRoot "port-work" }
$inventoryPath = Join-Path $WorkDir "inventory.json"
$statusJson = Join-Path $WorkDir "status.json"
if (-not (Test-Path -LiteralPath $inventoryPath) -or -not (Test-Path -LiteralPath $statusJson)) { Write-Fail "inventory.json / status.json not found in $WorkDir. Run inventory-csharp.ps1 -CppRoot `"$CppRoot`" first." }

$inventory = Get-Content -Raw -LiteralPath $inventoryPath | ConvertFrom-Json
$norm = $Unit.Replace('/', '\')
if ($norm.Contains('+')) { $norm = ($norm -split '\+')[0] }
$entry = @($inventory.units | Where-Object { $_.path -ieq $norm -or (@($_.files) -contains $norm) })
if ($entry.Count -eq 0) { Write-Fail "unit not in inventory: $Unit" }
$entry = $entry[0]
$base = $entry.path -replace '\.cs$', ''
$cpp = Join-Path $CppRoot ($base + ".cpp")
$h = Join-Path $CppRoot ($base + ".h")
$relCpp = ($base + ".cpp").Replace('\', '/')

$status = Get-Content -Raw -LiteralPath $statusJson | ConvertFrom-Json
$su = @($status.units | Where-Object { $_.unit -ieq $entry.path })
if ($su.Count -eq 0) { Write-Fail "unit missing from status.json: $($entry.path)" }
$su = $su[0]
if (-not ($su.PSObject.Properties.Name -contains "attempts")) { $su | Add-Member -NotePropertyName attempts -NotePropertyValue 0 }
$previousState = $su.state

function Save-Status { [System.IO.File]::WriteAllText($statusJson, ($status | ConvertTo-Json -Depth 4), $utf8) }
function Show-Next {
    $n = Invoke-Sibling "port-status.ps1" @("-WorkDir", $WorkDir, "-Next")
    $line = @($n.text -split "`n" | Where-Object { $_ -match '^NEXT:' })
    if ($line.Count -gt 0) { Write-Host $line[0] } else { Write-Host "NEXT: (unknown)" }
}

# 1. files present?
if (-not (Test-Path -LiteralPath $cpp)) { Write-Host "RESULT: MISSING $cpp (write the file(s) named in UNIT_PROMPT.md, then run finish-unit again)"; exit 2 }
$files = @($cpp); if (Test-Path -LiteralPath $h) { $files += $h }

# 2. forbidden scan
$scan = Invoke-Sibling "scan-forbidden.ps1" @("-Path", ($files -join ','))
if ($scan.code -eq 1) {
    $hits = @($scan.text -split "`n" | Where-Object { $_ -match '\|error\|' })
    Write-Host "RESULT: FORBIDDEN ($($hits.Count)) - fix these constructs in the files you wrote, then run finish-unit again:"
    foreach ($x in $hits) { Write-Host "  $x" }
    exit 1
}
if ($scan.code -eq 2) { Write-Fail "scan-forbidden failed: $($scan.text)" }

# 3. build
$bcArgs = @("-CppRoot", $CppRoot, "-Unit", $relCpp, "-WorkDir", $WorkDir, "-Standard", $Standard)
if ($IncludeDir) { $bcArgs += @("-IncludeDir", ($IncludeDir -join ',')) }
$bc = Invoke-Sibling "build-check.ps1" $bcArgs
if ($bc.code -eq 2) {
    Write-Host "RESULT: NO_COMPILER - relay $WorkDir\BUILD_RESULT.txt (Checked / Remedy) to the user verbatim"
    Write-Host $bc.text
    exit 2
}
if ($bc.code -eq 0) {
    $su.attempts = 0
    Save-Status
    $psArgs = @("-WorkDir", $WorkDir, "-Unit", $entry.path, "-State", "builds", "-Note", "finish-unit PASS")
    if ($previousState -in @("builds", "verified")) { $psArgs += "-StaleDependents" }
    $ps = Invoke-Sibling "port-status.ps1" $psArgs
    Write-Host "RESULT: PASS - $($entry.path) compiles (not yet verified)$(if ($previousState -in @('builds','verified')) { '; dependents reset to todo (header changed)' })"
    Show-Next
    exit 0
}

# 4. FAIL: count the round
$su.attempts = [int]$su.attempts + 1
$errLines = @()
$brPath = Join-Path $WorkDir "BUILD_RESULT.txt"
if (Test-Path -LiteralPath $brPath) { $errLines = @(Get-Content -LiteralPath $brPath | Where-Object { $_ -match '^[^|#]+\|\d+\|' }) }
$first = if ($errLines.Count -gt 0) { $errLines[0] } else { "compile failed" }
if ([int]$su.attempts -ge $MaxRounds) {
    $su.attempts = 0
    Save-Status
    Invoke-Sibling "port-status.ps1" @("-WorkDir", $WorkDir, "-Unit", $entry.path, "-State", "blocked", "-Note", ("after $MaxRounds rounds: " + $first)) | Out-Null
    Write-Host "RESULT: BLOCKED - $($entry.path) failed $MaxRounds rounds; marked blocked (first error: $first). Report it to the user at the end and continue with the next unit."
    Show-Next
    exit 1
}
Save-Status
Invoke-Sibling "port-status.ps1" @("-WorkDir", $WorkDir, "-Unit", $entry.path, "-State", "translated", "-Note", ("round $($su.attempts) failed: " + $first)) | Out-Null
Write-Host "RESULT: FAIL (round $($su.attempts) of $MaxRounds) - $($errLines.Count) error line(s). Re-run make-unit-prompt.ps1 -Unit `"$($entry.path)`" -CppRoot `"$CppRoot`" (the errors are now embedded), fix ONLY those errors in the files you wrote, then run finish-unit again."
foreach ($x in ($errLines | Select-Object -First 10)) { Write-Host "  $x" }
exit 1
