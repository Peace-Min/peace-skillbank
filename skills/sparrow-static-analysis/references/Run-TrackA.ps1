#requires -Version 5.1
<#
    Run-TrackA.ps1 — Sparrow Track A 결정론적 자동수정 (버킷1: var / 명확화 괄호 / 객체 이니셜라이저).
    LLM 없음, 컴파일 툴 없음: SDK 내장 `dotnet format`을 옆의 bucket1-autofix.editorconfig로 구동.
    반입물 = 이 스크립트 + .editorconfig (둘 다 순수 텍스트). 대상 레포의 fix 브랜치에서 실행.

    사용:
      .\Run-TrackA.ps1 -Solution C:\Work\OSTES\OSTES.sln              # 적용. -Commit/-DryRun 없으면 커밋 여부를 물음
      .\Run-TrackA.ps1 -Solution ...\OSTES.sln -Commit               # 규칙군마다 git 커밋(안 물어봄)
      .\Run-TrackA.ps1 -Solution ...\OSTES.sln -DryRun               # 변경 안 함, 무엇이 바뀔지만 보고
      .\Run-TrackA.ps1 -Solution ...\OSTES.sln -Rules var,parens     # 일부 규칙군만
#>
param(
    [Parameter(Mandatory = $true)][string]$Solution,
    [string]$EditorConfig,
    [ValidateSet('var', 'parens', 'initializer')][string[]]$Rules = @('var', 'parens', 'initializer'),
    [switch]$Commit,
    [switch]$DryRun,
    [string]$Severity = 'info',
    [ValidateSet('quiet', 'minimal', 'normal', 'detailed', 'diagnostic')][string]$Verbosity = 'diagnostic',
    [string]$LogDir
)

$ErrorActionPreference = 'Stop'

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
    if ($dirty.Count -gt 0) {
        Write-Warning "작업트리에 미커밋 변경이 있습니다($($dirty.Count)개). 자동수정 diff와 섞일 수 있으니 깨끗한 상태에서 권장."
    }
}

# 1) .editorconfig 배치(기존 것 있으면 덮지 않음)
if (Test-Path -LiteralPath $targetCfg) {
    Write-Warning "$slnDir 에 이미 .editorconfig 존재 -> 덮어쓰지 않음. 이 파일이 버킷1 규칙(IDE0007/0048/0017)을 안 가지면 변경이 0이 됩니다. 내용 확인 후, 우리 규칙으로 돌리려면 그 파일을 백업/제거하고 재실행."
}
else {
    Copy-Item -LiteralPath $EditorConfig -Destination $targetCfg -Force
    Write-Host "배치: $targetCfg"
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
        & git -C $slnDir add -- '*.cs' 2>&1 | Out-Null
        & git -C $slnDir diff --cached --quiet
        if ($LASTEXITCODE -ne 0) {
            & git -C $slnDir commit -q -m "sparrow: $($g.label)"
            Write-Host "  커밋    : sparrow: $($g.label)"
        }
        else { Write-Host "  커밋    : 변경 없음 -> 건너뜀 (이 규칙에서 바뀐 .cs 없음)" }
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
