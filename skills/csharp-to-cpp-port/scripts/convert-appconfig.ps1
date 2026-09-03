param(
    # App.config / Web.config to convert (appSettings only).
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    # Where the .ini goes. Default: <CppRoot>\App.ini . At runtime PortSupport::AppSetting reads
    # <exe path without extension>.ini, so copy/rename it next to the built executable.
    [string]$CppRoot,
    [string]$OutputPath
)

# Turns <appSettings><add key="X" value="Y"/></appSettings> into an INI file the ported C++ can read
# with PortSupport::AppSetting (Win32 GetPrivateProfileStringW, no XML dependency).
# Everything else in the config file (connectionStrings, custom sections) is reported, never guessed.
# Exit codes: 0 = written, 1 = written but sections were skipped, 2 = input problem.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0
$utf8 = New-Object System.Text.UTF8Encoding($false)

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { [Console]::Error.WriteLine("convert-appconfig: file not found: $ConfigPath"); exit 2 }
if (-not $OutputPath) {
    if ($CppRoot) { $OutputPath = Join-Path $CppRoot "App.ini" }
    else { $OutputPath = Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $ConfigPath).Path) "App.ini" }
}

try { $xml = [xml](Get-Content -Raw -LiteralPath $ConfigPath) }
catch { [Console]::Error.WriteLine("convert-appconfig: not valid XML: $ConfigPath ($($_.Exception.Message))"); exit 2 }

$lines = New-Object System.Collections.ArrayList
[void]$lines.Add("; Generated from " + (Split-Path -Leaf $ConfigPath) + " by convert-appconfig.ps1. appSettings only.")
[void]$lines.Add("[appSettings]")
$count = 0
$adds = @($xml.SelectNodes("//appSettings/add"))
foreach ($a in $adds) {
    $k = $a.GetAttribute("key"); $v = $a.GetAttribute("value")
    if (-not $k) { continue }
    [void]$lines.Add("$k=$v")
    $count++
}
[System.IO.File]::WriteAllText($OutputPath, (($lines -join "`r`n") + "`r`n"), $utf8)

$skippedSections = @()
foreach ($name in @("connectionStrings", "configSections", "system.serviceModel", "system.diagnostics", "applicationSettings", "userSettings", "system.net")) {
    if (@($xml.SelectNodes("//$name")).Count -gt 0) { $skippedSections += $name }
}

Write-Host "convert-appconfig: $count appSettings key(s) -> $OutputPath"
Write-Host "  the ported program reads <exe path>.ini, so copy this next to the built .exe and rename it to match"
if ($skippedSections.Count -gt 0) {
    Write-Host "  NOT converted (handle by hand): $($skippedSections -join ', ')"
    exit 1
}
exit 0
