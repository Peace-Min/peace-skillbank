#requires -Version 5.1
<#
    Behavioral fixture tests for skills/lightningchart-72/scripts/setup-local-corpus.ps1.

    Covers the deterministic preflight / auto-detect / fail-fast paths that need no real licensed
    corpus, Python build, or DLL load: missing inputs, missing DLL folder, DLL auto-detected but
    missing manual PDF. The script is run as a child process so its `exit` does not end this runner.
#>
param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"

$setup = Join-Path $RepositoryRoot "skills\lightningchart-72\scripts\setup-local-corpus.ps1"
if (-not (Test-Path -LiteralPath $setup)) { throw "Missing setup CLI: $setup" }

function Invoke-Setup {
    param([string[]]$ScriptArgs)
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $setup @ScriptArgs 2>&1 | Out-String
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

$work = Join-Path $env:TEMP ("setup-corpus-fixtures-" + [System.Guid]::NewGuid().ToString("N"))
$emptyDir = Join-Path $work "empty"
$dllOnlyDir = Join-Path $work "dll-only"
New-Item -ItemType Directory -Path $emptyDir | Out-Null
New-Item -ItemType Directory -Path $dllOnlyDir | Out-Null
# A fake main assembly so DLL auto-detection succeeds (existence only; never loaded in preflight).
New-Item -ItemType File -Path (Join-Path $dllOnlyDir "Vendor.LightningChartUltimate.WPF.dll") | Out-Null

$failures = @()
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = "")
    if ($Ok) { Write-Host "  [ok]   $Name" }
    else { $script:failures += "  [FAIL] $Name$(if ($Detail) { " -- $Detail" })" }
}

# 1) No inputs at all -> abort with usage guidance.
$r = Invoke-Setup @()
Check "no inputs aborts non-zero" ($r.Code -ne 0) "exit $($r.Code)"
Check "no inputs explains the inputs needed" ($r.Out -match 'No inputs given') $r.Out

# 2) SourceDir present but empty -> cannot find the DLL folder.
$r = Invoke-Setup @("-SourceDir", $emptyDir)
Check "empty SourceDir aborts non-zero" ($r.Code -ne 0) "exit $($r.Code)"
Check "empty SourceDir names the missing DLL folder" ($r.Out -match 'DLL folder') $r.Out

# 3) DLL auto-detected, but no manual PDF -> abort naming the PDF (proves DLL detection ran first).
$r = Invoke-Setup @("-SourceDir", $dllOnlyDir)
Check "dll-only SourceDir aborts non-zero" ($r.Code -ne 0) "exit $($r.Code)"
Check "dll-only SourceDir auto-detected the DLL folder" ($r.Out -match 'Auto-detected DLL folder') $r.Out
Check "dll-only SourceDir names the missing manual PDF" ($r.Out -match "User's Manual PDF") $r.Out

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

if ($failures.Count -gt 0) {
    throw ("setup-local-corpus fixture tests failed:`n" + ($failures -join "`n"))
}
Write-Host "setup-local-corpus fixture tests passed."
