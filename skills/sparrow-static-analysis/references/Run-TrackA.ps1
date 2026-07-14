#requires -Version 5.1
<#
    Run-TrackA.ps1 — Sparrow Track A 결정론적 자동수정 (버킷1: var / 명확화 괄호 / 객체 이니셜라이저).
    LLM 없음, 컴파일 툴 없음: SDK 내장 `dotnet format`을 옆의 bucket1-autofix.editorconfig로 구동.
    반입물 = 이 스크립트 + .editorconfig (둘 다 순수 텍스트). 대상 레포의 fix 브랜치에서 실행.

    사용:
      .\Run-TrackA.ps1 -Solution C:\Work\OSTES\OSTES.sln              # 전체(var,괄호,이니셜라이저) 적용
      .\Run-TrackA.ps1 -Solution ...\OSTES.sln -Commit               # 규칙군마다 git 커밋
      .\Run-TrackA.ps1 -Solution ...\OSTES.sln -DryRun               # 변경 안 함, 무엇이 바뀔지만 보고
      .\Run-TrackA.ps1 -Solution ...\OSTES.sln -Rules var,parens     # 일부 규칙군만
#>
param(
    [Parameter(Mandatory = $true)][string]$Solution,
    [string]$EditorConfig,
    [ValidateSet('var', 'parens', 'initializer')][string[]]$Rules = @('var', 'parens', 'initializer'),
    [switch]$Commit,
    [switch]$DryRun,
    [string]$Severity = 'info'
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

# 작업트리 오염 경고(자동수정 diff 격리를 위해)
if (-not $DryRun) {
    $dirty = @(& git -C $slnDir status --porcelain 2>$null)
    if ($dirty.Count -gt 0) {
        Write-Warning "작업트리에 미커밋 변경이 있습니다($($dirty.Count)개). 자동수정 diff와 섞일 수 있으니 깨끗한 상태에서 권장."
    }
}

# 1) .editorconfig 배치(기존 것 있으면 덮지 않음)
if (Test-Path -LiteralPath $targetCfg) {
    Write-Warning "$slnDir 에 이미 .editorconfig 존재 -> 덮어쓰지 않음. 버킷1 규칙이 켜져 있는지 확인하거나 제거 후 재실행."
}
else {
    Copy-Item -LiteralPath $EditorConfig -Destination $targetCfg -Force
    Write-Host "배치: $targetCfg"
}

# 2) 규칙군별 dotnet format
$failed = $false
foreach ($r in $Rules) {
    $g = $groups[$r]
    Write-Host ""
    Write-Host "=== $r  ($($g.ids -join ','))  ==="
    $fmtArgs = @('format', 'style', $slnFull, '--severity', $Severity, '--diagnostics') + $g.ids + @('--verbosity', 'minimal')
    if ($DryRun) { $fmtArgs += '--verify-no-changes' }

    & dotnet @fmtArgs
    $code = $LASTEXITCODE

    if ($DryRun) {
        if ($code -eq 0) { Write-Host "  [dry-run] 변경 없음" } else { Write-Host "  [dry-run] 변경 필요(위 목록)" }
        continue
    }
    if ($code -ne 0) {
        Write-Warning "dotnet format 실패/로드 못함(exit $code). 레거시 .csproj가 SDK로 안 열리면 VS '코드 정리 / Fix All in Solution'으로 (track-a-autofix.md 참조)."
        $failed = $true
        break
    }
    if ($Commit) {
        & git -C $slnDir add -- '*.cs' | Out-Null
        & git -C $slnDir diff --cached --quiet
        if ($LASTEXITCODE -ne 0) {
            & git -C $slnDir commit -q -m "sparrow: $($g.label)"
            Write-Host "  커밋: sparrow: $($g.label)"
        }
        else { Write-Host "  변경 없음 -> 커밋 건너뜀" }
    }
}

Write-Host ""
if ($failed) {
    Write-Host "일부 규칙군 미완 -> VS 경로로 처리 후 아래 검증."
}
Write-Host "다음(필수): (1) 빌드 통과 확인  (2) 스패로우 재분석으로 해당 체커 건수 감소 확인 (Roslyn 경계 != Sparrow 경계)."
Write-Host "참고: .editorconfig는 워킹파일로 남습니다(커밋엔 *.cs만 포함). 병합 전 유지/제거는 직접 결정."
