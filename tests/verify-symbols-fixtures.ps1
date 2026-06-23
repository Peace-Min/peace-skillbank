#requires -Version 5.1
<#
    Behavioral fixture tests for skills/lightningchart-72/scripts/verify-symbols.py
    (the hallucination guard). Drives the verifier against SYNTHETIC, unlicensed indexes
    and asserts its exit-code contract:

        exit 0  every cited symbol verified (and valid constructor arity)
        exit 1  unknown qualified symbol, --strict unknown bare / inline-code id, or bad ctor arity
        exit 2  corpus / api-index not built

    Synthetic types (tests/fixtures/lightningchart-72/api-index.json):
        FixtureSeries     props=LineColor,Visible  methods=Clear  ctors arity {0,3}
        FixtureMode       enum values Fast,Slow
        FixtureGeneric`1  props=Payload            ctors arity {1}   (backtick arity on purpose)

    The symbols-only fixture (tests/fixtures/lightningchart-72-symbols/api-symbols.txt) exercises
    the api-symbols.txt fallback path (no api-index.json present).

    Skips silently when Python is unavailable (matches validate.ps1 policy).
#>
param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"

$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) {
    Write-Host "Python not found; skipping verify-symbols fixture tests."
    return
}

$verify = Join-Path $RepositoryRoot "skills\lightningchart-72\scripts\verify-symbols.py"
if (-not (Test-Path -LiteralPath $verify)) {
    throw "Missing verify script: $verify"
}

$indexDir = Join-Path $PSScriptRoot "fixtures\lightningchart-72"           # has api-index.json
$symbolsDir = Join-Path $PSScriptRoot "fixtures\lightningchart-72-symbols" # has only api-symbols.txt
foreach ($d in @((Join-Path $indexDir "api-index.json"), (Join-Path $symbolsDir "api-symbols.txt"))) {
    if (-not (Test-Path -LiteralPath $d)) { throw "Missing synthetic fixture: $d" }
}

# A directory with no api-index.json / api-symbols.txt -> the "corpus not built" (exit 2) case.
$emptyDir = Join-Path $env:TEMP "lc72-verify-noindex-fixture"
if (Test-Path -LiteralPath $emptyDir) { Remove-Item -LiteralPath $emptyDir -Recurse -Force }
New-Item -ItemType Directory -Path $emptyDir | Out-Null

function Invoke-Verify {
    param(
        [Parameter(Mandatory = $true)][string]$Draft,
        [Parameter(Mandatory = $true)][string]$RefDir,
        [switch]$Strict
    )

    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($tmp, $Draft, (New-Object System.Text.UTF8Encoding($false)))
        $pyArgs = @($verify, $tmp, $RefDir)
        if ($Strict) { $pyArgs += "--strict" }
        & $python.Source @pyArgs | Out-Null
        return $LASTEXITCODE
    }
    finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

# Drafts use single-quoted PowerShell strings so embedded C# double-quotes are literal.
$cases = @(
    # --- exit-code matrix over the JSON index ---
    @{ Name = "known qualified + valid ctor arity -> 0"; Draft = 'Use FixtureSeries.LineColor to set the color, then call FixtureSeries.Clear. Create one with new FixtureSeries(view, xAxis, yAxis).'; Dir = $indexDir; Strict = $false; Expect = 0 }
    @{ Name = "known qualified members under --strict -> 0"; Draft = 'FixtureSeries.LineColor and FixtureSeries.Visible and FixtureMode.Fast.'; Dir = $indexDir; Strict = $true; Expect = 0 }
    @{ Name = "unknown qualified member -> 1"; Draft = 'Set FixtureSeries.RainbowMode to enable a rainbow.'; Dir = $indexDir; Strict = $false; Expect = 1 }
    @{ Name = "strict unknown bare name -> 1"; Draft = 'Apply a RainbowPalette to the chart.'; Dir = $indexDir; Strict = $true; Expect = 1 }
    @{ Name = "unknown bare name without --strict -> 0"; Draft = 'Apply a RainbowPalette to the chart.'; Dir = $indexDir; Strict = $false; Expect = 0 }
    @{ Name = "invalid constructor arity -> 1"; Draft = 'Create it with new FixtureSeries(view, xAxis, yAxis, zAxis, extra).'; Dir = $indexDir; Strict = $false; Expect = 1 }

    # --- enum value citations ---
    @{ Name = "known enum value qualified -> 0"; Draft = 'Set the mode to FixtureMode.Slow.'; Dir = $indexDir; Strict = $true; Expect = 0 }
    @{ Name = "invented enum value qualified -> 1"; Draft = 'Set the mode to FixtureMode.Medium.'; Dir = $indexDir; Strict = $false; Expect = 1 }

    # --- P0: single-word member cited in inline-code (the bypass) ---
    @{ Name = "P0 invented inline-code member, strict -> 1"; Draft = 'Enable the `Smoothing` property for nicer curves.'; Dir = $indexDir; Strict = $true; Expect = 1 }
    @{ Name = "P0 invented inline-code member, non-strict -> 0"; Draft = 'Enable the `Smoothing` property for nicer curves.'; Dir = $indexDir; Strict = $false; Expect = 0 }
    @{ Name = "P0 known inline-code member is REVIEW not fail -> 0"; Draft = 'Set the `Visible` flag on the series.'; Dir = $indexDir; Strict = $true; Expect = 0 }

    # --- P1-1: string-literal arguments must not corrupt arity counting ---
    @{ Name = "P1-1 string arg with comma counts as one -> 0"; Draft = 'Create it with new FixtureSeries("a, b", xAxis, yAxis).'; Dir = $indexDir; Strict = $false; Expect = 0 }
    @{ Name = "P1-1 string arg with close-paren counts as one -> 0"; Draft = 'Create it with new FixtureSeries("a)b", xAxis, yAxis).'; Dir = $indexDir; Strict = $false; Expect = 0 }

    # --- P1-2 / P1-3: generic type name normalization + generic ctor detection ---
    @{ Name = "P1-2 generic member cited without backtick -> 0"; Draft = 'Read FixtureGeneric.Payload after construction.'; Dir = $indexDir; Strict = $true; Expect = 0 }
    @{ Name = "P1-3 generic ctor valid arity -> 0"; Draft = 'Create with new FixtureGeneric<int>(item).'; Dir = $indexDir; Strict = $false; Expect = 0 }
    @{ Name = "P1-3 generic ctor invalid arity is detected -> 1"; Draft = 'Create with new FixtureGeneric<int>(a, b, c).'; Dir = $indexDir; Strict = $false; Expect = 1 }

    # --- api-symbols.txt fallback path (no api-index.json) ---
    @{ Name = "fallback: known qualified -> 0"; Draft = 'Use FixtureSeries.LineColor here.'; Dir = $symbolsDir; Strict = $false; Expect = 0 }
    @{ Name = "fallback: unknown qualified -> 1"; Draft = 'Use FixtureSeries.RainbowMode here.'; Dir = $symbolsDir; Strict = $false; Expect = 1 }
    @{ Name = "fallback: generic member without backtick -> 0"; Draft = 'Read FixtureGeneric.Payload here.'; Dir = $symbolsDir; Strict = $true; Expect = 0 }

    # --- regression guards for verifier edge cases the audit found ---
    @{ Name = "prose apostrophe does not swallow a following bad ctor -> 1"; Draft = 'Adjust the chart''s color, then new FixtureSeries(view, xAxis, yAxis, zAxis, extra).'; Dir = $indexDir; Strict = $false; Expect = 1 }
    @{ Name = "chained invented member is flagged -> 1"; Draft = 'Call FixtureSeries.Clear.Deeper to reset.'; Dir = $indexDir; Strict = $true; Expect = 1 }
    @{ Name = "generic ctor with nested angle brackets, bad arity -> 1"; Draft = 'Create with new FixtureGeneric<Func<int>>(a, b, c).'; Dir = $indexDir; Strict = $false; Expect = 1 }

    # --- audit over-block fixes: `using`/`namespace` lines and BCL/collection members must NOT
    #     false-flag (the contract tells the model to quote real code), while real invented
    #     members in the SAME draft must still be caught. ---
    @{ Name = "using directive line is not flagged -> 0"; Draft = "using Arction.Wpf.Charting;`nUse FixtureSeries.LineColor here."; Dir = $indexDir; Strict = $true; Expect = 0 }
    @{ Name = "namespace declaration is not flagged -> 0"; Draft = "namespace Demo.App;`nUse FixtureSeries.LineColor here."; Dir = $indexDir; Strict = $true; Expect = 0 }
    @{ Name = "BCL member on a chain (.Count) is not flagged -> 0"; Draft = 'Read FixtureSeries.Clear.Count after reset.'; Dir = $indexDir; Strict = $true; Expect = 0 }
    @{ Name = "BCL member qualified (.Add) is not flagged -> 0"; Draft = 'Call FixtureSeries.Add to append an item.'; Dir = $indexDir; Strict = $true; Expect = 0 }
    @{ Name = "stripping using lines does not hide a real invented member -> 1"; Draft = "using Arction.Wpf.Charting;`nSet FixtureSeries.RainbowMode here."; Dir = $indexDir; Strict = $false; Expect = 1 }
    @{ Name = "BCL leniency still flags a non-BCL invented chain segment -> 1"; Draft = 'Call FixtureSeries.Clear.Frobnicate to reset.'; Dir = $indexDir; Strict = $true; Expect = 1 }
)

$failures = @()
foreach ($case in $cases) {
    $actual = Invoke-Verify -Draft $case.Draft -RefDir $case.Dir -Strict:$case.Strict
    if ($actual -ne $case.Expect) {
        $failures += "  [FAIL] $($case.Name): expected exit $($case.Expect), got $actual"
    }
    else {
        Write-Host "  [ok]   $($case.Name)"
    }
}

# exit 2: index not built
$noIndex = Invoke-Verify -Draft 'FixtureSeries.LineColor' -RefDir $emptyDir
if ($noIndex -ne 2) {
    $failures += "  [FAIL] no api-index -> 2: expected exit 2, got $noIndex"
}
else {
    Write-Host "  [ok]   corpus not built -> 2"
}

Remove-Item -LiteralPath $emptyDir -Recurse -Force -ErrorAction SilentlyContinue

# CLAUDE_PLUGIN_DATA resolution: with no ref-dir arg, a corpus in the plugin data dir is used
# (this is how the verifier finds the corpus when the skill is installed as a plugin).
$dataDir = Join-Path $env:TEMP "lc72-plugindata-fixture"
$dataRefs = Join-Path $dataDir "references"
if (Test-Path -LiteralPath $dataDir) { Remove-Item -LiteralPath $dataDir -Recurse -Force }
New-Item -ItemType Directory -Path $dataRefs | Out-Null
Copy-Item -LiteralPath (Join-Path $indexDir "api-index.json") -Destination (Join-Path $dataRefs "api-index.json")
$savedData = $env:CLAUDE_PLUGIN_DATA
try {
    $env:CLAUDE_PLUGIN_DATA = $dataDir
    $t1 = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($t1, 'Use FixtureSeries.LineColor here.', (New-Object System.Text.UTF8Encoding($false)))
    & $python.Source $verify $t1 "--strict" | Out-Null     # no ref-dir arg -> resolve via CLAUDE_PLUGIN_DATA
    $c1 = $LASTEXITCODE
    Remove-Item -LiteralPath $t1 -Force
    if ($c1 -eq 0) { Write-Host "  [ok]   CLAUDE_PLUGIN_DATA corpus resolved (known -> 0)" }
    else { $failures += "  [FAIL] CLAUDE_PLUGIN_DATA known: expected 0, got $c1" }

    $t2 = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($t2, 'Use FixtureSeries.RainbowMode here.', (New-Object System.Text.UTF8Encoding($false)))
    & $python.Source $verify $t2 "--strict" | Out-Null
    $c2 = $LASTEXITCODE
    Remove-Item -LiteralPath $t2 -Force
    if ($c2 -eq 1) { Write-Host "  [ok]   CLAUDE_PLUGIN_DATA corpus resolved (unknown -> 1)" }
    else { $failures += "  [FAIL] CLAUDE_PLUGIN_DATA unknown: expected 1, got $c2" }
}
finally {
    if ($null -eq $savedData) { Remove-Item Env:\CLAUDE_PLUGIN_DATA -ErrorAction SilentlyContinue }
    else { $env:CLAUDE_PLUGIN_DATA = $savedData }
    Remove-Item -LiteralPath $dataDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    throw ("verify-symbols fixture tests failed:`n" + ($failures -join "`n"))
}

Write-Host "verify-symbols fixture tests passed ($($cases.Count + 3) cases)."
