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
Assert ($unknownText -notmatch '## 진성 판별 기준') "fallback 가이드에 합성 pseudo 섹션 없음"
Assert ($unknownText -match '## 처리 정책 \(이 프로젝트\)') "fallback 요청도 공통 처리 정책 임베드(스킵 금지 근거)"

# --- 미등록 체커 환각 차단 계약(P0) ---
# 요청 md 는 LLM 이 읽는다. GUI 룰 등록은 LLM 이 수행할 수 없는 동작이라 '보류 근거'/가짜 액션아이템으로
# 오독된다 → 요청 md 에서 제거하고 운영자 경로(_작업지침.md + prepare 요약)로만 남긴다.
Assert ($unknownText -notmatch 'Sparrow Helper GUI') "미등록 요청 md 에 GUI 룰 등록 안내 없음(작업자 실행 불가 동작)"
Assert ($unknownText -notmatch '체커 룰 관리') "미등록 요청 md 에 '체커 룰 관리' 경로 안내 없음"
Assert ($unknownText -match '추론해 보충하지 마십시오') "미등록 가이드 = 근거 범위 제한(추론 보충 금지)"
Assert ($unknownText -match '룰 미등록은 처리 유예 사유가 아닙니다') "미등록 가이드 = 유예 불가 명시"
# 근거 필드: 등록은 '요약', 미등록은 '인용'(요약할 룰이 없으므로 빈칸을 가이드 서술로 메우지 못하게).
Assert ($unknownText -match '- 근거\(인용\):') "미등록 요청 = 근거(인용) 필드"
Assert ($unknownText -match '- 근거\(코드\):') "미등록 요청 = 근거(코드) 필드"
Assert ($unknownText -notmatch '(?m)^- 근거: ') "미등록 요청에 요약형 '근거:' 필드 없음"
Assert ($unknownText -match '등록된 룰이 없으므로 "체커 가이드에 따르면" 류 서술을 쓰지 마십시오') "미등록 요청 = 출력 형식 앞 인용 제약 문장"
Assert ($fwdText -match '(?m)^- 근거: <체커 가이드 기준으로 짧게 요약>') "등록 체커 요청 = 요약형 '근거:' 필드 유지"
Assert ($fwdText -notmatch '- 근거\(인용\):') "등록 체커 요청에 인용형 근거 필드 없음"
Assert ($fwdText -notmatch '체커 가이드에 따르면" 류 서술') "등록 체커 요청에 미등록 전용 제약 없음"

# --- 전건 수정 배너 / 상태 enum / 검증 블록 (P0-2, P1-3, P1-4) ---
foreach ($pair in @(@{ N = '등록'; T = $fwdText }, @{ N = '미등록'; T = $unknownText })) {
    $t = $pair.T; $n = $pair.N
    Assert ($t -match '\*\*\[필수\] 스킵·제외·"해당 없음"·"문제 없음" 결론 금지') "$n 요청: [필수] 배너가 앞부분에 노출"
    Assert ($t -match '상태: 수정 완료 \| 패치 제안 \| 문맥 필요 \| 판정 근거 기록\(수정 불요\)') "$n 요청: 상태 enum 4종(판정 근거 기록 포함)"
    Assert ($t -match '## 검증 \(실행은 사용자가 수행 — 결과를 추측해 적지 말 것\)') "$n 요청: 검증 섹션 = 추측 금지 명시"
    Assert ($t -match '- 빌드 영향 범위:') "$n 요청: 검증은 결과칸이 아니라 '빌드 영향 범위'(전망형)"
    Assert ($t -notmatch '(?m)^- 빌드:\s*$') "$n 요청: 빈 '빌드:' 결과칸 없음(허위 '통과' 유도 차단)"
    Assert ($t -notmatch '(?m)^- Sparrow 재분석:\s*$') "$n 요청: 빈 'Sparrow 재분석:' 결과칸 없음"
    Assert ($t -match '판정 근거 기록\(수정 불요\)`은 \(a\) 왜 결함이 아닌지') "$n 요청: 수정 불요 상태의 증거 요건 게이트 존재"
}
# 배너는 '작업 규칙'보다 앞에 있어야 한다(약한 모델이 꼬리 정책을 놓치는 경로 보완).
$bannerIdx = $fwdText.IndexOf('[필수] 스킵·제외')
$rulesIdx = $fwdText.IndexOf('## 작업 규칙')
Assert (($bannerIdx -ge 0) -and ($rulesIdx -gt $bannerIdx)) "배너가 '## 작업 규칙'보다 앞에 위치"

# --- ⚠️ 앵커 블록: 기준점 + 최소 인접 범위 허용 (P1-1) ---
Assert ($unknownText -match '수정 기준점 = 라인 17\.') "항목 md ⚠️ 블록 = '수정 기준점' 문구"
Assert ($unknownText -match '최소 인접 범위\(감싸는 블록·try/finally·선언부\)까지는 수정 가능') "⚠️ 블록이 최소 인접 범위 수정 허용"
Assert ($unknownText -notmatch '그 라인만 고치고') "⚠️ 블록에 '그 라인만 고치고' 단일라인 제약 없음"

# 템플릿 유지보수용 머리말은 어떤 요청에도 새어 나가지 않는다(등록/미등록 공통).
Assert ($unknownText -notmatch '이 파일은') "미등록 요청에 템플릿 유지보수 머리말 없음"
Assert ($unknownText -notmatch '템플릿이다') "미등록 요청에 템플릿 설명 문구 없음"
Assert ($fwdText -notmatch '이 파일은') "등록 체커 요청에 템플릿 유지보수 머리말 없음"
Assert ($fwdText -notmatch '템플릿이다') "등록 체커 요청에 템플릿 설명 문구 없음"
Assert ($fwdText -match '(?m)^# Track C 실제 수정 요청 프롬프트') "머리말 제거 후에도 H1 유지"
Assert ($fwdText -match '(?m)^## 역할') "머리말 제거 후 첫 섹션(## 역할) 보존"

# 상태 결정 배타 규칙 + 비결함 근거 전용 칸(템플릿 밖 임의 항목 방지). red-team 재실증에서
# (1) Before/After를 내고도 '문맥 필요'로 라벨링 (2) 4번째 상태 증빙을 담을 칸이 없어 형식 이탈이 관찰됨.
Assert ($fwdText -match '상태 결정 규칙\(배타\)') "상태 결정 배타 규칙 명시"
Assert ($fwdText -match 'Before/After 또는 patch를 제시했으면') "patch 제시 시 '패치 제안' 라벨 규칙"
Assert ($fwdText -match '비결함 근거\(a 코드 인용\)') "비결함 근거 a 칸 존재"
Assert ($fwdText -match '비결함 근거\(b 잔여 리스크\)') "비결함 근거 b 칸 존재"
Assert ($fwdText -match '비결함 근거\(c 소유 계약 출처\)') "비결함 근거 c 칸 존재"
Assert ($fwdText -match '템플릿 밖에 임의 항목을 만들지') "템플릿 밖 임의 항목 금지 명시"
Assert ($unknownText -match '상태 결정 규칙\(배타\)') "미등록 요청도 배타 규칙 포함"

# 체커별 _작업지침.md
$instrFwd = Join-Path $out 'requests\FORWARD_NULL\_작업지침.md'
$instrLeak = Join-Path $out 'requests\RESOURCE_LEAK\_작업지침.md'
$instrUnknown = Join-Path $out 'requests\UNKNOWN_RULE\_작업지침.md'
Assert (Test-Path -LiteralPath $instrFwd) "작업지침 생성: FORWARD_NULL\_작업지침.md"
Assert (Test-Path -LiteralPath $instrLeak) "작업지침 생성: RESOURCE_LEAK\_작업지침.md"
Assert (Test-Path -LiteralPath $instrUnknown) "작업지침 생성: UNKNOWN_RULE\_작업지침.md"
Assert ((ReadAll $instrFwd) -match '전건') "작업지침에 공통 정책 렌더됨"
# 룰 등록 안내는 제품에서 사라지면 안 된다: 요청 md 밖(운영자용 _작업지침.md)에 fallback 체커만 남긴다.
Assert ((ReadAll $instrUnknown) -match "체커 룰 관리'에서 ``UNKNOWN_RULE`` 룰을 추가") "미등록 체커 작업지침에 GUI 룰 등록 경로 안내 존재"
Assert ((ReadAll $instrFwd) -notmatch '체커 룰 관리') "등록 체커 작업지침에는 룰 등록 안내 없음"

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
