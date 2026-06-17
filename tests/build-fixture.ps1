param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [int]$GrowSeconds = 8,
    [string]$ToolPath
)

$ErrorActionPreference = "Stop"
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

Add-Type -AssemblyName System.IO.Compression.FileSystem

if (-not $ToolPath) {
    $ToolPath = Join-Path $env:USERPROFILE ".dotnet\tools\dotnet-gcdump.exe"
}
if (-not (Test-Path -LiteralPath $ToolPath)) {
    throw "dotnet-gcdump not found at $ToolPath. Install with 'dotnet tool install --global dotnet-gcdump' or pass -ToolPath."
}

$workRoot = Join-Path $RepositoryRoot "out\fixture"
$projDir = Join-Path $workRoot "leakapp"
$dumpDir = Join-Path $workRoot "gcdumps"
if (Test-Path -LiteralPath $projDir) { Remove-Item -Recurse -Force -LiteralPath $projDir }
New-Item -ItemType Directory -Force -Path $projDir, $dumpDir | Out-Null

# 1. Create a tiny .NET app that grows the managed heap (a List<byte[]> that never releases).
Push-Location $projDir
try {
    $newOut = & dotnet new console -o . --force 2>&1
    if ($LASTEXITCODE -ne 0) { throw "dotnet new failed: $newOut" }

    $program = @'
using System;
using System.Collections.Generic;
using System.Threading;

var leak = new List<byte[]>();
Console.WriteLine("leakapp pid=" + Environment.ProcessId);
while (true)
{
    leak.Add(new byte[1_000_000]);
    Thread.Sleep(250);
}
'@
    Set-Content -LiteralPath (Join-Path $projDir "Program.cs") -Value $program -Encoding utf8

    $buildOut = & dotnet build -c Release -v quiet 2>&1
    if ($LASTEXITCODE -ne 0) { throw "dotnet build failed: $buildOut" }
}
finally {
    Pop-Location
}

# 2. Launch the app so its PID is the runtime process (run the apphost exe, or 'dotnet <dll>').
$exe = Get-ChildItem -Path (Join-Path $projDir "bin\Release") -Recurse -Filter "leakapp.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($exe) {
    $proc = Start-Process -FilePath $exe.FullName -PassThru -WindowStyle Hidden
}
else {
    $dll = Get-ChildItem -Path (Join-Path $projDir "bin\Release") -Recurse -Filter "leakapp.dll" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $dll) { throw "Built leakapp output not found." }
    $proc = Start-Process -FilePath "dotnet" -ArgumentList ('"' + $dll.FullName + '"') -PassThru -WindowStyle Hidden
}

function Invoke-GcdumpCollect {
    param([int]$ProcessId, [string]$OutputFile)
    $out = & $ToolPath collect -p $ProcessId -o $OutputFile 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutputFile)) {
        throw "dotnet-gcdump collect failed for pid ${ProcessId}: $out"
    }
}

$snap1 = Join-Path $dumpDir "Snapshot1-before.gcdump"
$snap2 = Join-Path $dumpDir "Snapshot2-after.gcdump"
try {
    Start-Sleep -Seconds 2
    Invoke-GcdumpCollect -ProcessId $proc.Id -OutputFile $snap1
    Start-Sleep -Seconds $GrowSeconds
    Invoke-GcdumpCollect -ProcessId $proc.Id -OutputFile $snap2
}
finally {
    if (-not $proc.HasExited) { $proc.Kill() }
}

# 3. Zip the two snapshots into a synthetic .diagsession (the skill matches \.gcdump$ entries).
$diag = Join-Path $workRoot "fixture-leak.diagsession"
if (Test-Path -LiteralPath $diag) { Remove-Item -Force -LiteralPath $diag }
$zip = [System.IO.Compression.ZipFile]::Open($diag, 'Create')
try {
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $snap1, "Snapshot1-before.gcdump") | Out-Null
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $snap2, "Snapshot2-after.gcdump") | Out-Null
}
finally {
    $zip.Dispose()
}

Write-Host "Fixture built."
Write-Host "  gcdump1:     $snap1 ($((Get-Item $snap1).Length) bytes)"
Write-Host "  gcdump2:     $snap2 ($((Get-Item $snap2).Length) bytes)"
Write-Host "  diagsession: $diag ($((Get-Item $diag).Length) bytes)"
