#requires -Version 5.1
<#
    Opt-in end-to-end smoke test for SparrowXlsExport. NOT run by the default validate gate (needs the
    .NET SDK + an NPOI restore -- env/time heavy). Run it manually, or via `validate.ps1 -IncludeSparrowE2E`.

    It builds the FixtureGen generator + the tool, generates a tiny real BIFF (.xls) fixture, runs the
    tool, and asserts the split outputs (per-item md, index.csv, checkers.md), the filters (--severity /
    --checker / --max), and idempotent re-runs. Skips cleanly (not fails) when the .NET SDK is missing.

    PS 5.1 notes honored here: collections wrapped in @() before .Count; no &&/ternary/null-coalescing;
    md/checkers read with -Encoding UTF8 (the TOOL writes UTF-8 without BOM via .NET, not via PowerShell).
#>
param([string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path)

$ErrorActionPreference = "Stop"
$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if (-not $dotnet) { Write-Host "dotnet SDK not found; skipping Sparrow XLS export E2E."; return }

$toolDir = Join-Path $RepositoryRoot "skills\sparrow-static-analysis\tools\SparrowXlsExport"
$toolProj = Join-Path $toolDir "SparrowXlsExport.csproj"
$fixtureProj = Join-Path $toolDir "FixtureGen\FixtureGen.csproj"
foreach ($p in @($toolProj, $fixtureProj)) { if (-not (Test-Path -LiteralPath $p)) { throw "missing project: $p" } }

$work = Join-Path $env:TEMP ("sparrow-e2e-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$failures = @()
function Check($name, [scriptblock]$cond) {
    try { if (& $cond) { Write-Host "  [ok]   $name" } else { $script:failures += $name } }
    catch { $script:failures += "$name ($($_.Exception.Message))" }
}

function Invoke-Tool {
    param([string[]]$ToolArgs)
    & $dotnet.Source run --project $toolProj -c Release --no-build -- @ToolArgs 2>&1 | Out-Null
    return $LASTEXITCODE
}

function Get-MdCount {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) { return 0 }
    return @(Get-ChildItem -LiteralPath $Dir -Filter *.md -File).Count
}

try {
    Write-Host "  building FixtureGen + SparrowXlsExport (Release)..."
    & $dotnet.Source build $fixtureProj -c Release -v q 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "FixtureGen build failed" }
    & $dotnet.Source build $toolProj -c Release -v q 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "SparrowXlsExport build failed" }

    $fixtureXls = Join-Path $work "fixture.xls"
    & $dotnet.Source run --project $fixtureProj -c Release --no-build -- $fixtureXls 2>&1 | Out-Null
    Check "fixture.xls generated" { (Test-Path -LiteralPath $fixtureXls) -and ((Get-Item -LiteralPath $fixtureXls).Length -gt 0) }

    # --- default run ---
    $out = Join-Path $work "out"
    $exit = Invoke-Tool @($fixtureXls, "--out", $out)
    Check "exit 0 (default run)" { $exit -eq 0 }
    $items = Join-Path $out "items"
    Check "4 md files written" { (Get-MdCount $items) -eq 4 }

    # index.csv: header + 4 data lines. Index columns carry no embedded newlines -> one physical line each.
    $indexCsv = Join-Path $out "index.csv"
    Check "index.csv exists" { Test-Path -LiteralPath $indexCsv }
    $indexLines = @(Get-Content -LiteralPath $indexCsv | Where-Object { $_ -ne "" })
    Check "index.csv has header + 4 data lines" { $indexLines.Count -eq 5 }
    $indexJoined = ($indexLines -join "`n")
    Check "index.csv quotes the comma-bearing 체커명" { $indexJoined.Contains('"사용되지 않는 객체, 암시적 타입"') }
    Check "index.csv ID renders as 101 (not 101.0)" { ($indexJoined -match "(?m),101,") -and ($indexJoined -notmatch "101\.0") }

    # checkers.md: both keys, correct counts (K1=3, K2=1), K1 severity distribution, checkbox line.
    $checkersMd = Join-Path $out "checkers.md"
    $checkers = Get-Content -Raw -Encoding UTF8 -LiteralPath $checkersMd
    Check "checkers.md lists K1 (MISSING_BLANK_LINE_BEFORE_COMMENT)" { $checkers.Contains("## MISSING_BLANK_LINE_BEFORE_COMMENT") }
    Check "checkers.md lists K2 (PRACTICE.OBJECT_INSTANTIATION...)" { $checkers.Contains("## PRACTICE.OBJECT_INSTANTIATION.NOT_USED_IMPLICITLY_TYPE") }
    Check "checkers.md K1 count = 3" { $checkers.Contains("건수: 3") }
    Check "checkers.md K2 count = 1" { $checkers.Contains("건수: 1") }
    Check "checkers.md K1 severity distribution (낮음:2 보통:1)" { $checkers.Contains("낮음:2") -and $checkers.Contains("보통:1") }
    Check "checkers.md has 해결방안 checkbox" { $checkers.Contains("- [ ] 해결방안 작성") }

    # row (b) md (ID 102): pipe escaped + <br> in table; source fenced + verbatim multi-line.
    $rowB = @(Get-ChildItem -LiteralPath $items -Filter "102_*.md" -File)
    Check "row (b) md exists" { $rowB.Count -eq 1 }
    if ($rowB.Count -eq 1) {
        $b = Get-Content -Raw -Encoding UTF8 -LiteralPath $rowB[0].FullName
        Check "row (b) table escapes | and collapses newline to <br>" { $b.Contains('a\|b<br>c,d"e') }
        Check "row (b) source is fenced (text code block)" { $b -match '(?m)^```text' }
        Check "row (b) source verbatim line 1" { $b.Contains("   6: void f() {") }
        Check "row (b) source verbatim line 2" { $b.Contains("   7:   int x=0; // x") }
        Check "row (b) source verbatim line 3" { $b.Contains("   8: }") }
        Check "row (b) 소스 코드/체커 설명 excluded from table" { (-not ($b -match "(?m)^\| 소스 코드 ")) -and (-not ($b -match "(?m)^\| 체커 설명 ")) }
    }

    # row (a) md (ID 101): ID renders without a trailing .0 in the table.
    $rowA = @(Get-ChildItem -LiteralPath $items -Filter "101_*.md" -File)
    Check "row (a) md exists" { $rowA.Count -eq 1 }
    if ($rowA.Count -eq 1) {
        $a = Get-Content -Raw -Encoding UTF8 -LiteralPath $rowA[0].FullName
        Check "row (a) ID renders as 101 (not 101.0)" { $a.Contains("| ID | 101 |") -and (-not $a.Contains("101.0")) }
    }

    # --- filters ---
    $sevOut = Join-Path $work "sev"
    $null = Invoke-Tool @($fixtureXls, "--out", $sevOut, "--severity", "높음")
    Check "--severity 높음 writes exactly 1 md" { (Get-MdCount (Join-Path $sevOut "items")) -eq 1 }

    $chkOut = Join-Path $work "chk"
    $null = Invoke-Tool @($fixtureXls, "--out", $chkOut, "--checker", "missing_blank")   # case-insensitive substring
    Check "--checker (case-insensitive substring) writes 3 md" { (Get-MdCount (Join-Path $chkOut "items")) -eq 3 }

    $maxOut = Join-Path $work "mx"
    $null = Invoke-Tool @($fixtureXls, "--out", $maxOut, "--max", "2")
    Check "--max 2 writes 2 md" { (Get-MdCount (Join-Path $maxOut "items")) -eq 2 }

    # --- idempotency: re-run default into the same dir -> identical md file set ---
    $before = @(Get-ChildItem -LiteralPath $items -Filter *.md -File | Select-Object -ExpandProperty Name | Sort-Object)
    $null = Invoke-Tool @($fixtureXls, "--out", $out)
    $after = @(Get-ChildItem -LiteralPath $items -Filter *.md -File | Select-Object -ExpandProperty Name | Sort-Object)
    Check "re-run is idempotent (same md file set)" { ($before.Count -eq $after.Count) -and (($before -join "|") -eq ($after -join "|")) }
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count) { throw ("Sparrow XLS export E2E failed:`n  " + ($failures -join "`n  ")) }
Write-Host "Sparrow XLS export E2E passed."
