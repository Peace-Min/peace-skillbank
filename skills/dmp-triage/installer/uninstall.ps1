<#  Remove the dmp-triage install. Analysis outputs are never touched. #>
[CmdletBinding()]
param([string]$InstallDir, [switch]$Force)
$ErrorActionPreference = 'Stop'
if (-not $InstallDir) { $InstallDir = Join-Path $env:USERPROFILE '.claude\skills\dmp-triage' }
$cmd = Join-Path $env:USERPROFILE '.claude\commands\dmp-triage.md'
Write-Host ""
Write-Host "This will delete:"
Write-Host "  $InstallDir"
if (Test-Path -LiteralPath $cmd) { Write-Host "  $cmd" }
if (-not $Force) {
    $a = Read-Host "Proceed? (y/N)"
    if ($a -notmatch '^[Yy]') { Write-Host "Cancelled."; exit 0 }
}
if (Test-Path -LiteralPath $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force; Write-Host "removed: $InstallDir" }
if (Test-Path -LiteralPath $cmd) { Remove-Item -LiteralPath $cmd -Force; Write-Host "removed: $cmd" }
foreach ($v in @('DMP_TRIAGE_HOME','DMP_TRIAGE_CDB')) {
    if ([Environment]::GetEnvironmentVariable($v, 'User')) {
        [Environment]::SetEnvironmentVariable($v, $null, 'User')
        Write-Host "removed user variable: $v"
    }
}
Write-Host "Uninstalled. Your dump reports and dumps were not touched."
exit 0
