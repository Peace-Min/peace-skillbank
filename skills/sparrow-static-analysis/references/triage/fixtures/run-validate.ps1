#requires -Version 5.1
<#
    fixtures/run-validate.ps1 — Track C 요청 패키지 자체 검증(합성 픽스처).
    prepare(실제 checkers 가이드에 대해) → 요청/작업지침/멱등성 을 검사한다.
    Compare-Sparrow.ps1 은 실제 Sparrow xls 2개가 필요하므로 기본 스킵(triage-contract.md 6절: 문서화된 한계).
    각 검사 PASS/FAIL 출력, 하나라도 실패면 exit 1.
#>
param([switch]$SkipCompare = $true)

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
Assert ($unknownText -match 'XLS 기반 자동 생성') "UNKNOWN_RULE 요청에 fallback 가이드 병합"
Assert ($unknownText -match 'DoRiskyWork') "UNKNOWN_RULE 요청에 항목 소스 병합"
Assert ($unknownText -match '가이드가 없다는 이유로 false-positive 처리하거나 스킵하지 않는다') "fallback 가이드가 스킵 금지 명시"

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
if ($SkipCompare) {
    Write-Host "  SKIP  Compare-Sparrow — 실제 Sparrow xls 2개 필요 (triage-contract.md 6절 문서화된 한계)"
}

# --- cleanup + 결과
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""
if ($script:fails -eq 0) { Write-Host "== 전체 PASS =="; exit 0 }
else { Write-Host ("== 실패 {0} 건 ==" -f $script:fails); exit 1 }
