#requires -Version 5.1
<#
    Behavioral fixture tests for the diagsession-memory-analysis skill's two pieces of core logic
    that validate.ps1 otherwise only syntax-checks:

      1. Extract-GcdumpsFromDiagSession / Format-DiagSessionEntrySummary
         (skills/.../scripts/extract-gcdump-reports.ps1) -- exercised against a SYNTHETIC .diagsession
         (a ZIP) built here. No dotnet-gcdump and no real Visual Studio session are needed: extraction
         and entry-summary do not invoke the tool.
      2. Test-DiagSessionAnalysisReport (tests/diagsession-report-contract.ps1) -- the 8-heading
         report contract, mirroring tests/verify-symbols-fixtures.ps1.

    The extract script is dot-sourced; its top-level pipeline self-skips when dot-sourced.
#>
param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression          # ZipArchive / ZipArchiveMode
Add-Type -AssemblyName System.IO.Compression.FileSystem  # ZipFile / ZipFileExtensions

$extractScript = Join-Path $RepositoryRoot "skills\diagsession-memory-analysis\scripts\extract-gcdump-reports.ps1"
$contractHelper = Join-Path $RepositoryRoot "tests\diagsession-report-contract.ps1"
foreach ($f in @($extractScript, $contractHelper)) {
    if (-not (Test-Path -LiteralPath $f)) { throw "Missing fixture target: $f" }
}

# Dot-source to load the functions; the guard in the script returns before the pipeline runs.
. $extractScript -InputPath "dot-source-only.gcdump"
. $contractHelper

$work = Join-Path $env:TEMP ("diagsession-fixtures-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null

function New-FixtureDiagSession {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object[]]$Entries   # each: @{ Name = "..."; Content = "..." }
    )
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    $zip = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($e in $Entries) {
            $entry = $zip.CreateEntry($e.Name)
            $stream = $entry.Open()
            try {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$e.Content)
                $stream.Write($bytes, 0, $bytes.Length)
            }
            finally { $stream.Dispose() }
        }
    }
    finally { $zip.Dispose() }
}

$failures = @()
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = "")
    if ($Ok) { Write-Host "  [ok]   $Name" }
    else { $script:failures += "  [FAIL] $Name$(if ($Detail) { " -- $Detail" })" }
}

# --- 1) Extraction: gcdump entries are selected, ordered, and the .heapstate is ignored ---
$dsPath = Join-Path $work "leak-test.diagsession"
New-FixtureDiagSession -Path $dsPath -Entries @(
    @{ Name = "snapshot-before.gcdump"; Content = "fake-gcdump-before" }
    @{ Name = "metadata/info.heapstate"; Content = "not-a-gcdump" }
    @{ Name = "snapshot-after.gcdump"; Content = "fake-gcdump-after" }
)
$extractDir = Join-Path $work "extract-ok"
New-Item -ItemType Directory -Path $extractDir | Out-Null
$result = @(Extract-GcdumpsFromDiagSession -DiagSessionPath $dsPath -ExtractDirectory $extractDir)

Check "extraction returns exactly the 2 gcdump entries" ($result.Count -eq 2) "got $($result.Count)"
Check "heapstate is excluded" (-not ($result.ArchiveEntry -match '\.heapstate$'))
Check "archive order preserved (before then after)" ($result[0].ArchiveEntry -eq "snapshot-before.gcdump" -and $result[1].ArchiveEntry -eq "snapshot-after.gcdump") "$($result[0].ArchiveEntry) / $($result[1].ArchiveEntry)"
Check "ArchiveIndex is 1-based sequential" ($result[0].ArchiveIndex -eq 1 -and $result[1].ArchiveIndex -eq 2)
Check "extracted files exist with NN- prefix" ((Test-Path -LiteralPath (Join-Path $extractDir "01-snapshot-before.gcdump")) -and (Test-Path -LiteralPath (Join-Path $extractDir "02-snapshot-after.gcdump")))

# --- 2) Extraction: a gcdump-less session escalates with the documented message ---
$noGcPath = Join-Path $work "heapstate-only.diagsession"
New-FixtureDiagSession -Path $noGcPath -Entries @(
    @{ Name = "snapshot.heapstate"; Content = "heapstate-only" }
    @{ Name = "trace.etl"; Content = "etl" }
)
$noGcExtract = Join-Path $work "extract-none"
New-Item -ItemType Directory -Path $noGcExtract | Out-Null
$threw = $false; $msg = ""
try { Extract-GcdumpsFromDiagSession -DiagSessionPath $noGcPath -ExtractDirectory $noGcExtract | Out-Null }
catch { $threw = $true; $msg = $_.Exception.Message }
Check "gcdump-less session throws" $threw
Check "error names the gcdump-only limitation" ($msg -match 'No \.gcdump files were found' -and $msg -match 'heapstate') $msg

# --- 3) Entry summary reports detected extensions ---
$archive = [System.IO.Compression.ZipFile]::OpenRead($noGcPath)
try { $summary = Format-DiagSessionEntrySummary -Entries @($archive.Entries) }
finally { $archive.Dispose() }
Check "entry summary lists .heapstate and .etl" ($summary -match '\.heapstate=1' -and $summary -match '\.etl=1') $summary

# --- 4) Report contract: a complete report passes, a missing-heading report fails ---
$headings = Get-DiagSessionAnalysisReportHeadings
$goodReport = Join-Path $work "good-report.md"
($headings -join "`r`n`r`nbody`r`n`r`n") | Out-File -FilePath $goodReport -Encoding utf8
Check "complete 8-heading report passes" ((Test-DiagSessionAnalysisReport -ResponsePath $goodReport) -eq $true)

$badReport = Join-Path $work "bad-report.md"
(($headings | Select-Object -First 5) -join "`r`n`r`nbody`r`n`r`n") | Out-File -FilePath $badReport -Encoding utf8
$contractThrew = $false
try { Test-DiagSessionAnalysisReport -ResponsePath $badReport | Out-Null } catch { $contractThrew = $true }
Check "incomplete report fails the contract" $contractThrew

# --- 5) Invoke-GcdumpReport must not deadlock on large stdout+stderr (regression guard for the
#        concurrent ReadToEndAsync fix), must append stderr after stdout, and must throw on non-zero
#        exit. A stub console exe emits ~200 KB to each stream (well past the OS pipe buffer); a
#        regression to sequential ReadToEnd()+WaitForExit() would deadlock and time out the job. ---
$stubExe = Join-Path $work "gcdump-stub.exe"
$stubSrc = @"
using System;
class P {
  static int Main(string[] a) {
    string p = a.Length > 1 ? a[1] : "";
    if (p.IndexOf("FAIL", StringComparison.OrdinalIgnoreCase) >= 0) { Console.Error.Write("boom-failure"); return 1; }
    var big = new string('x', 200000);
    Console.Out.Write(big);
    Console.Error.Write(big);
    return 0;
  }
}
"@
$stubBuilt = $true
try { Add-Type -TypeDefinition $stubSrc -OutputAssembly $stubExe -OutputType ConsoleApplication -ErrorAction Stop }
catch { $stubBuilt = $false; Write-Host "  [skip] C# stub compile unavailable; skipping Invoke-GcdumpReport large-output test" }

if ($stubBuilt) {
    $bigGc = Join-Path $work "big.gcdump"
    $failGc = Join-Path $work "FAIL.gcdump"
    Set-Content -LiteralPath $bigGc -Value "x"
    Set-Content -LiteralPath $failGc -Value "x"

    $okJob = Start-Job -ScriptBlock {
        param($script, $exe, $gc)
        . $script -InputPath "dot-source-only.gcdump"
        Invoke-GcdumpReport -Tool $exe -GcdumpPath $gc
    } -ArgumentList $extractScript, $stubExe, $bigGc
    if (Wait-Job $okJob -Timeout 30) {
        $combined = (Receive-Job $okJob) -join ""
        Remove-Job $okJob -Force
        Check "Invoke-GcdumpReport returns on large stdout+stderr (no deadlock)" $true
        Check "large stdout+stderr combined (~400KB)" ($combined.Length -ge 390000) "len=$($combined.Length)"
    }
    else {
        Stop-Job $okJob -ErrorAction SilentlyContinue; Remove-Job $okJob -Force -ErrorAction SilentlyContinue
        Check "Invoke-GcdumpReport returns on large stdout+stderr (no deadlock)" $false "timed out -- likely a sequential-read regression"
    }

    $failJob = Start-Job -ScriptBlock {
        param($script, $exe, $gc)
        . $script -InputPath "dot-source-only.gcdump"
        try { Invoke-GcdumpReport -Tool $exe -GcdumpPath $gc | Out-Null; "NOTHROW" }
        catch { "THREW:" + $_.Exception.Message }
    } -ArgumentList $extractScript, $stubExe, $failGc
    if (Wait-Job $failJob -Timeout 30) {
        $fr = (Receive-Job $failJob) -join ""
        Remove-Job $failJob -Force
        Check "non-zero gcdump exit throws with stderr in the message" (($fr -like "THREW:*") -and ($fr -match "boom-failure")) $fr
    }
    else {
        Stop-Job $failJob -ErrorAction SilentlyContinue; Remove-Job $failJob -Force -ErrorAction SilentlyContinue
        Check "non-zero gcdump exit throws with stderr in the message" $false "timed out"
    }
}

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

if ($failures.Count -gt 0) {
    throw ("diagsession fixture tests failed:`n" + ($failures -join "`n"))
}
Write-Host "diagsession fixture tests passed."
