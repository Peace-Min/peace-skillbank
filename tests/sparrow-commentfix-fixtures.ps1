#requires -Version 5.1
<#
    Opt-in end-to-end smoke test for SparrowCommentFix. NOT run by the default validate gate (needs the
    .NET SDK + a Roslyn restore -- env/time heavy). Run it manually, or via `validate.ps1 -IncludeCommentE2E`.

    It builds the tool, writes synthetic .cs fixtures to a temp dir, runs the tool per rule, and asserts the
    2 ACTIVE rules (space / period) before/after, the string-literal SAFETY guarantee (`//` inside a string is
    never touched), idempotency, --dry-run (writes nothing), --files-from CSV parsing, and that the three
    NOT-active rules (capitalize / blankline / asterisk) and any unknown key all exit 2. Skips cleanly (not
    fails) when the .NET SDK is missing.

    (capitalize/blankline were REMOVED from the tool per real-data analysis: capitalize=한글/기호 첫글자 대문자화
    결정론 불가·주석처리 코드 오변형 위험, blankline=실물은 트레일링 주석 지적이라 반대 타깃; asterisk stays
    deferred. So `--rules all` now means space+period.)

    PS 5.1 notes honored here: collections wrapped in @() before .Count; no &&/ternary/null-coalescing;
    fixtures/results read with -Encoding UTF8 (the TOOL writes UTF-8 via .NET, not via PowerShell);
    before/after assertions use .Contains (ordinal/case-sensitive; -match is case-insensitive in PS).
    This script carries Korean literals -> it MUST stay UTF-8 WITH BOM so PS 5.1 parses it correctly.
#>
param([string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path)

$ErrorActionPreference = "Stop"
$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if (-not $dotnet) { Write-Host "dotnet SDK not found; skipping SparrowCommentFix E2E."; return }

$toolDir = Join-Path $RepositoryRoot "skills\sparrow-static-analysis\tools\SparrowCommentFix"
$toolProj = Join-Path $toolDir "SparrowCommentFix.csproj"
if (-not (Test-Path -LiteralPath $toolProj)) { throw "missing project: $toolProj" }

$work = Join-Path $env:TEMP ("commentfix-e2e-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$failures = @()
function Check($name, [scriptblock]$cond) {
    try { if (& $cond) { Write-Host "  [ok]   $name" } else { $script:failures += $name } }
    catch { $script:failures += "$name ($($_.Exception.Message))" }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$utf8Bom = New-Object System.Text.UTF8Encoding($true)

function New-Fixture {
    param([string]$Name, [string]$Content, [System.Text.Encoding]$Encoding = $utf8NoBom)
    $path = Join-Path $work $Name
    [System.IO.File]::WriteAllText($path, $Content, $Encoding)
    return $path
}

function Read-Text {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path, $utf8NoBom)
}

function Invoke-Tool {
    param([string[]]$ToolArgs)
    # EAP=Continue locally: a run that fails on purpose (exit 2) writes to stderr, and native stderr under
    # EAP=Stop with 2>&1 becomes a terminating error (see HANDOFF). We want the exit code, not a throw.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try { & $dotnet.Source run --project $toolProj -c Release --no-build -- @ToolArgs 2>&1 | Out-Null }
    finally { $ErrorActionPreference = $prev }
    return $LASTEXITCODE
}

function Test-BytesEqual {
    param([byte[]]$A, [byte[]]$B)
    if ($A.Length -ne $B.Length) { return $false }
    for ($i = 0; $i -lt $A.Length; $i++) { if ($A[$i] -ne $B[$i]) { return $false } }
    return $true
}

try {
    Write-Host "  building SparrowCommentFix (Release)..."
    & $dotnet.Source build $toolProj -c Release -v q 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "SparrowCommentFix build failed" }

    # --- rule: space ---
    $spaceSrc = @'
class C {
    void M() {
        //foo
        int a = 0;
        ///bar
        int b = 0;
        ////
        int c = 0;
        // ok
        int d = 0;
    }
}
'@
    $spaceFile = New-Fixture "space.cs" $spaceSrc
    Check "space: exit 0" { (Invoke-Tool @($spaceFile, "--rules", "space")) -eq 0 }
    $sp = Read-Text $spaceFile
    Check "space: //foo -> // foo" { $sp.Contains("// foo") -and (-not $sp.Contains("//foo")) }
    Check "space: ///bar -> /// bar" { $sp.Contains("/// bar") -and (-not $sp.Contains("///bar")) }
    Check "space: //// unchanged" { $sp.Contains("////") }
    Check "space: // ok unchanged (no double space)" { $sp.Contains("// ok") -and (-not $sp.Contains("//  ok")) }

    # --- rule: period ---
    $periodSrc = @'
class C {
    void M() {
        // hello
        // 안녕
        // done.
        // ok!
        // ----
        // 3)
        int a = 0;
    }
}
'@
    $periodFile = New-Fixture "period.cs" $periodSrc
    Check "period: exit 0" { (Invoke-Tool @($periodFile, "--rules", "period")) -eq 0 }
    $pd = Read-Text $periodFile
    Check "period: // hello -> // hello." { $pd.Contains("// hello.") }
    Check "period: // 안녕 -> // 안녕. (Hangul letter qualifies)" { $pd.Contains("// 안녕.") }
    Check "period: // done. unchanged (no second period)" { $pd.Contains("// done.") -and (-not $pd.Contains("// done..")) }
    Check "period: // ok! unchanged" { $pd.Contains("// ok!") -and (-not $pd.Contains("// ok!.")) }
    Check "period: // ---- divider unchanged" { $pd.Contains("// ----") -and (-not $pd.Contains("// ----.")) }
    Check "period: // 3) ends non-letter unchanged" { $pd.Contains("// 3)") -and (-not $pd.Contains("// 3).")) }

    # capitalize / blankline were REMOVED from the tool (real-data analysis). Their exit-2 checks live with the
    # asterisk/unknown checks at the end of this script; there are no before/after fixtures for them anymore.

    # --- SAFETY: `//` inside string literals is never a comment -> --rules all leaves the file byte-identical ---
    $safeSrc = @'
class C {
    string M() {
        var s = "http://example.com";
        var t = "a//b";
        return s + t;
    }
}
'@
    $safeFile = New-Fixture "safety.cs" $safeSrc
    $safeBefore = [System.IO.File]::ReadAllBytes($safeFile)
    Check "safety: --rules all exit 0" { (Invoke-Tool @($safeFile, "--rules", "all")) -eq 0 }
    $safeAfter = [System.IO.File]::ReadAllBytes($safeFile)
    Check "safety: file byte-identical (string-literal // untouched)" { Test-BytesEqual $safeBefore $safeAfter }
    $safeText = Read-Text $safeFile
    Check "safety: string http://example.com intact" { $safeText.Contains('"http://example.com"') }
    Check "safety: string a//b intact" { $safeText.Contains('"a//b"') }

    # --- IDEMPOTENCY: running --rules all twice yields identical bytes on the second run ---
    $idemSrc = @'
class C
{
    void M()
    {
        int x = 0;
        //hello
        var s = "http://x";
    }
}
'@
    $idemFile = New-Fixture "idem.cs" $idemSrc
    Check "idempotency: first --rules all exit 0" { (Invoke-Tool @($idemFile, "--rules", "all")) -eq 0 }
    $idemAfter1 = [System.IO.File]::ReadAllBytes($idemFile)
    Check "idempotency: second --rules all exit 0" { (Invoke-Tool @($idemFile, "--rules", "all")) -eq 0 }
    $idemAfter2 = [System.IO.File]::ReadAllBytes($idemFile)
    Check "idempotency: second run is byte-identical to first" { Test-BytesEqual $idemAfter1 $idemAfter2 }

    # --- --dry-run: computes changes but writes nothing ---
    $drySrc = @'
class C
{
    void M()
    {
        int x = 0;
        //hello
    }
}
'@
    $dryFile = New-Fixture "dry.cs" $drySrc
    $dryBefore = [System.IO.File]::ReadAllBytes($dryFile)
    Check "dry-run: exit 0" { (Invoke-Tool @($dryFile, "--rules", "all", "--dry-run")) -eq 0 }
    $dryAfter = [System.IO.File]::ReadAllBytes($dryFile)
    Check "dry-run: file unchanged (nothing written)" { Test-BytesEqual $dryBefore $dryAfter }

    # --- --files-from index.csv: distinct 파일명 column drives which file is edited ---
    $ffSrc = @'
class C {
    void M() {
        //x
        int a = 0;
    }
}
'@
    $null = New-Fixture "ff_fixture.cs" $ffSrc
    # index.csv WITH BOM; the 위험도 AND 체커명 columns are quoted and contain commas to prove CSV parsing
    # (a naive Split(',') would misread the 파일명 column that sits AFTER the quoted comma-bearing 위험도).
    $csv = @'
md_file,ID,체커 키,위험도,파일명,라인,이슈 상태,체커명
items/1.md,101,FORMATTING.COMMENT.MISSING_SPACE_AFTER_DELIMITER,"낮음,높음",ff_fixture.cs,7,미해결,"사용되지 않는 객체, 암시적 타입"
'@
    $csvPath = Join-Path $work "index.csv"
    [System.IO.File]::WriteAllText($csvPath, $csv, $utf8Bom)
    Check "files-from: exit 0" { (Invoke-Tool @("--files-from", $csvPath, "--root", $work, "--rules", "space")) -eq 0 }
    $ffText = Read-Text (Join-Path $work "ff_fixture.cs")
    Check "files-from: named fixture edited (//x -> // x)" { $ffText.Contains("// x") -and (-not $ffText.Contains("//x")) }

    # --- not-active / unknown rules -> exit 2 (capitalize & blankline removed per real-data analysis) ---
    Check "capitalize rule -> exit 2 (removed)" { (Invoke-Tool @($spaceFile, "--rules", "capitalize")) -eq 2 }
    Check "blankline rule -> exit 2 (removed)" { (Invoke-Tool @($spaceFile, "--rules", "blankline")) -eq 2 }
    Check "asterisk rule -> exit 2 (deferred)" { (Invoke-Tool @($spaceFile, "--rules", "asterisk")) -eq 2 }
    Check "unknown rule -> exit 2" { (Invoke-Tool @($spaceFile, "--rules", "bogus")) -eq 2 }
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count) { throw ("SparrowCommentFix E2E failed:`n  " + ($failures -join "`n  ")) }
Write-Host "SparrowCommentFix E2E passed."
