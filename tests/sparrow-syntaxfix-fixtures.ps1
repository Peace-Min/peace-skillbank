#requires -Version 5.1
<#
    Opt-in end-to-end smoke test for SparrowSyntaxFix. NOT run by the default validate gate (needs the
    .NET SDK + a Roslyn restore -- env/time heavy). Run it manually, or via `validate.ps1 -IncludeSyntaxFixE2E`.

    It builds the FixtureTests harness + the tool, runs the in-memory before->after harness (the exact real
    Sparrow cases), then drives the real CLI over an on-disk UTF-8-BOM + CRLF file containing the real
    6869-style findings to assert: nullvar + objectvar-safe + objectvar-narrowing + objectinitializer +
    arrayvar-safe + arrayvar-narrowing + foreachcast + obviousvar + localconst + parens applied,
    the rewritten test project builds, BOM + CRLF preserved, generated `.Designer.cs`
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

    # 2) real on-disk project/file: UTF-8 BOM + CRLF; all Track-A Roslyn rules apply to real 6869-style patterns.
    $srcDir = Join-Path $work "src"
    New-Item -ItemType Directory -Force -Path $srcDir | Out-Null
    $nl = "`r`n"
    $lines = @(
        "using System;",
        "using System.Collections.Generic;",
        "using System.Xml;",
        "",
        "interface IFoo { }",
        "class Foo : IFoo { }",
        "class PropData { }",
        "class InitTarget { public int A { get; set; } public int B { get; set; } }",
        "class CComponentInfo { }",
        "class CPlayerObjectInfo { }",
        "class PatternOnly { public PatternEnumerator GetEnumerator() { return new PatternEnumerator(); } }",
        "class PatternEnumerator { public FooNode Current { get { return new FooNode(); } } public bool MoveNext() { return false; } }",
        "class FooNode { }",
        "",
        "class C",
        "{",
        "    void M()",
        "    {",
        "        const string szDescriptName = ""Description"";",
        "        double markerH = 20;",
        "        object boxed = ""x"";",
        "        int? pageSize = 0;",
        "        CComponentInfo clsComponentInfo = null;",
        "        CPlayerObjectInfo player;",
        "        player = new CPlayerObjectInfo();",
        "        PropData keep = new PropData();",
        "        IFoo iface = new Foo();",
        "        XmlDocument doc = new XmlDocument();",
        "        XmlNodeList clsNodes = doc.ChildNodes;",
        "        InitTarget init = new InitTarget();",
        "        init.A = 1;",
        "        init.B = 2;",
        "        int[] values = new int[] { 1, 2, 3 };",
        "        object[] names = new string[] { ""A"", ""B"" };",
        "        object[] riskyNames = new string[] { null };",
        "        Delegate[] handlers = new Action[] { Target };",
        "        Delegate[] handlers2 = new Action[] { (Target) };",
        "        foreach (XmlNode node in clsNodes)",
        "        {",
        "            _ = node.Name;",
        "        }",
        "        PatternOnly pattern = new PatternOnly();",
        "        foreach (FooNode item in pattern)",
        "        {",
        "            _ = item;",
        "        }",
        "        int nIndex = 1;",
        "        int nCount = 3;",
        "        if (nIndex > 0 && nIndex <= nCount - 1)",
        "        {",
        "        }",
        "        Console.WriteLine(szDescriptName + markerH + pageSize + clsComponentInfo + player + keep + iface + init + values + names + riskyNames + handlers + handlers2);",
        "    }",
        "    void Target() { }",
        "}")
    $content = ($lines -join $nl) + $nl
    $bomEnc = New-Object System.Text.UTF8Encoding($true)   # emit BOM
    $target = Join-Path $srcDir "Sample.cs"
    [System.IO.File]::WriteAllText($target, $content, $bomEnc)

    $proj = Join-Path $srcDir "SyntaxFixture.csproj"
    $projText = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <LangVersion>7.3</LangVersion>
    <Nullable>disable</Nullable>
    <ImplicitUsings>false</ImplicitUsings>
    <OutputType>Library</OutputType>
    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>
  </PropertyGroup>
  <ItemGroup>
    <Compile Include="Sample.cs" />
  </ItemGroup>
</Project>
"@
    [System.IO.File]::WriteAllText($proj, $projText, (New-Object System.Text.UTF8Encoding($false)))

    # a generated file that MUST be skipped by name
    $gen = Join-Path $srcDir "Widget.Designer.cs"
    [System.IO.File]::WriteAllText($gen, $content, $bomEnc)

    # --dry-run must not modify anything
    $before = [System.IO.File]::ReadAllBytes($target)
    $dryExit = Invoke-Tool @($srcDir, "--rules", "all", "--dry-run")
    Check "dry-run exits 0" { $dryExit -eq 0 }
    $afterDry = [System.IO.File]::ReadAllBytes($target)
    Check "dry-run leaves file byte-identical" { @(Compare-Object $before $afterDry -SyncWindow 0).Count -eq 0 }

    # apply
    $applyExit = Invoke-Tool @($srcDir, "--rules", "all")
    Check "apply exits 0" { $applyExit -eq 0 }

    $bytes = [System.IO.File]::ReadAllBytes($target)
    Check "BOM preserved (EF BB BF)" { ($bytes.Length -ge 3) -and ($bytes[0] -eq 0xEF) -and ($bytes[1] -eq 0xBB) -and ($bytes[2] -eq 0xBF) }

    $text = [System.Text.Encoding]::UTF8.GetString($bytes)   # .NET strips the BOM when decoding
    Check "localconst applied" { $text.Contains("var szDescriptName = ""Description"";") }
    Check "obviousvar numeric cast applied" { $text.Contains("var markerH = (double)20;") }
    Check "obviousvar object literal narrowing skipped" { $text.Contains("object boxed = ""x"";") }
    Check "obviousvar nullable numeric cast applied" { $text.Contains("var pageSize = (int?)0;") }
    Check "nullvar initializer applied" { $text.Contains("var clsComponentInfo = (CComponentInfo)null;") }
    Check "nullvar no-initializer applied" { $text.Contains("var player = (CPlayerObjectInfo)null;") }
    Check "objectvar-safe applied" { $text.Contains("var keep = new PropData();") }
    Check "objectvar-narrowing applied" { $text.Contains("var iface = new Foo();") }
    Check "objectinitializer applied" { $text.Contains("var init = new InitTarget { A = 1, B = 2 };") }
    Check "arrayvar-safe applied" { $text.Contains("int[] values = { 1, 2, 3 };") }
    Check "arrayvar-narrowing applied" { $text.Contains("var names = new[] { ""A"", ""B"" };") }
    Check "arrayvar-narrowing null inference risk skipped" { $text.Contains("object[] riskyNames = new string[] { null };") }
    Check "arrayvar-narrowing method group target typing skipped" { $text.Contains("Delegate[] handlers = new Action[] { Target };") }
    Check "arrayvar-narrowing parenthesized method group target typing skipped" { $text.Contains("Delegate[] handlers2 = new Action[] { (Target) };") }
    Check "foreachcast applied" { $text.Contains("foreach (var node in System.Linq.Enumerable.Cast<XmlNode>(clsNodes))") }
    Check "foreachcast pattern enumerator skipped" { $text.Contains("foreach (FooNode item in pattern)") }
    Check "parens applied" { $text.Contains("(nIndex > 0) && (nIndex <= nCount - 1)") }

    $buildOut = (& $dotnet.Source build $proj -c Release -v q 2>&1 | Out-String)
    $buildExit = $LASTEXITCODE
    if ($buildExit -ne 0) { Write-Host $buildOut }
    Check "rewritten real-pattern test project builds" { $buildExit -eq 0 }

    $lfCount = @([regex]::Matches($text, "`n")).Count
    $crlfCount = @([regex]::Matches($text, "`r`n")).Count
    Check "CRLF preserved (every LF is part of a CRLF)" { $lfCount -eq $crlfCount }

    $genText = [System.IO.File]::ReadAllText($gen)
    Check "generated .Designer.cs skipped" { $genText.Contains("CComponentInfo clsComponentInfo = null;") }

    # 3) idempotency: a second apply changes nothing (byte-identical)
    $firstBytes = [System.IO.File]::ReadAllBytes($target)
    $reExit = Invoke-Tool @($srcDir, "--rules", "all")
    Check "re-apply exits 0" { $reExit -eq 0 }
    $secondBytes = [System.IO.File]::ReadAllBytes($target)
    Check "idempotent (byte-identical second run)" { @(Compare-Object $firstBytes $secondBytes -SyncWindow 0).Count -eq 0 }

    # 4) --rules selection: nullvar-only leaves the && condition and object creation alone
    $selDir = Join-Path $work "sel"
    New-Item -ItemType Directory -Force -Path $selDir | Out-Null
    $selTarget = Join-Path $selDir "Sel.cs"
    [System.IO.File]::WriteAllText($selTarget, $content, $bomEnc)
    $null = Invoke-Tool @($selDir, "--rules", "nullvar")
    $selText = [System.IO.File]::ReadAllText($selTarget)
    Check "--rules nullvar applies nullvar" { $selText.Contains("var clsComponentInfo = (CComponentInfo)null;") }
    Check "--rules nullvar leaves object creation alone" { $selText.Contains("PropData keep = new PropData();") }
    Check "--rules nullvar leaves foreach alone" { $selText.Contains("foreach (XmlNode node in clsNodes)") }
    Check "--rules nullvar leaves parens alone" { $selText.Contains("if (nIndex > 0 && nIndex <= nCount - 1)") }

    # 5) one-call runner parses cleanly (Run-TrackA.ps1 대응 러너)
    $runner = Join-Path $PSScriptRoot "..\skills\sparrow-static-analysis\tools\SparrowSyntaxFix\Run-SparrowSyntaxFix.ps1"
    Check "Run-SparrowSyntaxFix.ps1 exists" { Test-Path -LiteralPath $runner }
    Check "Run-SparrowSyntaxFix.ps1 parses (no syntax error)" {
        $perr = $null
        [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $runner).Path, [ref]$null, [ref]$perr) | Out-Null
        (-not $perr) -or ($perr.Count -eq 0)
    }
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count) { throw ("SparrowSyntaxFix E2E failed:`n  " + ($failures -join "`n  ")) }
Write-Host "SparrowSyntaxFix E2E passed."
