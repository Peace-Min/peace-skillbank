#requires -Version 5.1
<#
    Phase 4 of issue #29: the optional root-cause enrichment stage. Runs AFTER extract-gcdump-reports.ps1
    has produced per-snapshot HeapStat reports. Never replaces the existing analysis -- it ADDS evidence
    and degrades gracefully:

      >=2 HeapStat reports                 -> candidate selection (select-candidates.ps1)
      + after.dmp + built ClrMD tool       -> managed root-chains (ClrMdRootChainReport)
      missing dump / tool / report / fail  -> graceful note, HeapStat-only analysis still stands

    Output: root-cause-evidence.md (+ reference-chains.{json,md,html} when the dump path runs), and the
    same evidence appended to LLM_MEMORY_INPUT.txt when -MemoryInput is given.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ReportsDir,  # dir containing *.heapstat.txt (>=2 = before/after)
    [string]$DumpPath,                                  # optional after.dmp for managed root-chains
    [string]$ToolExe,                                   # optional path to ClrMdRootChainReport(.exe)
    [string]$OutputDir = ".",
    [string]$MemoryInput,                               # optional LLM_MEMORY_INPUT.txt to append to
    [int]$MaxDepth = 40
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Resolve-Tool {
    # 1) explicit path wins
    if ($ToolExe -and (Test-Path -LiteralPath $ToolExe)) { return (Resolve-Path -LiteralPath $ToolExe).Path }
    # 2) env override -- set once on the (offline) machine: setx CLRMD_ROOTCHAIN_EXE <path>
    if ($env:CLRMD_ROOTCHAIN_EXE -and (Test-Path -LiteralPath $env:CLRMD_ROOTCHAIN_EXE)) {
        return (Resolve-Path -LiteralPath $env:CLRMD_ROOTCHAIN_EXE).Path
    }
    # 3) common install / build locations, in priority order. The first is the offline-bundle default
    #    install path (Install-ClrMd.ps1 in github.com/Peace-Min/dotnet-gcdump-offline), so a bundle
    #    install is auto-detected with no -RootChainToolExe argument.
    $candidates = @("C:\tools\ClrMdRootChainReport\ClrMdRootChainReport.exe")
    foreach ($rel in @("..\tools\ClrMdRootChainReport\pub\ClrMdRootChainReport.exe",
                       "..\tools\ClrMdRootChainReport\dist\win-x64\ClrMdRootChainReport.exe",
                       "..\tools\ClrMdRootChainReport\ClrMdRootChainReport.exe")) {
        $candidates += (Join-Path $here $rel)
    }
    foreach ($p in $candidates) {
        if (Test-Path -LiteralPath $p) { return (Resolve-Path -LiteralPath $p).Path }
    }
    return $null
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$enrichMd = Join-Path $OutputDir "root-cause-evidence.md"

function Write-Enrichment([string]$Text) {
    [System.IO.File]::WriteAllText($enrichMd, $Text, (New-Object System.Text.UTF8Encoding($false)))
    if ($MemoryInput -and (Test-Path -LiteralPath $MemoryInput)) {
        Add-Content -LiteralPath $MemoryInput -Value ([Environment]::NewLine + $Text) -Encoding UTF8
    }
    Write-Output $Text
}

$reports = @(Get-ChildItem -LiteralPath $ReportsDir -Filter *.heapstat.txt -ErrorAction SilentlyContinue | Sort-Object Name)
if ($reports.Count -lt 2) {
    Write-Enrichment "## Root-cause evidence`n`n(Only $($reports.Count) HeapStat report found; need before+after snapshots for growth-based candidate selection. Root-chain analysis skipped.)`n"
    return
}

$before = $reports[0].FullName
$after = $reports[-1].FullName
$candMd = Join-Path $OutputDir "candidates.md"
$candList = Join-Path $OutputDir "candidates.txt"
& (Join-Path $here "select-candidates.ps1") -BeforeReport $before -AfterReport $after -OutMarkdown $candMd -OutTypeList $candList | Out-Null
$growth = [System.IO.File]::ReadAllText($candMd)

$tool = Resolve-Tool
$chainMd = ""
if ($DumpPath -and (Test-Path -LiteralPath $DumpPath) -and $tool) {
    try {
        & $tool $DumpPath --types-file $candList --out $OutputDir --max-depth $MaxDepth | Out-Null
        $rc = Join-Path $OutputDir "reference-chains.md"
        $chainMd = if (Test-Path -LiteralPath $rc) { [System.IO.File]::ReadAllText($rc) }
        else { "## Reference-chain evidence`n`n(Root-chain tool ran but produced no output.)`n" }
    }
    catch {
        $chainMd = "## Reference-chain evidence`n`n(Root-chain analysis failed: $($_.Exception.Message). HeapStat candidates above still stand.)`n"
    }
}
else {
    $why = if (-not $DumpPath) { "no after.dmp provided" }
    elseif (-not (Test-Path -LiteralPath $DumpPath)) { "after.dmp not found ($DumpPath)" }
    else { "ClrMdRootChainReport tool not found -- build/bundle it (see tools/ClrMdRootChainReport)" }
    $chainMd = "## Reference-chain evidence`n`nRoot-chain unavailable -- $why. HeapStat shows WHAT grew (candidates above). To also get WHY each candidate is retained, capture an after.dmp (``dotnet-dump collect --type heap -p <PID> -o after.dmp``) and provide the built tool.`n"
}

Write-Enrichment ($growth + [Environment]::NewLine + $chainMd)
