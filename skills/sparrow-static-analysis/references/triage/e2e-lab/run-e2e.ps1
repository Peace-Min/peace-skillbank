#requires -Version 5.1
<#
    run-e2e.ps1 — END-TO-END integration test for the Sparrow (파수) Track C processing pipeline.

    Exercises the REAL pieces (parser exe + Run-Triage.ps1 + Compare-Sparrow.ps1 + guide files)
    against a realistic mini C# project with planted defects and generated Sparrow-style .xls.

    Pipeline proven: 파싱(parser) -> prepare -> 수정+빌드(G1) -> G2 게이트.
    Prints PASS/FAIL per check; exits nonzero if any check fails.
#>
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$TriageDir = Split-Path -Parent $ScriptDir                      # references\triage
$RefsDir   = Split-Path -Parent $TriageDir                      # references
$SkillDir  = Split-Path -Parent $RefsDir                        # skills\sparrow-static-analysis
$Checkers  = Join-Path $RefsDir 'checkers'
$RunTriage = Join-Path $TriageDir 'Run-Triage.ps1'
$Compare   = Join-Path $TriageDir 'Compare-Sparrow.ps1'
$ParserExe = 'C:\Users\CEO\Desktop\dotnet-gcdump-offline\sparrow-xlsexport\win-x64\SparrowXlsExport.exe'

if (-not (Test-Path -LiteralPath $ParserExe)) {
    $parserProject = Join-Path $SkillDir 'tools\_internal\SparrowXlsExport\SparrowXlsExport.csproj'
    $localParser = Join-Path (Split-Path -Parent $parserProject) 'bin\Release\net8.0\SparrowXlsExport.exe'
    if (-not (Test-Path -LiteralPath $localParser)) {
        & dotnet build $parserProject -c Release | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "SparrowXlsExport build failed: $parserProject" }
    }
    $ParserExe = $localParser
}

$Out       = Join-Path $ScriptDir '_out'
$BeforeXls = Join-Path $ScriptDir 'sample-before.xls'
$AfterXls  = Join-Path $ScriptDir 'sample-after.xls'

# ---- tiny assert harness --------------------------------------------------
$script:Fails = 0
$script:Checks = 0
function Check {
    param([string]$Name, [bool]$Cond, [string]$Detail = '')
    $script:Checks++
    if ($Cond) {
        Write-Host ("  [PASS] {0}" -f $Name)
    } else {
        $script:Fails++
        Write-Host ("  [FAIL] {0}{1}" -f $Name, $(if ($Detail) { "  -- $Detail" } else { '' }))
    }
}
function Read-TextNoBom {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $t = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($t.Length -gt 0 -and [int][char]$t[0] -eq 0xFEFF) { $t = $t.Substring(1) }
    return $t
}

Write-Host "==================== Sparrow Track C E2E ===================="
Write-Host ("ScriptDir : {0}" -f $ScriptDir)
Write-Host ("Parser    : {0}" -f $ParserExe)
Write-Host ("RunTriage : {0}" -f $RunTriage)
Write-Host ("Compare   : {0}" -f $Compare)
Write-Host ("Checkers  : {0}" -f $Checkers)

# preconditions
Check "parser exe exists"        (Test-Path -LiteralPath $ParserExe) $ParserExe
Check "Run-Triage.ps1 exists"    (Test-Path -LiteralPath $RunTriage) $RunTriage
Check "Compare-Sparrow.ps1 exists" (Test-Path -LiteralPath $Compare) $Compare
Check "checkers guide dir exists" (Test-Path -LiteralPath $Checkers) $Checkers

# clean out dir
if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Recurse -Force }
[void](New-Item -ItemType Directory -Force -Path $Out)

# ---- generate golden xls (NPOI) -------------------------------------------
Write-Host "`n---- gen-xls: generate golden sample-before.xls / sample-after.xls ----"
& dotnet run --project (Join-Path $ScriptDir 'gen-xls') -c Release -- $ScriptDir 2>&1 | Out-Null
Check "gen-xls exit 0"           ($LASTEXITCODE -eq 0) "exit=$LASTEXITCODE"
Check "sample-before.xls created" (Test-Path -LiteralPath $BeforeXls) $BeforeXls
Check "sample-after.xls created"  (Test-Path -LiteralPath $AfterXls) $AfterXls

# ============================================================ A. 파싱
Write-Host "`n==== A. 파싱 (parser -> items/index.csv) ===="
$parsed = Join-Path $Out 'parsed'
& $ParserExe $BeforeXls --out $parsed | Out-Null
$parseExit = $LASTEXITCODE
Check "A: parser exit 0"         ($parseExit -eq 0) "exit=$parseExit"
$itemsDir = Join-Path $parsed 'items'
$mdCount = 0
if (Test-Path -LiteralPath $itemsDir) { $mdCount = @(Get-ChildItem -LiteralPath $itemsDir -Filter *.md -File).Count }
Check "A: 5 item .md files"      ($mdCount -eq 5) "found=$mdCount"
$indexCsv = Join-Path $parsed 'index.csv'
Check "A: index.csv present"     (Test-Path -LiteralPath $indexCsv) $indexCsv
$expectKeys = @('FORWARD_NULL','RESOURCE_LEAK','EMPTY_CATCH_BLOCK','OVERLY_BROAD_CATCH','NULL_RETURN_STD')
$idxText = if (Test-Path -LiteralPath $indexCsv) { Read-TextNoBom $indexCsv } else { '' }
$allKeys = $true
foreach ($k in $expectKeys) { if ($idxText -notmatch [regex]::Escape($k)) { $allKeys = $false } }
Check "A: index.csv has all 5 체커 키" $allKeys

# ============================================================ B. prepare
Write-Host "`n==== B. prepare (Run-Triage.ps1: 체커키->가이드 요청 조립) ===="
$triage = Join-Path $Out 'triage'
& $RunTriage prepare -Index $indexCsv -ItemsDir $itemsDir -GuidesDir $Checkers -Out $triage | Out-Null
$reqDir = Join-Path $triage 'requests'
$reqFiles = @()
if (Test-Path -LiteralPath $reqDir) {
    # 요청은 이제 requests\<체커키>\ 하위에 있고, 각 폴더엔 _작업지침.md 도 있으므로 재귀 + 제외.
    $reqFiles = @(Get-ChildItem -LiteralPath $reqDir -Filter *.md -File -Recurse | Where-Object { $_.Name -ne '_작업지침.md' })
}
Check "B: 5 requests created"    ($reqFiles.Count -eq 5) "found=$($reqFiles.Count)"
# 체커별 _작업지침.md (5개 폴더)
$instrFiles = @()
if (Test-Path -LiteralPath $reqDir) { $instrFiles = @(Get-ChildItem -LiteralPath $reqDir -Filter '_작업지침.md' -File -Recurse) }
Check "B: 5 per-checker _작업지침.md" ($instrFiles.Count -eq 5) "found=$($instrFiles.Count)"
$obcInstr = Join-Path $reqDir 'OVERLY_BROAD_CATCH\_작업지침.md'
Check "B: OVERLY_BROAD_CATCH 작업지침 enforces policy" `
    ((Test-Path -LiteralPath $obcInstr) -and ((Read-TextNoBom $obcInstr) -match '전건') -and ((Read-TextNoBom $obcInstr).Contains('catch(Exception)'))) `
    $obcInstr

# each request must merge its guide (checker-specific CWE marker) + the item's source line
$cweByChecker = @{
    'FORWARD_NULL'       = 'CWE-476'
    'RESOURCE_LEAK'      = 'CWE-772'
    'EMPTY_CATCH_BLOCK'  = 'CWE-390'
    'OVERLY_BROAD_CATCH' = 'CWE-396'
    'NULL_RETURN_STD'    = 'CWE-476'
}
$srcFragByChecker = @{
    'FORWARD_NULL'       = 'node.Value'
    'RESOURCE_LEAK'      = 'new FileStream'
    'EMPTY_CATCH_BLOCK'  = 'catch { }'
    'OVERLY_BROAD_CATCH' = 'catch (Exception ex)'
    'NULL_RETURN_STD'    = 'Activator.CreateInstance'
}
foreach ($rf in $reqFiles) {
    $chk = ($rf.BaseName -split '_', 2)[1]   # {ID}_{체커키}
    $txt = Read-TextNoBom $rf.FullName
    $cwe = $cweByChecker[$chk]
    $frag = $srcFragByChecker[$chk]
    Check ("B: request {0} merges guide ({1}) + source ('{2}')" -f $chk, $cwe, $frag) `
        (($cwe -and $txt.Contains($cwe)) -and ($frag -and $txt.Contains($frag)))
}
$nullStdReq = $reqFiles | Where-Object { $_.BaseName -match '_NULL_RETURN_STD$' } | Select-Object -First 1
$nullStdText = if ($nullStdReq) { Read-TextNoBom $nullStdReq.FullName } else { '' }
Check "B: NULL_RETURN_STD request includes dotnet contract table" `
    (($nullStdText -match '추가 계약표: \.NET null-return API') -and ($nullStdText -match 'Regex\.Match')) `
    $(if ($nullStdReq) { $nullStdReq.FullName } else { 'request missing' })
$unresolved = Join-Path $triage 'unresolved.csv'
$unrLines = @((Read-TextNoBom $unresolved) -split "`n" | Where-Object { $_.Trim().Length -gt 0 })
Check "B: unresolved.csv empty (header only)" ($unrLines.Count -eq 1) "lines=$($unrLines.Count)"

# ============================================================ C. 합성 수정 적용 + 빌드 (G1)
Write-Host "`n==== C. 합성 수정 적용 + 빌드 (G1) ===="
# multi-line fix bodies built by joining with LF (never CRLF) so they match the LF-normalized source.
$fnBefore  = '            return node.Value;'
$fnAfter   = (@('            if (node == null) return -1;','            return node.Value;') -join "`n")

$rlBefore  = (@(
    '            var fs = new FileStream(path, FileMode.Open);',
    '            var buf = new byte[16];',
    '            fs.Read(buf, 0, buf.Length);',
    '            fs.Close();',
    '            return buf;') -join "`n")
$rlAfter   = (@(
    '            var buf = new byte[16];',
    '            using (var fs = new FileStream(path, FileMode.Open))',
    '            {',
    '                fs.Read(buf, 0, buf.Length);',
    '            }',
    '            return buf;') -join "`n")

$ecBefore  = '            catch { }'
$ecAfter   = (@(
    '            catch (Exception ex)',
    '            {',
    '                Console.Error.WriteLine("DoWork failed: " + ex.Message);',
    '                throw;',
    '            }') -join "`n")

$nrBefore  = '            return Activator.CreateInstance(t);'
$nrAfter   = (@('            if (t == null) return null;','            return Activator.CreateInstance(t);') -join "`n")

$repairs = @(
    @{ Checker = 'FORWARD_NULL'; File = 'NullDeref.cs'; Before = $fnBefore; After = $fnAfter },
    @{ Checker = 'RESOURCE_LEAK'; File = 'LeakFile.cs'; Before = $rlBefore; After = $rlAfter },
    @{ Checker = 'EMPTY_CATCH_BLOCK'; File = 'SwallowEx.cs'; Before = $ecBefore; After = $ecAfter },
    @{ Checker = 'NULL_RETURN_STD'; File = 'BclNull.cs'; Before = $nrBefore; After = $nrAfter }
)

$fixedApp = Join-Path $Out 'SampleApp-fixed'
Copy-Item -LiteralPath (Join-Path $ScriptDir 'SampleApp') -Destination $fixedApp -Recurse -Force
# remove any copied build outputs to force a clean build
foreach ($d in @('bin','obj')) { $p = Join-Path $fixedApp $d; if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force } }

$applied = 0
foreach ($r in $repairs) {
    $target = Join-Path $fixedApp ([string]$r.File)
    $before = [string]$r.Before
    $after  = [string]$r.After
    $okTarget = Test-Path -LiteralPath $target
    if (-not $okTarget) { Check ("C: target exists {0}" -f $r.File) $false $target; continue }
    # normalize to LF so multi-line before matches exactly
    $src = [System.IO.File]::ReadAllText($target) -replace "`r`n", "`n"
    $occ = ($src.Length - $src.Replace($before, '').Length)
    $count = if ($before.Length -gt 0) { [math]::Round($occ / $before.Length) } else { 0 }
    Check ("C: '{0}' before found exactly once in {1}" -f $r.Checker, $r.File) ($count -eq 1) "count=$count"
    if ($count -eq 1) {
        $src = $src.Replace($before, $after)
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($target, $src, $utf8)
        $applied++
    }
}
Check "C: 4 fixes applied"         ($applied -eq 4) "applied=$applied"

$csproj = Join-Path $fixedApp 'SampleApp.csproj'
Write-Host "  building fixed SampleApp (dotnet build, LangVersion 7.3) ..."
$buildOut = & dotnet build $csproj -c Debug --nologo 2>&1
$buildExit = $LASTEXITCODE
Check "C: dotnet build SUCCESS (G1)" ($buildExit -eq 0) "exit=$buildExit"
if ($buildExit -ne 0) { $buildOut | ForEach-Object { Write-Host ("      | " + $_) } }

# ============================================================ D. G2 게이트
Write-Host "`n==== D. G2 게이트 (Compare-Sparrow.ps1: 검출 소멸 + 신규 0) ===="
# positive: before vs after, FORWARD_NULL 소멸 + 신규 0 => PASS (exit 0)
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Compare -Before $BeforeXls -After $AfterXls -Checker FORWARD_NULL -Exe $ParserExe | Out-Null
$g2pos = $LASTEXITCODE
Check "D: G2 PASS (before vs after, FORWARD_NULL eliminated) exit 0" ($g2pos -eq 0) "exit=$g2pos"

# negative control: before vs before, FORWARD_NULL still present => FAIL (exit 1)
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Compare -Before $BeforeXls -After $BeforeXls -Checker FORWARD_NULL -Exe $ParserExe | Out-Null
$g2neg = $LASTEXITCODE
Check "D: G2 discriminates (before vs before) exit 1" ($g2neg -eq 1) "exit=$g2neg"

# ============================================================ summary
Write-Host "`n============================================================"
Write-Host ("checks: {0}   fails: {1}" -f $script:Checks, $script:Fails)
if ($script:Fails -eq 0) {
    Write-Host "== E2E PASS =="
    exit 0
} else {
    Write-Host ("== E2E FAIL ({0}) ==" -f $script:Fails)
    exit 1
}
