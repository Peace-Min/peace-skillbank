<#  Verify an existing dmp-triage install (no changes made). #>
[CmdletBinding()]
param([string]$InstallDir)
$ErrorActionPreference = 'Stop'
if (-not $InstallDir) { $InstallDir = Join-Path $env:USERPROFILE '.claude\skills\dmp-triage' }
$fail = 0
function Ok([string]$m)  { Write-Host "  [ok]   $m" -ForegroundColor Green }
function Bad([string]$m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fail++ }

Write-Host ""
Write-Host "dmp-triage install check: $InstallDir"
Write-Host ""
if (Test-Path -LiteralPath $InstallDir) { Ok "skill folder present" } else { Bad "skill folder missing"; }
$cli = Join-Path $InstallDir 'scripts\dmp-triage.ps1'
if (Test-Path -LiteralPath $cli) { Ok "CLI present" } else { Bad "CLI missing (scripts\dmp-triage.ps1)" }
$cdb = Join-Path $InstallDir 'bin\debuggers\cdb.exe'
if (Test-Path -LiteralPath $cdb) {
    $v = (& $cdb -version 2>&1 | Select-Object -First 1)
    Ok "cdb present - $v"
} else { Bad "cdb missing (bin\debuggers\cdb.exe) - analyze will run pre-triage only" }
foreach ($n in @('winext\ext.dll','dbgeng.dll')) {
    if (Test-Path -LiteralPath (Join-Path $InstallDir "bin\debuggers\$n")) { Ok "$n present" } else { Bad "$n missing" }
}
$sos = Join-Path $InstallDir 'bin\debuggers\winext\sos'
if (Test-Path -LiteralPath $sos) { Ok "SOS extension present (.NET managed stacks available)" } else { Bad "SOS extension missing" }
foreach ($v in @('DMP_TRIAGE_HOME','DMP_TRIAGE_CDB')) {
    $val = [Environment]::GetEnvironmentVariable($v, 'User')
    if (-not $val) { Write-Host "  [note] $v not set (path search will be used)" }
    elseif ($v -eq 'DMP_TRIAGE_CDB' -and -not (Test-Path -LiteralPath $val -PathType Leaf)) { Bad "$v points at a missing file: $val" }
    elseif ($v -eq 'DMP_TRIAGE_HOME' -and -not (Test-Path -LiteralPath $val)) { Bad "$v points at a missing folder: $val" }
    else { Ok "$v = $val" }
}
$cmd = Join-Path $env:USERPROFILE '.claude\commands\dmp-triage.md'
if (Test-Path -LiteralPath $cmd) { Ok "/dmp-triage slash command installed" } else { Write-Host "  [note] slash command not installed (optional)" }
if (Test-Path -LiteralPath $cli) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $cli check 2>&1
    if (($out | Where-Object { $_ -match 'cdb\.exe' } | Select-Object -First 1) -match 'NOT FOUND') {
        Bad "CLI cannot resolve cdb"
    } else { Ok "CLI resolves its bundled cdb" }
}
Write-Host ""
if ($fail -eq 0) { Write-Host "ALL CHECKS PASSED" -ForegroundColor Green; exit 0 }
Write-Host "$fail CHECK(S) FAILED" -ForegroundColor Red; exit 1
