#requires -Version 5.1
<#
    원큐 러너 — Track A(SparrowSyntaxFix, Roslyn) + Track B(SparrowCommentFix)를 한 번의 명령으로 순차 실행.

    두 서브러너는 각각 git 하드닝(대상 repo에 gc.auto 0 자동 설정 + 커밋 락 재시도)을 이미 내장하므로,
    기본 옵션으로 그냥 돌려도 Windows "Unlink of file ...pack-*.idx failed" 에러에 멈추지 않는다.

    기본 규칙셋은 이 스킬이 결정론으로 처리 가능한 Track A/B 전 규칙(신규 opt-in forvar/fieldsplit/emptystmt/
    forhoist/blockpromote 포함)이다. 검토필요(review-needed) 규칙은 커밋 메시지에 '!' 로 표시된다.
    (참고: SparrowSyntaxFix 기반 Run-SparrowSyntaxFix 는 OSTES x64에서 무력이라 원큐에는 포함하지 않고 Roslyn 러너를 쓴다.)

    사용:
      .\Run-SparrowAll.ps1 -Solution ...\OSTES.sln -Commit     # A→B 전 규칙, 규칙별 자동 커밋
      .\Run-SparrowAll.ps1 -Solution ...\OSTES.sln -NoCommit   # A→B 전 규칙, 파일만 수정
      .\Run-SparrowAll.ps1 -Solution ...\src -DryRun            # 변경 미리보기(파일 안 건드림)
      .\Run-SparrowAll.ps1 -Solution ...\src                    # 적용만(커밋 여부는 각 러너가 물음)
      # 규칙 좁히기:
      .\Run-SparrowAll.ps1 -Solution ... -SyntaxRules forhoist,forvar -CommentRules blockpromote -Commit
#>
param(
    [string]$Solution,
    [switch]$Commit,
    [switch]$NoCommit,
    [switch]$DryRun,
    # Track A(SparrowSyntaxFix) 규칙 — 안전 기본(obviousvar/objectvar-safe/parens/foreachcast) + opt-in(forvar/fieldsplit/emptystmt/forhoist)
    [string]$SyntaxRules = 'obviousvar,objectvar-safe,parens,foreachcast,forvar,fieldsplit,emptystmt,forhoist',
    # Track B(SparrowCommentFix) 규칙 — 전 규칙(continuation 깊이정규화·blockpromote opt-in 포함)
    [string]$CommentRules = 'flatten,trailing,space,period,capitalize,memberblank,onestatement,onedeclaration,continuation,linqalign,blockpromote'
)

trap {
    $message = if ($_.Exception) { $_.Exception.Message } else { ($_ | Out-String).Trim() }
    Write-Host ""
    Write-Host "[FATAL] Run-SparrowAll 중단: $message" -ForegroundColor Red
    $inputRedirected = $false
    try { $inputRedirected = [Console]::IsInputRedirected } catch { $inputRedirected = $false }
    if ([Environment]::UserInteractive -and -not $inputRedirected) {
        [void](Read-Host "오류로 중단되었습니다. 내용을 확인한 뒤 Enter를 누르면 닫습니다")
    }
    exit 1
}

try {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [Console]::InputEncoding = $utf8NoBom
    [Console]::OutputEncoding = $utf8NoBom
    $OutputEncoding = $utf8NoBom
}
catch {
    # 콘솔 인코딩 설정 실패는 러너 본동작을 막지 않는다.
}

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$syntaxRunner  = Join-Path $here 'SparrowSyntaxFix\Run-SparrowSyntaxFix.ps1'
$commentRunner = Join-Path $here 'SparrowCommentFix\Run-SparrowCommentFix.ps1'
foreach ($p in @($syntaxRunner, $commentRunner)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "서브러너를 찾을 수 없습니다: $p" }
}

# -Commit / -DryRun 만 서브러너로 전달(둘 다 없으면 각 러너가 커밋 여부를 물음).
$pass = @{}
if ($Commit) { $pass['Commit'] = $true }
if ($NoCommit) { $pass['NoCommit'] = $true }
if ($DryRun) { $pass['DryRun'] = $true }

$syntaxList  = @($SyntaxRules  -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$commentList = @($CommentRules -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

Write-Host "==================== 원큐: TRACK A (SparrowSyntaxFix) ===================="
Write-Host "  규칙: $($syntaxList -join ',')"
& $syntaxRunner -Solution $Solution -Rules $syntaxList @pass

Write-Host ""
Write-Host "==================== 원큐: TRACK B (SparrowCommentFix) ===================="
Write-Host "  규칙: $($commentList -join ',')"
& $commentRunner -Solution $Solution -Rules $commentList @pass

Write-Host ""
Write-Host "원큐 완료 (A→B). 다음(필수): (1) 빌드 통과 확인  (2) Sparrow 재분석으로 검출 감소 실측."
Write-Host "참고: Track C(로직) 작업 후에는 이 원큐를 한 번 더 돌려 C가 새로 만든 형식 검출을 정리하세요."
