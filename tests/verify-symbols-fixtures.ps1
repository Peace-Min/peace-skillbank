#requires -Version 5.1
<#
    Behavioral fixture tests for skills/lightningchart-72/scripts/verify-symbols.py
    (the hallucination guard). Drives the verifier against a SYNTHETIC, unlicensed
    api-index.json and asserts its exit-code contract:

        exit 0  every cited symbol verified (and valid constructor arity)
        exit 1  unknown qualified symbol, --strict unknown bare name, or bad ctor arity
        exit 2  corpus / api-index not built

    Synthetic types (tests/fixtures/lightningchart-72/api-index.json):
        FixtureSeries  props=LineColor,Visible  methods=Clear  ctors arity {0,3}
        FixtureMode    enum values Fast,Slow

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
    throw "Missing verify hook: $verify"
}

$indexDir = Join-Path $PSScriptRoot "fixtures\lightningchart-72"
if (-not (Test-Path -LiteralPath (Join-Path $indexDir "api-index.json"))) {
    throw "Missing synthetic fixture index: $indexDir\api-index.json"
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

$cases = @(
    @{ Name = "known qualified + valid ctor arity -> 0"; Draft = "Use FixtureSeries.LineColor to set the color, then call FixtureSeries.Clear. Create one with new FixtureSeries(view, xAxis, yAxis)."; Strict = $false; Expect = 0 }
    @{ Name = "known qualified members under --strict -> 0"; Draft = "FixtureSeries.LineColor and FixtureSeries.Visible and FixtureMode.Fast."; Strict = $true; Expect = 0 }
    @{ Name = "unknown qualified member -> 1"; Draft = "Set FixtureSeries.RainbowMode to enable a rainbow."; Strict = $false; Expect = 1 }
    @{ Name = "strict unknown bare name -> 1"; Draft = "Apply a RainbowPalette to the chart."; Strict = $true; Expect = 1 }
    @{ Name = "unknown bare name without --strict -> 0"; Draft = "Apply a RainbowPalette to the chart."; Strict = $false; Expect = 0 }
    @{ Name = "invalid constructor arity -> 1"; Draft = "Create it with new FixtureSeries(view, xAxis, yAxis, zAxis, extra)."; Strict = $false; Expect = 1 }
)

$failures = @()
foreach ($case in $cases) {
    $actual = Invoke-Verify -Draft $case.Draft -RefDir $indexDir -Strict:$case.Strict
    if ($actual -ne $case.Expect) {
        $failures += "  [FAIL] $($case.Name): expected exit $($case.Expect), got $actual"
    }
    else {
        Write-Host "  [ok]   $($case.Name)"
    }
}

# exit 2: index not built
$noIndex = Invoke-Verify -Draft "FixtureSeries.LineColor" -RefDir $emptyDir
if ($noIndex -ne 2) {
    $failures += "  [FAIL] no api-index -> 2: expected exit 2, got $noIndex"
}
else {
    Write-Host "  [ok]   corpus not built -> 2"
}

Remove-Item -LiteralPath $emptyDir -Recurse -Force -ErrorAction SilentlyContinue

if ($failures.Count -gt 0) {
    throw ("verify-symbols fixture tests failed:`n" + ($failures -join "`n"))
}

Write-Host "verify-symbols fixture tests passed (7 cases)."
