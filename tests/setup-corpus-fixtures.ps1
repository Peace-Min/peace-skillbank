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

# Run the setup script as a child process with a controlled working directory so we can test the
# "default -SourceDir to the current directory" behavior deterministically.
function Invoke-Setup {
    param([string[]]$ScriptArgs = @(), [string]$WorkingDir = $RepositoryRoot)
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $allArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $setup) + $ScriptArgs
        $p = Start-Process -FilePath "powershell" -ArgumentList $allArgs -WorkingDirectory $WorkingDir `
            -NoNewWindow -Wait -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $out = (Get-Content -Raw -LiteralPath $outFile -ErrorAction SilentlyContinue)
        $out += (Get-Content -Raw -LiteralPath $errFile -ErrorAction SilentlyContinue)
        return [pscustomobject]@{ Code = $p.ExitCode; Out = [string]$out }
    }
    finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
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

# 1) No args: defaults to the current directory as the source. Run from an empty dir -> DLL not found.
$r = Invoke-Setup -WorkingDir $emptyDir
Check "no args falls back to current directory" ($r.Out -match 'using the current directory') $r.Out
Check "current-dir source with no DLL aborts non-zero" ($r.Code -ne 0) "exit $($r.Code)"
Check "current-dir source names the missing DLL folder" ($r.Out -match 'DLL folder') $r.Out

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
