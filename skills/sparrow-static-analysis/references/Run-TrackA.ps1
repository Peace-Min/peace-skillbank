#requires -Version 5.1
<#
    Run-TrackA.ps1 — Sparrow Track A 결정론적 자동수정 (버킷1: var / 명확화 괄호 / 객체 이니셜라이저).
    LLM 없음, 컴파일 툴 없음: SDK 내장 `dotnet format`을 옆의 bucket1-autofix.editorconfig로 구동.
    반입물 = 이 스크립트 + .editorconfig (둘 다 순수 텍스트). 대상 레포의 fix 브랜치에서 실행.

    사용:
      .\Run-TrackA.ps1                                                # 경로 입력 후 적용. -Commit/-DryRun 없으면 커밋 여부를 물음
      .\Run-TrackA.ps1 -Solution C:\Work\OSTES\OSTES.sln              # 경로를 미리 줘도 됨
      .\Run-TrackA.ps1 -Solution ...\OSTES.sln -Commit               # 규칙군마다 git 커밋(안 물어봄)
      .\Run-TrackA.ps1 -Solution ...\OSTES.sln -DryRun               # 변경 안 함, 무엇이 바뀔지만 보고
      .\Run-TrackA.ps1 -Solution ...\OSTES.sln -Rules var,parens     # 일부 규칙군만
#>
param(
    [string]$Solution,
    [string]$EditorConfig,
    [string[]]$Rules = @('var', 'parens', 'initializer'),
    [switch]$Commit,
    [switch]$DryRun,
    [string]$Severity = 'info',
    [ValidateSet('quiet', 'minimal', 'normal', 'detailed', 'diagnostic')][string]$Verbosity = 'diagnostic',
    [string]$LogDir,
    [switch]$KeepEditorConfig
)

trap {
    $message = if ($_.Exception) { $_.Exception.Message } else { ($_ | Out-String).Trim() }
    Write-Host ""
    Write-Host "[FATAL] Run-TrackA 중단: $message" -ForegroundColor Red
    $lp = Get-Variable -Name logPath -Scope 0 -ErrorAction SilentlyContinue
    if ($lp -and $lp.Value) { Write-Host "로그: $($lp.Value)" }
    $inputRedirected = $false
    try { $inputRedirected = [Console]::IsInputRedirected } catch { $inputRedirected = $false }
    if ([Environment]::UserInteractive -and -not $inputRedirected) {
        [void](Read-Host "오류로 중단되었습니다. 내용을 확인한 뒤 Enter를 누르면 닫습니다")
    }
    exit 1
}

$ErrorActionPreference = 'Stop'

if (-not $Solution) {
    $Solution = Read-Host "정리할 솔루션(.sln) 파일 또는 프로젝트/소스 폴더 경로를 입력하세요"
}
if ($Solution) { $Solution = $Solution.Trim().Trim('"').Trim("'").Trim() }
if (-not $Solution) { throw "경로가 비었습니다. 솔루션(.sln) 또는 프로젝트/소스 폴더 경로가 필요합니다." }

# $PSScriptRoot is empty inside a param default under some invocations -> resolve script dir in the body.
if (-not $EditorConfig) {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $EditorConfig = Join-Path $scriptDir "bucket1-autofix.editorconfig"
}

# 규칙군 -> 진단 ID + 커밋 라벨  (Sparrow 체커 대응은 bucket1-autofix.editorconfig 주석 참조)
$groups = [ordered]@{
    var         = @{ ids = @('IDE0007', 'IDE0008'); label = 'var 일괄(IDE0007/0008)' }
    parens      = @{ ids = @('IDE0048');            label = '괄호 명확화(IDE0048)' }
    initializer = @{ ids = @('IDE0017');            label = '객체 이니셜라이저(IDE0017)' }
}
$Rules = @($Rules | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$invalidRules = @($Rules | Where-Object { -not $groups.Contains($_) })
if ($invalidRules.Count -gt 0) {
    throw "지원하지 않는 규칙: $($invalidRules -join ', ') / 허용: $($groups.Keys -join ', ')"
}

# 0) preflight
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { throw "dotnet SDK를 PATH에서 찾을 수 없습니다." }
if (-not (Test-Path -LiteralPath $Solution)) { throw "솔루션/프로젝트 없음: $Solution" }
if (-not (Test-Path -LiteralPath $EditorConfig)) { throw ".editorconfig 템플릿 없음: $EditorConfig" }

$slnFull = (Resolve-Path -LiteralPath $Solution).Path
$slnDir = Split-Path -Parent $slnFull
$targetCfg = Join-Path $slnDir ".editorconfig"

# 실행 로그: CLI 실행 지점(현재 폴더)에 기본 저장, -LogDir로 변경 가능. 콘솔=요약, 로그=전체 진단.
if (-not $LogDir) { $LogDir = (Get-Location).Path }
$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$logPath = Join-Path $LogDir ("Run-TrackA.$stamp.log")
"Run-TrackA | solution=$slnFull | rules=$($Rules -join ',') | dryrun=$([bool]$DryRun) | commit=$([bool]$Commit) | time=$stamp" | Out-File -LiteralPath $logPath -Encoding utf8
Write-Host "실행 로그(전체 진단): $logPath"

# 작업트리 오염 경고(자동수정 diff 격리를 위해)
if (-not $DryRun) {
    $dirty = @(& git -C $slnDir status --porcelain 2>$null)
    $gitCode = $LASTEXITCODE
    if ($gitCode -eq 0) {
        # 커밋마다 git 자동 gc(재패킹)가 .git pack의 .idx를 unlink하려다 백신/인덱서와 충돌해
        # "Unlink of file ...pack-*.idx failed. Should I try again?" 가 나는 것을 원천 차단(대상 repo 로컬, 1회).
        & git -C $slnDir config gc.auto 0 2>&1 | Out-Null
        & git -C $slnDir config gc.autoDetach false 2>&1 | Out-Null
        & git -C $slnDir config core.fscache true 2>&1 | Out-Null
        if ($dirty.Count -gt 0) {
            Write-Warning "작업트리에 미커밋 변경이 있습니다($($dirty.Count)개). 자동수정 diff와 섞일 수 있으니 깨끗한 상태에서 권장."
        }
    }
}

# git 커밋 하드닝: add/commit을 일시 락(.idx unlink 실패·index.lock 등)에 자동 재시도로 감쌈.
# 반환: 'committed' | 'nochange' | 'failed'. 실패해도 러너는 계속 진행.
function Invoke-GitCommitStep {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Message)
    & git -C $Root add -- '*.cs' 2>&1 | Out-Null
    & git -C $Root diff --cached --quiet
    if ($LASTEXITCODE -eq 0) { return 'nochange' }
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        & git -C $Root commit -q -m $Message 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { return 'committed' }
        & git -C $Root diff --cached --quiet
        if ($LASTEXITCODE -eq 0) { return 'committed' }
        Start-Sleep -Milliseconds (400 * $attempt)
        $lock = Join-Path $Root '.git\index.lock'
        if (Test-Path -LiteralPath $lock) { Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue }
    }
    return 'failed'
}

# 1) .editorconfig 배치 — 기존 것이 있으면 백업 후 *최신 bucket1로 덮어씀*(버전 꼬임/충돌 방지가 기본).
#    -KeepEditorConfig 를 주면 기존 것을 유지(우리 규칙을 이미 공유 config에 병합해 둔 경우).
if ($KeepEditorConfig -and (Test-Path -LiteralPath $targetCfg)) {
    Write-Warning "$targetCfg 유지(-KeepEditorConfig). 이 파일에 버킷1 규칙(IDE0007/0048/0017)이 있어야 변경이 발생합니다."
}
else {
    if (Test-Path -LiteralPath $targetCfg) {
        $bak = "$targetCfg.pre-tracka-$stamp.bak"
        Copy-Item -LiteralPath $targetCfg -Destination $bak -Force
        Write-Warning "기존 .editorconfig 를 백업: $bak  ->  최신 bucket1로 덮어씀. (원래가 OSTES 자체 설정이면 병합/복원 필요; 유지하려면 -KeepEditorConfig)"
    }
    Copy-Item -LiteralPath $EditorConfig -Destination $targetCfg -Force
    Write-Host "배치(최신 bucket1): $targetCfg"
}

# 1b) -Commit/-DryRun 둘 다 없으면 물어봄(플래그 빼먹는 실수 방지). 비대화형(CI/파이프)은 안 물어보고 커밋 안 함.
if (-not $Commit -and -not $DryRun) {
    if ([Environment]::UserInteractive) {
        $ans = Read-Host "규칙별로 커밋할까요? (Y=규칙별 자동 커밋 / N=파일만 수정, 커밋 안 함)"
        if ($ans -match '^\s*(y|yes|예|ㅛ)\s*$') { $Commit = $true; Write-Host "-> 규칙별 커밋 진행" }
        else { Write-Host "-> 파일만 수정(커밋 안 함). 나중에 직접 커밋하거나 -Commit으로 재실행." }
    }
    else {
        Write-Host "(비대화형: -Commit 미지정 -> 커밋 안 함)"
    }
}

# 2) 규칙군별 dotnet format — 전체 출력은 로그로, 콘솔엔 요약만
# native 명령(dotnet/git)의 stderr가 EAP=Stop에서 ErrorRecord로 감싸져 throw되는 것을 막기 위해
# 이 구간은 Continue. (autocrlf=true면 git add가 CRLF 경고를 stderr에 씀 -> Stop이면 커밋 전에 죽음)
$ErrorActionPreference = 'Continue'
$failed = $false
foreach ($r in $Rules) {
    $g = $groups[$r]
    $fmtArgs = @('format', 'style', $slnFull, '--severity', $Severity, '--diagnostics') + $g.ids + @('--verbosity', $Verbosity)
    if ($DryRun) { $fmtArgs += '--verify-no-changes' }

    $out = & dotnet @fmtArgs 2>&1
    $code = $LASTEXITCODE
    $text = ($out | Out-String)

    # 전체 출력 -> 로그
    Add-Content -LiteralPath $logPath -Value ("`n========== $r ($($g.ids -join ',')) | exit=$code ==========")
    Add-Content -LiteralPath $logPath -Value $text

    # 요약 추출 (ko '개 중 N개 ...지정했습니다' / en 'Formatted N of M')
    $sumMatch = $out | Select-String -Pattern '개 중 .*지정했습니다|Formatted \d+ of \d+' | Select-Object -Last 1
    $summary = if ($sumMatch) { $sumMatch.Line.Trim() } else { '(요약 줄 없음 - 로그 확인. 변경 0 또는 로드 실패 가능)' }
    $loadWarn = if ($text -match '경고가 발생했습니다|warnings? while loading|작업 영역을 로드') { '있음 (상세=로그)' } else { '없음' }

    Write-Host ""
    Write-Host "=== $r  ($($g.ids -join ','))  | exit=$code ==="
    Write-Host "  요약    : $summary"
    Write-Host "  로드경고: $loadWarn"

    if ($DryRun) { Write-Host "  결과    : [dry-run] 파일 변경 안 함"; continue }
    if ($code -ne 0) {
        Write-Warning "  dotnet format 실패(exit $code) - 로그 확인. 레거시 로드 실패면 VS '코드 정리/Fix All in Solution'으로."
        $failed = $true
        break
    }
    if ($Commit) {
        $res = Invoke-GitCommitStep -Root $slnDir -Message "sparrow: $($g.label)"
        switch ($res) {
            'committed' { Write-Host "  커밋    : sparrow: $($g.label)" }
            'nochange'  { Write-Host "  커밋    : 변경 없음 -> 건너뜀 (이 규칙에서 바뀐 .cs 없음)" }
            'failed'    { Write-Warning "  커밋 실패(git 락 5회 재시도 후에도) - 파일 수정은 유지됨. 나중에 수동 커밋 가능." }
        }
    }
    else { Write-Host "  커밋    : -Commit 미지정 -> 커밋 안 함 (파일만 수정됨; 커밋하려면 -Commit)" }
}

Write-Host ""
if ($failed) {
    Write-Host "일부 규칙군 미완 -> VS 경로로 처리 후 아래 검증."
}
Write-Host "전체 진단 로그: $logPath   (커밋 안 되거나 이상하면 이 파일을 확인/공유)"
Write-Host "다음(필수): (1) 빌드 통과 확인  (2) 스패로우 재분석으로 해당 체커 건수 감소 확인 (Roslyn 경계 != Sparrow 경계)."
Write-Host "참고: .editorconfig는 워킹파일로 남습니다(커밋엔 *.cs만 포함). 병합 전 유지/제거는 직접 결정."
