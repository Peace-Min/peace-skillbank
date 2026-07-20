#requires -Version 5.1
<#
    fixtures/run-validate.ps1 — Track C 요청 패키지 자체 검증(합성 픽스처).
    prepare(실제 checkers 가이드에 대해) → 요청/작업지침/멱등성 을 검사한다.
    Compare-Sparrow.ps1 은 gen-xls --scenarios 합성 xls 로 G2 게이트 의미론(라인시프트 무오탐/진짜회귀 FAIL/
    스캔위생 경고·-StrictScope)을 검사한다. dotnet SDK 없으면 해당 구간만 SKIP(-SkipCompare 로 강제 스킵).
    각 검사 PASS/FAIL 출력, 하나라도 실패면 exit 1.
#>
param([switch]$SkipCompare)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$triageDir = Split-Path -Parent $here
$runTriage = Join-Path $triageDir 'Run-Triage.ps1'
$promptPath = Join-Path $triageDir 'triage-prompt.md'
$guidesDir = Join-Path (Split-Path -Parent $triageDir) 'checkers'
$index = Join-Path $here 'index.csv'
$items = Join-Path $here 'items'

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('triage-validate-' + [System.IO.Path]::GetRandomFileName())
$out = Join-Path $work 'triage'

$script:fails = 0
function Assert($cond, $msg) {
    if ($cond) { Write-Host "  PASS  $msg" } else { Write-Host "  FAIL  $msg"; $script:fails++ }
}
function ReadAll($p) { if (Test-Path -LiteralPath $p) { [System.IO.File]::ReadAllText($p) } else { '' } }
function DataLines($text) { @($text -split "`n" | Where-Object { $_.Trim().Length -gt 0 }) }

Write-Host "== Track C 트리아지 픽스처 검증 =="
Write-Host "work: $work"
Write-Host ""

# --- preflight
Write-Host "[preflight]"
Assert (Test-Path -LiteralPath $runTriage) "Run-Triage.ps1 존재"
Assert (Test-Path -LiteralPath $guidesDir) "실제 checkers 가이드 폴더 존재: $guidesDir"
Assert (Test-Path -LiteralPath (Join-Path $guidesDir 'FORWARD_NULL.md')) "FORWARD_NULL.md 가이드 존재"
Assert (Test-Path -LiteralPath (Join-Path $guidesDir 'RESOURCE_LEAK.md')) "RESOURCE_LEAK.md 가이드 존재"
Assert (Test-Path -LiteralPath $index) "fixtures/index.csv 존재"

# --- 1) prepare
Write-Host ""
Write-Host "[prepare]"
& $runTriage prepare -Index $index -ItemsDir $items -GuidesDir $guidesDir -Out $out -PromptPath $promptPath | Out-Null
$reqFwd = Join-Path $out 'requests\FORWARD_NULL\5001_FORWARD_NULL.md'
$reqLeak = Join-Path $out 'requests\RESOURCE_LEAK\5002_RESOURCE_LEAK.md'
$reqUnknown = Join-Path $out 'requests\UNKNOWN_RULE\5003_UNKNOWN_RULE.md'
Assert (Test-Path -LiteralPath $reqFwd) "요청 생성: FORWARD_NULL\5001_FORWARD_NULL.md"
Assert (Test-Path -LiteralPath $reqLeak) "요청 생성: RESOURCE_LEAK\5002_RESOURCE_LEAK.md"
Assert (Test-Path -LiteralPath $reqUnknown) "fallback 요청 생성: UNKNOWN_RULE\5003_UNKNOWN_RULE.md"

$fwdText = ReadAll $reqFwd
Assert ($fwdText -match 'CWE-476') "요청에 가이드 병합됨 (CWE-476)"
Assert ($fwdText -match 'FirstOrDefault') "요청에 항목 소스 병합됨 (FirstOrDefault)"
Assert (($fwdText -notmatch '\{\{GUIDE\}\}') -and ($fwdText -notmatch '\{\{ITEM\}\}')) "자리표시자 모두 치환됨"
Assert ($fwdText -match '## 처리 정책 \(이 프로젝트\)') "요청에 공통 처리 정책(Policy A) 임베드됨"
Assert ($fwdText -match '전건') "임베드 정책에 '전건 수정' 정책 포함"

$leakText = ReadAll $reqLeak
Assert ($leakText -match 'CWE-772') "RESOURCE_LEAK 요청에 가이드 병합 (CWE-772)"
Assert ($leakText -match 'SqlConnection') "RESOURCE_LEAK 요청에 항목 소스 병합"

$unknownText = ReadAll $reqUnknown
Assert ($unknownText -match '가이드 상태\*\*: 미등록') "UNKNOWN_RULE 요청에 fallback 가이드 병합(미등록 표시)"
Assert ($unknownText -match 'DoRiskyWork') "UNKNOWN_RULE 요청에 항목 소스 병합"
# fallback 은 합성 의사 가이드가 아니라 최소 안내 2줄. 스킵 금지/전건 수정은 '처리 정책' 섹션이 담당한다.
Assert ($unknownText -match '등록된 룰이 없습니다') "fallback 가이드 = 미등록 안내 1줄"
Assert ($unknownText -match '체커 룰 관리') "fallback 가이드 = 룰 등록 경로 안내 1줄"
Assert ($unknownText -notmatch '## 진성 판별 기준') "fallback 가이드에 합성 pseudo 섹션 없음"
Assert ($unknownText -match '## 처리 정책 \(이 프로젝트\)') "fallback 요청도 공통 처리 정책 임베드(스킵 금지 근거)"

# 템플릿 유지보수용 머리말은 어떤 요청에도 새어 나가지 않는다(등록/미등록 공통).
Assert ($unknownText -notmatch '이 파일은') "미등록 요청에 템플릿 유지보수 머리말 없음"
Assert ($unknownText -notmatch '템플릿이다') "미등록 요청에 템플릿 설명 문구 없음"
Assert ($fwdText -notmatch '이 파일은') "등록 체커 요청에 템플릿 유지보수 머리말 없음"
Assert ($fwdText -notmatch '템플릿이다') "등록 체커 요청에 템플릿 설명 문구 없음"
Assert ($fwdText -match '(?m)^# Track C 실제 수정 요청 프롬프트') "머리말 제거 후에도 H1 유지"
Assert ($fwdText -match '(?m)^## 역할') "머리말 제거 후 첫 섹션(## 역할) 보존"

# 체커별 _작업지침.md
$instrFwd = Join-Path $out 'requests\FORWARD_NULL\_작업지침.md'
$instrLeak = Join-Path $out 'requests\RESOURCE_LEAK\_작업지침.md'
$instrUnknown = Join-Path $out 'requests\UNKNOWN_RULE\_작업지침.md'
Assert (Test-Path -LiteralPath $instrFwd) "작업지침 생성: FORWARD_NULL\_작업지침.md"
Assert (Test-Path -LiteralPath $instrLeak) "작업지침 생성: RESOURCE_LEAK\_작업지침.md"
Assert (Test-Path -LiteralPath $instrUnknown) "작업지침 생성: UNKNOWN_RULE\_작업지침.md"
Assert ((ReadAll $instrFwd) -match '전건') "작업지침에 공통 정책 렌더됨"

$wlLines = DataLines (ReadAll (Join-Path $out 'worklist.csv'))
Assert (($wlLines | Where-Object { $_ -match ',TODO$' }).Count -eq 3) "worklist TODO 3건"
$unresLines = DataLines (ReadAll (Join-Path $out 'unresolved.csv'))
Assert ($unresLines.Count -eq 2) "unresolved 데이터행 1건 (item md 누락)"
$unresolvedDir = Join-Path $out 'requests\_UNRESOLVED'
$unresolvedGuide = Join-Path $unresolvedDir '_작업지침.md'
$unresolvedReq = Join-Path $unresolvedDir '00001_5004_MISSING_ITEM.md'
Assert (Test-Path -LiteralPath $unresolvedGuide) "미해결 작업지침 생성: _UNRESOLVED\_작업지침.md"
Assert (Test-Path -LiteralPath $unresolvedReq) "미해결 요청 생성: _UNRESOLVED\00001_5004_MISSING_ITEM.md"
Assert ((ReadAll $unresolvedReq) -match '항목 md 없음') "미해결 요청에 사유 포함"

# --- 2) 멱등성
Write-Host ""
Write-Host "[idempotency]"
$reqBefore = $fwdText
$worklistBefore = ReadAll (Join-Path $out 'worklist.csv')
$unresolvedBefore = ReadAll (Join-Path $out 'unresolved.csv')
$instrBefore = ReadAll $instrFwd
& $runTriage prepare -Index $index -ItemsDir $items -GuidesDir $guidesDir -Out $out -PromptPath $promptPath | Out-Null
Assert ((ReadAll $reqFwd) -eq $reqBefore) "멱등: 요청 파일 재실행 동일"
Assert ((ReadAll (Join-Path $out 'worklist.csv')) -eq $worklistBefore) "멱등: worklist 재실행 동일"
Assert ((ReadAll (Join-Path $out 'unresolved.csv')) -eq $unresolvedBefore) "멱등: unresolved 재실행 동일"
Assert ((ReadAll $instrFwd) -eq $instrBefore) "멱등: 작업지침 재실행 동일"

# --- Compare-Sparrow (실제 xls 필요)
Write-Host ""
Write-Host "[compare-sparrow]"
# G2 게이트 시나리오 검증: gen-xls --scenarios 로 합성 xls 3쌍을 만들어 count-based/full-path/스캔위생
# 의미론을 검사한다. dotnet SDK 가 필요하므로 없으면 SKIP(기존 문서화된 한계 유지). -SkipCompare 로 강제 스킵.
$dotnetCmd = Get-Command dotnet -ErrorAction SilentlyContinue
if ($SkipCompare -or -not $dotnetCmd) {
    Write-Host "  SKIP  Compare-Sparrow 시나리오 — dotnet SDK 필요(-SkipCompare 또는 SDK 없음)"
}
else {
    $compare = Join-Path $triageDir 'Compare-Sparrow.ps1'
    $genProj = Join-Path $triageDir 'e2e-lab\gen-xls\gen-xls.csproj'
    $parserProj = Join-Path (Split-Path -Parent (Split-Path -Parent $triageDir)) 'tools\_internal\SparrowXlsExport\SparrowXlsExport.csproj'
    $parserExe = Join-Path (Split-Path -Parent (Split-Path -Parent $triageDir)) 'tools\_internal\SparrowXlsExport\bin\Release\net8.0\SparrowXlsExport.exe'
    Assert (Test-Path -LiteralPath $compare) "Compare-Sparrow.ps1 존재"
    Assert (Test-Path -LiteralPath $genProj) "gen-xls.csproj 존재"

    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        # 파서는 항상 소스에서 재빌드한 bin exe 사용(오래된 publish exe가 경로 컬럼을 모를 수 있음).
        & $dotnetCmd.Source build $parserProj -c Release --nologo -v q 2>&1 | Out-Null
        $scenDir = Join-Path $work 'g2-scenarios'
        & $dotnetCmd.Source run -c Release --project $genProj -- $scenDir --scenarios 2>&1 | Out-Null
        Assert ($LASTEXITCODE -eq 0) "gen-xls --scenarios exit 0"
        Assert (Test-Path -LiteralPath (Join-Path $scenDir 'lineshift-before.xls')) "시나리오 xls 생성됨"

        function Invoke-Compare([string[]]$CmpArgs) {
            $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $compare @CmpArgs -Exe $parserExe 2>&1 | Out-String
            return [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $o }
        }

        # 1) 라인 시프트: 해소 1건 + 라인만 밀린 1건 → 가짜 신규 없이 PASS.
        $r1 = Invoke-Compare @('-Before', (Join-Path $scenDir 'lineshift-before.xls'), '-After', (Join-Path $scenDir 'lineshift-after.xls'))
        Assert ($r1.Exit -eq 0) "G2 라인시프트: PASS(exit 0) — 라인 이동은 신규 아님"
        Assert ($r1.Out -match '결과: PASS') "G2 라인시프트: '결과: PASS' 출력"

        # 2) 진짜 회귀: (체커,전체경로) 건수 증가 → FAIL + 증가쌍(전체경로) 나열.
        $r2 = Invoke-Compare @('-Before', (Join-Path $scenDir 'regress-before.xls'), '-After', (Join-Path $scenDir 'regress-after.xls'))
        Assert ($r2.Exit -eq 1) "G2 진짜회귀: FAIL(exit 1)"
        Assert ($r2.Out -match 'src/App/Fresh\.cs') "G2 진짜회귀: 증가쌍이 전체경로로 나열됨"

        # 3) 스캔 스코프 불일치: 기본은 경고+판정미변경(PASS), -StrictScope 는 FAIL.
        $r3 = Invoke-Compare @('-Before', (Join-Path $scenDir 'scope-before.xls'), '-After', (Join-Path $scenDir 'scope-after.xls'))
        Assert ($r3.Exit -eq 0) "G2 스코프불일치: 기본 PASS(경고만)"
        # 한글 match 는 중첩 powershell 캡처의 콘솔 코드페이지에 따라 깨질 수 있어 ASCII 배너(####…)도 인정.
        Assert (($r3.Out -match '스캔 위생 경고') -or ($r3.Out -match '#{40,}')) "G2 스코프불일치: 위생 경고 출력"
        $r4 = Invoke-Compare @('-Before', (Join-Path $scenDir 'scope-before.xls'), '-After', (Join-Path $scenDir 'scope-after.xls'), '-StrictScope')
        Assert ($r4.Exit -eq 1) "G2 스코프불일치: -StrictScope 는 FAIL(exit 1)"
    }
    finally { $ErrorActionPreference = $prevEap }
}

# --- cleanup + 결과
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""
if ($script:fails -eq 0) { Write-Host "== 전체 PASS =="; exit 0 }
else { Write-Host ("== 실패 {0} 건 ==" -f $script:fails); exit 1 }
