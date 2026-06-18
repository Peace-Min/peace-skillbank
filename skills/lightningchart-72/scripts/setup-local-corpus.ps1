<#
.SYNOPSIS
  One command to build the lightningchart-72 local grounded corpus (air-gapped friendly).

.DESCRIPTION
  Resolves the Arction 7.2 DLL folder and the User's Manual PDF -- explicitly via -DllDir /
  -ManualPdf, or by auto-detection under a single -SourceDir -- then verifies the Python + pypdf
  toolchain and builds BOTH tiers and self-checks the result:

    Tier 1  build-api-index.ps1   -> references/api-index.json + api-symbols.txt   (PowerShell)
    Tier 2  build-manual-index.py -> references/manual/*.md + manual-index.json     (Python + pypdf)

  Nothing is downloaded and nothing licensed is copied or committed; the corpus stays local under
  references/ (gitignored). The two build scripts remain the underlying machinery -- this is just a
  convenience front-end for them.

  Fail-fast: if Python, pypdf, the DLL folder, or the manual PDF is missing, the script prints
  specific recovery guidance and ABORTS without building a partial corpus.

.EXAMPLE
  # Simplest: drop the DLLs + manual PDF in a folder, run the script from inside it (no paths).
  cd D:\LightningChart72
  powershell -NoProfile -ExecutionPolicy Bypass -File C:\path\to\scripts\setup-local-corpus.ps1

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-local-corpus.ps1 -SourceDir "D:\LightningChart72"

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-local-corpus.ps1 `
    -DllDir "D:\LightningChart72\Lib\Arction" `
    -ManualPdf "D:\LightningChart72\LightningChart Users Manual.pdf"

.NOTES
  The corpus OUTPUT location is anchored to the SCRIPT's own location ($PSScriptRoot), not the source
  folder or the current directory: it writes to the skill's references/ (repo) or ${CLAUDE_PLUGIN_DATA}
  (installed plugin). So running from inside the source folder never confuses where the corpus lands.
#>
param(
    [string]$SourceDir,
    [string]$DllDir,
    [string]$ManualPdf,
    [string]$OutDir
)

$ErrorActionPreference = "Stop"

function Write-Step { param([string]$Message) Write-Host "[setup] $Message" }

function Stop-Setup {
    param([string]$Message, [string[]]$Hint = @())
    Write-Host ""
    Write-Host "[setup] FAILED: $Message"
    foreach ($h in $Hint) { Write-Host "        $h" }
    exit 1
}

$scriptDir = $PSScriptRoot
if (-not $OutDir) {
    $repoRef = Join-Path (Split-Path -Parent $scriptDir) "references"
    if ($env:CLAUDE_PLUGIN_DATA) {
        # Inside Claude Code (hook/skill context): write to the persistent plugin data dir.
        $OutDir = Join-Path $env:CLAUDE_PLUGIN_DATA "references"
    }
    elseif ($scriptDir -match '[\\/]plugins[\\/]cache[\\/]') {
        # Manual terminal run from the read-only plugin cache (no env var). Writing here loses the
        # corpus on '/plugin update', so try to find the persistent data dir on disk and target it.
        $dataRoot = Join-Path $env:USERPROFILE ".claude\plugins\data"
        $dataDir = $null
        if (Test-Path -LiteralPath $dataRoot) {
            $dataDir = Get-ChildItem -LiteralPath $dataRoot -Directory -Filter "*peace-skillbank*" -ErrorAction SilentlyContinue |
                Select-Object -First 1
        }
        if ($dataDir) {
            $OutDir = Join-Path $dataDir.FullName "references"
            Write-Step "Installed-plugin context: targeting persistent data dir $OutDir"
        }
        else {
            Write-Host "[setup] NOTE: running from the read-only plugin cache and CLAUDE_PLUGIN_DATA is not set."
            Write-Host "        The corpus would be written into the cache and lost on '/plugin update'."
            Write-Host "        Run setup from within a Claude Code session, or pass -OutDir pointing at your"
            Write-Host "        persistent data dir (e.g. %USERPROFILE%\.claude\plugins\data\<id>\references)."
            $OutDir = $repoRef
        }
    }
    else {
        # Repo / dev checkout: the corpus sits next to the scripts.
        $OutDir = $repoRef
    }
}

if (-not $SourceDir -and -not $DllDir -and -not $ManualPdf) {
    # Default: assume the script is run from inside the folder holding the DLLs + manual PDF, so the
    # user can just drop the files in a folder, run the script there, and be done -- no paths to pass.
    $SourceDir = (Get-Location).Path
    Write-Step "No -SourceDir given; using the current directory as the source: $SourceDir"
}
if ($SourceDir -and -not (Test-Path -LiteralPath $SourceDir)) {
    Stop-Setup "SourceDir not found: $SourceDir" @("Pass a folder that contains the 7.2 SDK DLLs and the User's Manual PDF.")
}

# --- Resolve the DLL folder (existence only; the actual load happens in build-api-index.ps1). ---
if (-not $DllDir -and $SourceDir) {
    $mainDll = Get-ChildItem -LiteralPath $SourceDir -Recurse -Filter "*LightningChartUltimate*.dll" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($mainDll) {
        $DllDir = $mainDll.DirectoryName
        Write-Step "Auto-detected DLL folder: $DllDir"
    }
}
if (-not $DllDir -or -not (Test-Path -LiteralPath $DllDir)) {
    Stop-Setup "Could not locate the Arction 7.2 DLL folder." @(
        "Pass -DllDir 'D:\LightningChart72\Lib\Arction' (the folder holding *LightningChartUltimate*.dll),",
        "or pass -SourceDir pointing at a tree that contains it."
    )
}

# --- Resolve the manual PDF. ---
if (-not $ManualPdf -and $SourceDir) {
    foreach ($pat in @("*User*Manual*.pdf", "*Manual*.pdf", "*LightningChart*.pdf")) {
        $pdf = Get-ChildItem -LiteralPath $SourceDir -Recurse -Filter $pat -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($pdf) { $ManualPdf = $pdf.FullName; Write-Step "Auto-detected manual PDF: $ManualPdf"; break }
    }
}
if (-not $ManualPdf -or -not (Test-Path -LiteralPath $ManualPdf)) {
    Stop-Setup "Could not locate the LightningChart 7.2 User's Manual PDF." @(
        "Pass -ManualPdf 'D:\LightningChart72\LightningChart Users Manual.pdf',",
        "or pass -SourceDir pointing at a tree that contains it."
    )
}

# --- Verify the Python toolchain (prefer 'python', then the 'py -3' launcher; avoid the Store stub). ---
$pythonExe = $null
$pythonPre = @()
$py = Get-Command python -ErrorAction SilentlyContinue
if ($py) {
    $pythonExe = $py.Source
}
else {
    $launcher = Get-Command py -ErrorAction SilentlyContinue
    if ($launcher) { $pythonExe = $launcher.Source; $pythonPre = @("-3") }
}
if (-not $pythonExe) {
    Stop-Setup "Python 3 was not found (required to index the manual PDF)." @(
        "Install Python 3 and re-run. Avoid the 'python3' Microsoft Store stub.",
        "Offline: install Python from a local installer/bundle first."
    )
}

& $pythonExe @pythonPre -c "import pypdf" *> $null
if ($LASTEXITCODE -ne 0) {
    Stop-Setup "Python is present but the 'pypdf' package is missing (required for the manual index)." @(
        "Online:  $pythonExe $($pythonPre -join ' ') -m pip install pypdf",
        "Offline: $pythonExe $($pythonPre -join ' ') -m pip install --no-index --find-links <wheelhouse-dir> pypdf",
        "         (point <wheelhouse-dir> at a folder holding the pypdf wheel and its dependencies)."
    )
}

Write-Host ""
Write-Step "DLL folder : $DllDir"
Write-Step "Manual PDF : $ManualPdf"
Write-Step "Output     : $OutDir"
Write-Step "Python     : $pythonExe $($pythonPre -join ' ')"
Write-Host ""

# --- Build Tier 1 (DLL API index). ---
Write-Step "(1/2) Building Tier 1 DLL API index..."
try {
    & (Join-Path $scriptDir "build-api-index.ps1") -DllDir $DllDir -OutDir $OutDir
}
catch {
    Stop-Setup "DLL API index build failed: $($_.Exception.Message)" @(
        "Check that -DllDir holds the 7.2 Arction assemblies (and their sibling dependencies)."
    )
}

# --- Build Tier 2 (manual index). ---
Write-Step "(2/2) Building Tier 2 manual index..."
& $pythonExe @pythonPre (Join-Path $scriptDir "build-manual-index.py") $ManualPdf $OutDir
if ($LASTEXITCODE -ne 0) {
    Stop-Setup "Manual index build failed (exit $LASTEXITCODE)." @(
        "Confirm the PDF path is correct and that pypdf can read it."
    )
}

# --- Self-check the generated corpus. ---
Write-Host ""
Write-Step "Self-check:"
$apiIndex = Join-Path $OutDir "api-index.json"
$apiSymbols = Join-Path $OutDir "api-symbols.txt"
$manualIndex = Join-Path $OutDir "manual-index.json"
$manualDir = Join-Path $OutDir "manual"

$problems = @()
foreach ($f in @($apiIndex, $apiSymbols, $manualIndex)) {
    if (-not (Test-Path -LiteralPath $f)) { $problems += "missing $(Split-Path -Leaf $f)" }
}

$typeCount = 0; $sectionCount = 0; $mdCount = 0
if (Test-Path -LiteralPath $apiIndex) {
    try { $typeCount = (Get-Content -Raw -LiteralPath $apiIndex | ConvertFrom-Json).typeCount }
    catch { $problems += "api-index.json is not valid JSON" }
}
if (Test-Path -LiteralPath $manualIndex) {
    try { $sectionCount = (Get-Content -Raw -Encoding UTF8 -LiteralPath $manualIndex | ConvertFrom-Json).sectionCount }
    catch { $problems += "manual-index.json is not valid JSON" }
}
if (Test-Path -LiteralPath $manualDir) {
    $mdCount = @(Get-ChildItem -LiteralPath $manualDir -Filter *.md -ErrorAction SilentlyContinue).Count
}
if ($typeCount -le 0) { $problems += "api-index.json reports no types" }
if ($sectionCount -ne $mdCount) { $problems += "manual sections ($sectionCount) != manual/*.md files ($mdCount)" }

Write-Step "  api types      : $typeCount"
Write-Step "  manual sections: $sectionCount  (md files: $mdCount)"

if ($problems.Count -gt 0) {
    Stop-Setup ("corpus self-check found problems:`n        - " + ($problems -join "`n        - ")) @(
        "Fix the inputs above and re-run this script."
    )
}

Write-Host ""
Write-Step "OK. Corpus ready under: $OutDir"
Write-Step "  Tier 1: api-index.json ($typeCount types), api-symbols.txt"
Write-Step "  Tier 2: manual-index.json ($sectionCount sections), manual/*.md"
Write-Step "  Local-only (gitignored). You can now ask LightningChart 7.2 questions."
