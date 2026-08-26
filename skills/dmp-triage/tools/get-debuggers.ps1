<#
 get-debuggers.ps1 - run on an INTERNET-CONNECTED machine.
 Obtains cdb.exe (Debugging Tools for Windows) and stages it into
 ..\bin\debuggers so `dmp-triage.ps1 package` can build the air-gap zip.

 Strategy:
   1) winget install Microsoft.WinDbg   (light, ~100MB, includes cdb.exe)
   2) fallback: tell the user how to get the Windows SDK "Debugging Tools
      for Windows" feature and copy the Debuggers\x64 folder manually.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Dest = Join-Path $Root 'bin\debuggers'

function Stage-From([string]$SrcDir) {
    Write-Host "[get-debuggers] staging from: $SrcDir"
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    Copy-Item -Path (Join-Path $SrcDir '*') -Destination $Dest -Recurse -Force
    # optional 12.7MB doc bundle - dead weight in the USB package
    Remove-Item -Path (Join-Path $Dest 'DebuggerDocs.zip') -Force -ErrorAction SilentlyContinue
    $cdb = Join-Path $Dest 'cdb.exe'
    if (Test-Path $cdb) {
        Write-Host "[get-debuggers] OK: $cdb"
        & $cdb -version
        return $true
    }
    return $false
}

# already-installed SDK debuggers?
foreach ($p in @('C:\Program Files (x86)\Windows Kits\10\Debuggers\x64',
                 'C:\Program Files\Windows Kits\10\Debuggers\x64')) {
    if (Test-Path (Join-Path $p 'cdb.exe')) {
        if (Stage-From $p) { return }
    }
}

# try winget WinDbg
$wg = Get-Command winget -ErrorAction SilentlyContinue
if ($wg) {
    Write-Host '[get-debuggers] installing Microsoft.WinDbg via winget...'
    winget install --id Microsoft.WinDbg -e --accept-source-agreements --accept-package-agreements
    $pkg = Get-AppxPackage -Name Microsoft.WinDbg -ErrorAction SilentlyContinue
    if ($pkg) {
        $amd64 = Get-ChildItem -Path $pkg.InstallLocation -Directory |
                 Where-Object { $_.Name -eq 'amd64' } | Select-Object -First 1
        if ($amd64 -and (Test-Path (Join-Path $amd64.FullName 'cdb.exe'))) {
            if (Stage-From $amd64.FullName) { return }
        }
    }
}

Write-Host @'
[get-debuggers] Automatic acquisition failed. Manual options:
  A. On any internet PC: winget install Microsoft.WinDbg
     then copy the "amd64" folder from
     C:\Program Files\WindowsApps\Microsoft.WinDbg_*\amd64
     into <dmp-triage>\bin\debuggers\
  B. Install the Windows SDK (developer.microsoft.com/windows/downloads/windows-sdk),
     selecting ONLY "Debugging Tools for Windows", then copy
     C:\Program Files (x86)\Windows Kits\10\Debuggers\x64  ->  bin\debuggers\
  C. Air-gap without any transfer: if any machine on the closed network already
     has the Windows SDK or WinDbg, copy its Debuggers\x64 folder - it is
     xcopy-portable (no installation or registry needed).
'@
