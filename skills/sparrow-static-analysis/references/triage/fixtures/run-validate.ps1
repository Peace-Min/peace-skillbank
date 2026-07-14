#requires -Version 5.1
<#
    fixtures/run-validate.ps1 — Track C 트리아지 파이프라인 자체 검증(합성 픽스처).
    prepare(실제 checkers 가이드에 대해) → collect → 멱등성 을 검사한다.
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
$verdicts = Join-Path $here 'verdicts'

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
$reqFwd = Join-Path $out 'requests\5001_FORWARD_NULL.md'
$reqLeak = Join-Path $out 'requests\5002_RESOURCE_LEAK.md'
Assert (Test-Path -LiteralPath $reqFwd) "요청 생성: 5001_FORWARD_NULL.md"
Assert (Test-Path -LiteralPath $reqLeak) "요청 생성: 5002_RESOURCE_LEAK.md"

$fwdText = ReadAll $reqFwd
Assert ($fwdText -match 'CWE-476') "요청에 가이드 병합됨 (CWE-476)"
Assert ($fwdText -match 'FirstOrDefault') "요청에 항목 소스 병합됨 (FirstOrDefault)"
Assert (($fwdText -notmatch '\{\{GUIDE\}\}') -and ($fwdText -notmatch '\{\{ITEM\}\}')) "자리표시자 모두 치환됨"

$leakText = ReadAll $reqLeak
Assert ($leakText -match 'CWE-772') "RESOURCE_LEAK 요청에 가이드 병합 (CWE-772)"
Assert ($leakText -match 'SqlConnection') "RESOURCE_LEAK 요청에 항목 소스 병합"

$wlLines = DataLines (ReadAll (Join-Path $out 'worklist.csv'))
Assert (($wlLines | Where-Object { $_ -match ',TODO$' }).Count -eq 2) "worklist TODO 2건"
$unresLines = DataLines (ReadAll (Join-Path $out 'unresolved.csv'))
Assert ($unresLines.Count -eq 1) "unresolved 데이터행 0 (헤더만; 모두 해결)"

# --- 2) collect
Write-Host ""
Write-Host "[collect]"
& $runTriage collect -VerdictsDir $verdicts -Worklist (Join-Path $out 'worklist.csv') -Out $out | Out-Null
$ledger = ReadAll (Join-Path $out 'triage-ledger.csv')
Assert ((DataLines $ledger).Count -eq 3) "원장 = 헤더 + 유효 2행 (진성1/위양성1)"
Assert (($ledger -match 'FORWARD_NULL') -and ($ledger -match '진성')) "원장에 진성 FORWARD_NULL"
Assert (($ledger -match 'RESOURCE_LEAK') -and ($ledger -match '위양성')) "원장에 위양성 RESOURCE_LEAK"

$invalid = ReadAll (Join-Path $out 'invalid.csv')
Assert ((DataLines $invalid).Count -eq 2) "invalid = 헤더 + 무효 1행 (5003-bad)"
Assert ($invalid -match '5003-bad\.json') "무효 목록에 5003-bad.json"
Assert ($invalid -match 'fix') "무효 사유가 fix 관련(진성인데 fix 비어있음)"

$bcFwdPath = Join-Path $out 'by-checker\FORWARD_NULL.md'
Assert (Test-Path -LiteralPath $bcFwdPath) "by-checker/FORWARD_NULL.md 생성"
$bcFwd = ReadAll $bcFwdPath
Assert (($bcFwd -match '## 진성') -and ($bcFwd -match '5001')) "by-checker에 진성 5001 커밋후보 목록"
$bcLeak = ReadAll (Join-Path $out 'by-checker\RESOURCE_LEAK.md')
Assert (($bcLeak -match '## 위양성') -and ($bcLeak -match '5002')) "by-checker에 위양성 5002 목록"

# --- 3) 멱등성
Write-Host ""
Write-Host "[idempotency]"
$reqBefore = $fwdText
$ledgerBefore = $ledger
$invalidBefore = $invalid
$bcBefore = $bcFwd
& $runTriage prepare -Index $index -ItemsDir $items -GuidesDir $guidesDir -Out $out -PromptPath $promptPath | Out-Null
& $runTriage collect -VerdictsDir $verdicts -Worklist (Join-Path $out 'worklist.csv') -Out $out | Out-Null
Assert ((ReadAll $reqFwd) -eq $reqBefore) "멱등: 요청 파일 재실행 동일"
Assert ((ReadAll (Join-Path $out 'triage-ledger.csv')) -eq $ledgerBefore) "멱등: 원장 재실행 동일"
Assert ((ReadAll (Join-Path $out 'invalid.csv')) -eq $invalidBefore) "멱등: invalid 재실행 동일"
Assert ((ReadAll $bcFwdPath) -eq $bcBefore) "멱등: by-checker 재실행 동일"

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
