#requires -Version 5.1
<#
    Opt-in end-to-end smoke test for SparrowCommentFix. NOT run by the default validate gate (needs the
    .NET SDK + a Roslyn restore -- env/time heavy). Run it manually, or via `validate.ps1 -IncludeCommentE2E`.

    It builds the tool, writes synthetic .cs fixtures to a temp dir, runs the tool per rule, and asserts the
    ACTIVE rules (comment + layout) before/after, the string-literal SAFETY guarantee (`//` inside a string is
    never touched), idempotency, --dry-run (writes nothing), --files-from CSV parsing, and that the three
    NOT-active rules (capitalize / blankline / asterisk) and any unknown key all exit 2. Skips cleanly (not
    fails) when the .NET SDK is missing.

    `--rules all` means all active comment + layout rules; runner defaults are narrower.

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

    # --- rule: flatten (6+7+8: block/Doxygen comment -> line comments, capitalized, periodized) ---
    $flattenSrc = @'
class C {
    void M() {
        /**.
         * @brief delta event marker 반환
         *
         * @param annot annotation 객체
         * @returns delta event marker 객체
         */
        int a = 0;
    }
}
'@
    $flattenFile = New-Fixture "flatten.cs" $flattenSrc
    Check "flatten: exit 0" { (Invoke-Tool @($flattenFile, "--rules", "flatten")) -eq 0 }
    $fl = Read-Text $flattenFile
    Check "flatten: @brief line normalized" { $fl.Contains("// Delta event marker 반환.") }
    Check "flatten: @param line normalized" { $fl.Contains("// Param annot annotation 객체.") }
    Check "flatten: @returns line normalized" { $fl.Contains("// Returns delta event marker 객체.") }
    Check "flatten: block delimiters removed" { (-not $fl.Contains("/**")) -and (-not $fl.Contains("*/")) -and (-not $fl.Contains(" * @")) }
    Check "flatten: no punctuation-only comment emitted" { (-not $fl.Contains("// .")) }

    # --- rule: trailing (9: move inline comment above code and normalize comment style) ---
    $trailingSrc = @'
class C {
    void M() {
        int count = 0; //ABC
        string url = "http://example.com"; //url
    }
}
'@
    $trailingFile = New-Fixture "trailing.cs" $trailingSrc
    Check "trailing: exit 0" { (Invoke-Tool @($trailingFile, "--rules", "trailing")) -eq 0 }
    $tr = Read-Text $trailingFile
    Check "trailing: comment moved above first code line" { $tr.Contains("        // ABC.`r`n        int count = 0;") -or $tr.Contains("        // ABC.`n        int count = 0;") }
    Check "trailing: string literal URL intact and comment moved" { $tr.Contains('"http://example.com"') -and ($tr.Contains("// Url.`r`n        string url") -or $tr.Contains("// Url.`n        string url")) }

    # flatten negative: block comments embedded in code are not standalone comment lines and must not be changed.
    $flatNegSrc = @'
class C {
    void M() {
        int x = /* note */ 1;
        Foo(/* note */ x);
    }
}
'@
    $flatNegFile = New-Fixture "flatten_negative.cs" $flatNegSrc
    $flatNegBefore = [System.IO.File]::ReadAllBytes($flatNegFile)
    Check "flatten negative: exit 0" { (Invoke-Tool @($flatNegFile, "--rules", "flatten")) -eq 0 }
    $flatNegAfter = [System.IO.File]::ReadAllBytes($flatNegFile)
    Check "flatten negative: embedded block comments byte-identical" { Test-BytesEqual $flatNegBefore $flatNegAfter }

    # trailing negative: closing-brace comments and suppression comments stay in place.
    $trailNegSrc = @'
class C {
    void M() {
        if (true) { } // namespace-ish
        int x = 0; // NOSONAR
    }
}
'@
    $trailNegFile = New-Fixture "trailing_negative.cs" $trailNegSrc
    $trailNegBefore = [System.IO.File]::ReadAllBytes($trailNegFile)
    Check "trailing negative: exit 0" { (Invoke-Tool @($trailNegFile, "--rules", "trailing")) -eq 0 }
    $trailNegAfter = [System.IO.File]::ReadAllBytes($trailNegFile)
    Check "trailing negative: unsafe comments byte-identical" { Test-BytesEqual $trailNegBefore $trailNegAfter }

    $protectedSrc = @'
class C {
    void M() {
        /**
         * @code
         * int x = 0;
         * @endcode
         */
        int x = 0; //NOSONAR
        /** See @ref Foo */
        /** \code */
    }
}
'@
    $protectedFile = New-Fixture "protected_all.cs" $protectedSrc
    $protectedBefore = [System.IO.File]::ReadAllBytes($protectedFile)
    Check "protected comments: --rules all exit 0" { (Invoke-Tool @($protectedFile, "--rules", "all")) -eq 0 }
    $protectedAfter = [System.IO.File]::ReadAllBytes($protectedFile)
    Check "protected comments: --rules all byte-identical" { Test-BytesEqual $protectedBefore $protectedAfter }

    $tagBoundarySrc = @'
class C {
    void M() {
        /** @briefly not a real brief */
        /** @parameter not a real param */
    }
}
'@
    $tagBoundaryFile = New-Fixture "tag_boundary.cs" $tagBoundarySrc
    $tagBoundaryBefore = [System.IO.File]::ReadAllBytes($tagBoundaryFile)
    Check "tag boundary: exit 0" { (Invoke-Tool @($tagBoundaryFile, "--rules", "all")) -eq 0 }
    $tagBoundaryAfter = [System.IO.File]::ReadAllBytes($tagBoundaryFile)
    Check "tag boundary: unsupported prefixes byte-identical" { Test-BytesEqual $tagBoundaryBefore $tagBoundaryAfter }

    $lineDoxygenSrc = @'
class C {
    void M() {
        /// @unknown custom command
        /// See @unknown custom command
        // \brief native doxygen command
        int x = 0; // \brief trailing command
    }
}
'@
    $lineDoxygenFile = New-Fixture "line_doxygen.cs" $lineDoxygenSrc
    $lineDoxygenBefore = [System.IO.File]::ReadAllBytes($lineDoxygenFile)
    Check "line-form Doxygen protection: exit 0" { (Invoke-Tool @($lineDoxygenFile, "--rules", "all")) -eq 0 }
    $lineDoxygenAfter = [System.IO.File]::ReadAllBytes($lineDoxygenFile)
    Check "line-form Doxygen protection: byte-identical" { Test-BytesEqual $lineDoxygenBefore $lineDoxygenAfter }

    $parseErrorSrc = @'
class C {
    void M( {
        //bad
    }
}
'@
    $parseErrorFile = New-Fixture "parse_error.cs" $parseErrorSrc
    $parseErrorBefore = [System.IO.File]::ReadAllBytes($parseErrorFile)
    Check "parse error: --rules all exit 0" { (Invoke-Tool @($parseErrorFile, "--rules", "all")) -eq 0 }
    $parseErrorAfter = [System.IO.File]::ReadAllBytes($parseErrorFile)
    Check "parse error: byte-identical skip" { Test-BytesEqual $parseErrorBefore $parseErrorAfter }

    # --- layout: memberblank ---
    $memberSrc = @'
interface IReport {
    string PrepareData(string name);
    bool SetWriteCSVFile(string path);
}
'@
    $memberFile = New-Fixture "memberblank.cs" $memberSrc
    Check "memberblank: exit 0" { (Invoke-Tool @($memberFile, "--rules", "memberblank")) -eq 0 }
    $mb = Read-Text $memberFile
    Check "memberblank: interface methods separated" { $mb.Contains("    string PrepareData(string name);`r`n`r`n    bool SetWriteCSVFile") -or $mb.Contains("    string PrepareData(string name);`n`n    bool SetWriteCSVFile") }
    $memberOnce = [System.IO.File]::ReadAllBytes($memberFile)
    Check "memberblank: second run exit 0" { (Invoke-Tool @($memberFile, "--rules", "memberblank")) -eq 0 }
    $memberTwice = [System.IO.File]::ReadAllBytes($memberFile)
    Check "memberblank: second run byte-identical" { Test-BytesEqual $memberOnce $memberTwice }

    $compactMemberSrc = @'
class C { void A() { } void B() { } }
'@
    $compactMemberFile = New-Fixture "memberblank_compact.cs" $compactMemberSrc
    $compactMemberBefore = [System.IO.File]::ReadAllBytes($compactMemberFile)
    Check "memberblank compact: first run exit 0" { (Invoke-Tool @($compactMemberFile, "--rules", "memberblank")) -eq 0 }
    $compactMemberAfter1 = [System.IO.File]::ReadAllBytes($compactMemberFile)
    Check "memberblank compact: first run byte-identical" { Test-BytesEqual $compactMemberBefore $compactMemberAfter1 }
    Check "memberblank compact: second run exit 0" { (Invoke-Tool @($compactMemberFile, "--rules", "memberblank")) -eq 0 }
    $compactMemberAfter2 = [System.IO.File]::ReadAllBytes($compactMemberFile)
    Check "memberblank compact: second run byte-identical" { Test-BytesEqual $compactMemberAfter1 $compactMemberAfter2 }

    # --- layout: onedeclaration ---
    $declSrc = @'
class C {
    public double X, Y, Z;
    void M() {
        string objectName, subPath;
        double initialX_Min = 0, initialX_Max = 0;
    }
}
'@
    $declFile = New-Fixture "onedeclaration.cs" $declSrc
    Check "onedeclaration: exit 0" { (Invoke-Tool @($declFile, "--rules", "onedeclaration")) -eq 0 }
    $dc = Read-Text $declFile
    Check "onedeclaration: fields split" { $dc.Contains("    public double X;`r`n    public double Y;`r`n    public double Z;") -or $dc.Contains("    public double X;`n    public double Y;`n    public double Z;") }
    Check "onedeclaration: locals split" { $dc.Contains("        string objectName;`r`n        string subPath;") -or $dc.Contains("        string objectName;`n        string subPath;") }
    Check "onedeclaration: initialized locals split" { $dc.Contains("        double initialX_Min = 0;`r`n        double initialX_Max = 0;") -or $dc.Contains("        double initialX_Min = 0;`n        double initialX_Max = 0;") }

    # --- layout: onestatement ---
    $stmtSrc = @'
class C {
    void M() {
        X = x; Y = y;
        if (ok) { A = false; B = false; }
    }
}
'@
    $stmtFile = New-Fixture "onestatement.cs" $stmtSrc
    Check "onestatement: exit 0" { (Invoke-Tool @($stmtFile, "--rules", "onestatement")) -eq 0 }
    $st = Read-Text $stmtFile
    Check "onestatement: adjacent assignments split" { $st.Contains("        X = x;`r`n        Y = y;") -or $st.Contains("        X = x;`n        Y = y;") }
    Check "onestatement: single-line if block expanded" { $st.Contains("if (ok)`r`n        {") -or $st.Contains("if (ok)`n        {") -or $st.Contains("if (ok) {`r`n            A = false;") -or $st.Contains("if (ok) {`n            A = false;") }

    $nestedStmtSrc = @'
class C {
    void M() {
        if (a) { if (b) { A(); B(); } C(); }
    }
}
'@
    $nestedStmtFile = New-Fixture "onestatement_nested.cs" $nestedStmtSrc
    Check "onestatement nested: exit 0 without overlapping edits" { (Invoke-Tool @($nestedStmtFile, "--rules", "onestatement")) -eq 0 }
    $nestedStmtText = Read-Text $nestedStmtFile
    Check "onestatement nested: file remains parseable text" { $nestedStmtText.Contains("if (a)") -and $nestedStmtText.Contains("if (b)") }

    # --- layout: continuation ---
    $contSrc = @'
class C {
    void M() {
        PlayerInfoXML = new XElement("playerInfo",
        new XAttribute("symbolICOPS", value),
        new XAttribute("movepath_opt_1", value));
        if ((A) &&
           (B))
        {
        }
    }
}
'@
    $contFile = New-Fixture "continuation.cs" $contSrc
    Check "continuation: exit 0" { (Invoke-Tool @($contFile, "--rules", "continuation")) -eq 0 }
    $ct = Read-Text $contFile
    Check "continuation: arguments indented one level" { $ct.Contains("        PlayerInfoXML = new XElement(`"playerInfo`",`r`n            new XAttribute") -or $ct.Contains("        PlayerInfoXML = new XElement(`"playerInfo`",`n            new XAttribute") }
    Check "continuation: binary right operand indented one level" { $ct.Contains("        if ((A) &&`r`n            (B))") -or $ct.Contains("        if ((A) &&`n            (B))") }

    $contOverSrc = @'
class C {
    void M() {
        PlayerInfoXML = new XElement("playerInfo",
                new XAttribute("symbolICOPS", value));
    }
}
'@
    $contOverFile = New-Fixture "continuation_overindented.cs" $contOverSrc
    $contOverBefore = [System.IO.File]::ReadAllBytes($contOverFile)
    Check "continuation overindented: exit 0" { (Invoke-Tool @($contOverFile, "--rules", "continuation")) -eq 0 }
    $contOverAfter = [System.IO.File]::ReadAllBytes($contOverFile)
    Check "continuation overindented: byte-identical no churn" { Test-BytesEqual $contOverBefore $contOverAfter }

    # --- continuation: OPERATOR-LED style (dominant in OSTES): the continuation line begins with `&&`/`||`,
    #     not the operand. The indent fix must target the operator token and set it to if-indent + 4. ---
    $contOpLedSrc = @'
public class C {
    public void M(int a) {
        if (20 > 10
        && 30 > 10)
        { System.Console.WriteLine("x"); }
        if (a > 0
        || a < 5)
        { }
    }
}
'@
    $contOpLedFile = New-Fixture "continuation_opled.cs" $contOpLedSrc
    Check "continuation op-led: exit 0" { (Invoke-Tool @($contOpLedFile, "--rules", "continuation")) -eq 0 }
    $col = Read-Text $contOpLedFile
    Check "continuation op-led: && line indented to if-indent+4" { $col.Contains("        if (20 > 10`r`n            && 30 > 10)") -or $col.Contains("        if (20 > 10`n            && 30 > 10)") }
    Check "continuation op-led: || line indented to if-indent+4" { $col.Contains("        if (a > 0`r`n            || a < 5)") -or $col.Contains("        if (a > 0`n            || a < 5)") }
    # idempotency: a second run makes zero further changes (byte-identical).
    $contOpLed1 = [System.IO.File]::ReadAllBytes($contOpLedFile)
    Check "continuation op-led: second run exit 0" { (Invoke-Tool @($contOpLedFile, "--rules", "continuation")) -eq 0 }
    $contOpLed2 = [System.IO.File]::ReadAllBytes($contOpLedFile)
    Check "continuation op-led: second run byte-identical (idempotent)" { Test-BytesEqual $contOpLed1 $contOpLed2 }

    # already-correct op-led continuation: `&&` already at if-indent+4 -> no change, no churn.
    $contOkSrc = @'
public class C {
    public void M() {
        if (20 > 10
            && 30 > 10)
        { }
    }
}
'@
    $contOkFile = New-Fixture "continuation_opled_ok.cs" $contOkSrc
    $contOkBefore = [System.IO.File]::ReadAllBytes($contOkFile)
    Check "continuation op-led already-correct: exit 0" { (Invoke-Tool @($contOkFile, "--rules", "continuation")) -eq 0 }
    $contOkAfter = [System.IO.File]::ReadAllBytes($contOkFile)
    Check "continuation op-led already-correct: byte-identical no churn" { Test-BytesEqual $contOkBefore $contOkAfter }

    # --- layout: linqalign ---
    $linqSrc = @'
using System.Linq;
class C {
    void M() {
        var orderedEvents = (from entry in sourceEvents
                                                where entry.Event != null
                                                orderby entry.Event.Timestamp
                                                select entry).ToList();
    }
}
'@
    $linqFile = New-Fixture "linqalign.cs" $linqSrc
    Check "linqalign: exit 0" { (Invoke-Tool @($linqFile, "--rules", "linqalign")) -eq 0 }
    $lq = Read-Text $linqFile
    Check "linqalign: clauses aligned to from" { $lq.Contains("        var orderedEvents = (from entry in sourceEvents`r`n                             where entry.Event != null`r`n                             orderby entry.Event.Timestamp`r`n                             select entry)") -or $lq.Contains("        var orderedEvents = (from entry in sourceEvents`n                             where entry.Event != null`n                             orderby entry.Event.Timestamp`n                             select entry)") }

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
        /** @brief delta event marker 반환 */
        int y = 1; //abc
        X = x; Y = y;
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
