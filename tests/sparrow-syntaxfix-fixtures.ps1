#requires -Version 5.1
<#
    Opt-in end-to-end smoke test for SparrowSyntaxFix. NOT run by the default validate gate (needs the
    .NET SDK + a Roslyn restore -- env/time heavy). Run it manually, or via `validate.ps1 -IncludeSyntaxFixE2E`.

    It builds the FixtureTests harness + the tool, runs the in-memory before->after harness (the exact real
    Sparrow cases), then drives the real CLI over an on-disk UTF-8-BOM + CRLF file to assert: nullcast +
    parens applied, the HARD `= new` rule left untouched, BOM + CRLF preserved, generated `.Designer.cs`
    skipped, --dry-run writes nothing, and a re-run is byte-identical (idempotent). Skips cleanly (not
    fails) when the .NET SDK is missing.

    PS 5.1 notes honored here: collections wrapped in @() before .Count; no &&/ternary/null-coalescing;
    files read as raw BYTES for BOM/idempotency checks (the TOOL writes bytes via .NET, not via PowerShell).
#>
param([string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path)

$ErrorActionPreference = "Stop"
$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if (-not $dotnet) { Write-Host "dotnet SDK not found; skipping SparrowSyntaxFix E2E."; return }

$toolDir = Join-Path $RepositoryRoot "skills\sparrow-static-analysis\tools\SparrowSyntaxFix"
$toolProj = Join-Path $toolDir "SparrowSyntaxFix.csproj"
$fixtureProj = Join-Path $toolDir "FixtureTests\FixtureTests.csproj"
foreach ($p in @($toolProj, $fixtureProj)) { if (-not (Test-Path -LiteralPath $p)) { throw "missing project: $p" } }

$work = Join-Path $env:TEMP ("sparrow-syntaxfix-e2e-" + [guid]::NewGuid().ToString("N"))
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

try {
    Write-Host "  building FixtureTests + SparrowSyntaxFix (Release)..."
    & $dotnet.Source build $fixtureProj -c Release -v q 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "FixtureTests build failed" }
    & $dotnet.Source build $toolProj -c Release -v q 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "SparrowSyntaxFix build failed" }

    # 1) in-memory before->after harness (exact real Sparrow cases). Surface its output only on failure.
    $fxOut = (& $dotnet.Source run --project $fixtureProj -c Release --no-build 2>&1 | Out-String)
    $fxExit = $LASTEXITCODE
    if ($fxExit -ne 0) { Write-Host $fxOut }
    Check "C# fixture harness exits 0 (all before->after cases pass)" { $fxExit -eq 0 }

    # 2) real on-disk file: UTF-8 BOM + CRLF; nullcast + parens both apply; a `= new` must NOT be touched.
    $srcDir = Join-Path $work "src"
    New-Item -ItemType Directory -Force -Path $srcDir | Out-Null
    $nl = "`r`n"
    $lines = @(
        "class C",
        "{",
        "    void M()",
        "    {",
        "        CComponentInfo clsComponentInfo = null;",
        "        List<PropData> keep = new List<PropData>();",
        "        if (nIndex > 0 && nIndex <= nCount - 1)",
        "        {",
        "        }",
        "    }",
        "}")
    $content = ($lines -join $nl) + $nl
    $bomEnc = New-Object System.Text.UTF8Encoding($true)   # emit BOM
    $target = Join-Path $srcDir "Sample.cs"
    [System.IO.File]::WriteAllText($target, $content, $bomEnc)

    # a generated file that MUST be skipped by name
    $gen = Join-Path $srcDir "Widget.Designer.cs"
    [System.IO.File]::WriteAllText($gen, $content, $bomEnc)

    # --dry-run must not modify anything
    $before = [System.IO.File]::ReadAllBytes($target)
    $dryExit = Invoke-Tool @($srcDir, "--dry-run")
    Check "dry-run exits 0" { $dryExit -eq 0 }
    $afterDry = [System.IO.File]::ReadAllBytes($target)
    Check "dry-run leaves file byte-identical" { @(Compare-Object $before $afterDry -SyncWindow 0).Count -eq 0 }

    # apply
    $applyExit = Invoke-Tool @($srcDir)
    Check "apply exits 0" { $applyExit -eq 0 }

    $bytes = [System.IO.File]::ReadAllBytes($target)
    Check "BOM preserved (EF BB BF)" { ($bytes.Length -ge 3) -and ($bytes[0] -eq 0xEF) -and ($bytes[1] -eq 0xBB) -and ($bytes[2] -eq 0xBF) }

    $text = [System.Text.Encoding]::UTF8.GetString($bytes)   # .NET strips the BOM when decoding
    Check "nullcast applied" { $text.Contains("var clsComponentInfo = (CComponentInfo)null;") }
    Check "HARD rule: = new left untouched" { $text.Contains("List<PropData> keep = new List<PropData>();") }
    Check "parens applied" { $text.Contains("(nIndex > 0) && (nIndex <= nCount - 1)") }

    $lfCount = @([regex]::Matches($text, "`n")).Count
    $crlfCount = @([regex]::Matches($text, "`r`n")).Count
    Check "CRLF preserved (every LF is part of a CRLF)" { $lfCount -eq $crlfCount }

    $genText = [System.IO.File]::ReadAllText($gen)
    Check "generated .Designer.cs skipped" { $genText.Contains("CComponentInfo clsComponentInfo = null;") }

    # 3) idempotency: a second apply changes nothing (byte-identical)
    $firstBytes = [System.IO.File]::ReadAllBytes($target)
    $reExit = Invoke-Tool @($srcDir)
    Check "re-apply exits 0" { $reExit -eq 0 }
    $secondBytes = [System.IO.File]::ReadAllBytes($target)
    Check "idempotent (byte-identical second run)" { @(Compare-Object $firstBytes $secondBytes -SyncWindow 0).Count -eq 0 }

    # 4) --rules selection: nullcast-only leaves the && condition unparenthesized
    $selDir = Join-Path $work "sel"
    New-Item -ItemType Directory -Force -Path $selDir | Out-Null
    $selTarget = Join-Path $selDir "Sel.cs"
    [System.IO.File]::WriteAllText($selTarget, $content, $bomEnc)
    $null = Invoke-Tool @($selDir, "--rules", "nullcast")
    $selText = [System.IO.File]::ReadAllText($selTarget)
    Check "--rules nullcast applies nullcast" { $selText.Contains("var clsComponentInfo = (CComponentInfo)null;") }
    Check "--rules nullcast leaves parens alone" { $selText.Contains("if (nIndex > 0 && nIndex <= nCount - 1)") }
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count) { throw ("SparrowSyntaxFix E2E failed:`n  " + ($failures -join "`n  ")) }
Write-Host "SparrowSyntaxFix E2E passed."
