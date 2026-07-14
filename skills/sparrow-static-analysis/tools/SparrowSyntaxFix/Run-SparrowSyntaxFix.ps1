#requires -Version 5.1
<#
    Run-SparrowSyntaxFix.ps1 — Track A 2단계 원콜 러너.
    dotnet format(Run-TrackA.ps1)이 못 하거나 일부 누락한 Track A 체커를 자작 Roslyn 툴 SparrowSyntaxFix로 결정론 처리:
      - nullvar              : `<타입> x = null;` / `<타입> x;` -> `var x = (<타입>)null;`
      - parens               : `a && b` 등의 비교/산술 피연산자 괄호
      - objectvar-safe       : `Foo x = new Foo()` -> `var x = new Foo()`
      - foreachcast          : `foreach (T x in xs)` -> `foreach (var x in Enumerable.Cast<T>(xs))`
      - obviousvar           : literal/Convert/cast initializer -> var
      - objectvar-narrowing  : 인터페이스/기반타입 var 변환(커밋명 review-needed)
      - localconst           : 지역 const -> var(커밋명 review-needed)
      - objectinitializer    : 생성 직후 연속 property 대입 -> object initializer + var
      - arrayvar-safe        : T[] a = new T[] { ... } -> T[] a = { ... }
      - arrayvar-narrowing   : 배열 정적 타입 축소 var 변환(커밋명 review-needed)
    Run-TrackA.ps1과 동일 UX: 솔루션 경로만 주면 동작(내부에서 exe 확보 -> 규칙별 실행 -> 규칙별 커밋).

    사용(원큐): 그냥 실행 -> 솔루션 경로 -> 검토필요 규칙 포함 여부(Y/N) -> 커밋 여부(Y/N)를 물어봄.
      .\Run-SparrowSyntaxFix.ps1                                                # ← 이게 원큐. 경로/검토필요 규칙/커밋 Y/N
      .\Run-SparrowSyntaxFix.ps1 -Solution C:\Work\OSTES\OSTES.sln              # 경로를 미리 줘도 됨(커밋 여부는 물음)
      .\Run-SparrowSyntaxFix.ps1 -Solution ...\OSTES.sln -Commit                # 안 물어보고 규칙별 자동 커밋
      .\Run-SparrowSyntaxFix.ps1 -Solution ...\OSTES.sln -DryRun                # 변경 안 함, 무엇이 바뀔지만 보고
      .\Run-SparrowSyntaxFix.ps1 -Solution ...\OSTES.sln -Rules objectvar-safe,foreachcast # 일부 규칙만
      .\Run-SparrowSyntaxFix.ps1 -Solution ...\OSTES.sln -FilesFrom index.csv   # (정밀) 검출된 파일만 (SparrowXlsExport 산출)
      .\Run-SparrowSyntaxFix.ps1 -Solution ...\OSTES.sln -ExePath C:\tools\SparrowSyntaxFix.exe  # 폐쇄망: 반입 exe 지정

    폐쇄망 참고: 이 툴은 Roslyn을 품은 컴파일 exe라, 대상 PC에 exe가 있어야 합니다. 러너는
    (1) -ExePath  (2) 스크립트 옆 publish\SparrowSyntaxFix.exe  (3) bin\Release\net8.0\SparrowSyntaxFix.dll
    (4) 없으면 `dotnet build`(패키지 복원 가능할 때)  순으로 확보합니다. 인터넷 없는 PC는 (1)/(2)로 반입 exe를 주세요.
#>
param(
    [string]$Solution,
    [ValidateSet('nullvar', 'nullcast', 'parens', 'objectvar-safe', 'foreachcast', 'obviousvar', 'objectvar-narrowing', 'localconst', 'objectinitializer', 'arrayvar-safe', 'arrayvar-narrowing')]
    [string[]]$Rules = @('objectvar-safe', 'obviousvar', 'arrayvar-safe', 'parens'),
    [switch]$Commit,
    [switch]$DryRun,
    [string]$FilesFrom,
    [string]$ExePath,
    [string]$LogDir
)

$ErrorActionPreference = 'Stop'
$rulesExplicit = $PSBoundParameters.ContainsKey('Rules')

# $PSScriptRoot가 일부 호출에서 비어 있을 수 있어 본문에서 스크립트 폴더 해석
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# 원큐 UX: 인자 없이 실행하면 솔루션 경로를 물어봄(그다음 커밋 여부도 물어봄). 붙여넣기 따옴표 자동 제거.
if (-not $Solution) {
    $Solution = Read-Host "정리할 솔루션(.sln) 파일 또는 소스 폴더 경로를 입력하세요"
}
if ($Solution) { $Solution = $Solution.Trim().Trim('"').Trim("'").Trim() }
if (-not $Solution) { throw "경로가 비었습니다. 솔루션(.sln) 또는 소스 폴더 경로가 필요합니다." }

# 규칙 -> 커밋 라벨 (검수 가능한 단위로 규칙별 커밋)
$labels = [ordered]@{
    nullcast              = '검토필요: 명시 지역변수 typed null 초기화 (SparrowSyntaxFix)'
    nullvar               = '검토필요: 명시 지역변수 typed null 초기화 (SparrowSyntaxFix)'
    parens                = '괄호 명확화 일괄 (&&/|| 피연산자) (SparrowSyntaxFix)'
    'objectvar-safe'      = '객체 생성 명시 타입 var 변환 일괄 (SparrowSyntaxFix)'
    foreachcast           = '검토필요: foreach Cast<T> 기반 var 변환 (SparrowSyntaxFix)'
    obviousvar            = '명확한 지역변수 var 변환 일괄 (SparrowSyntaxFix)'
    'objectvar-narrowing' = '검토필요: 정적 타입 축소 var 변환 (SparrowSyntaxFix)'
    localconst            = '검토필요: 지역 const var 전환 (SparrowSyntaxFix)'
    objectinitializer     = '검토필요: 연속 대입 object initializer 통합 (SparrowSyntaxFix)'
    'arrayvar-safe'       = '배열 선언 문법 간소화 일괄 (SparrowSyntaxFix)'
    'arrayvar-narrowing'  = '검토필요: 배열 정적 타입 축소 var 변환 (SparrowSyntaxFix)'
}

if (-not $rulesExplicit -and [Environment]::UserInteractive) {
    $optionalRules = @(
        @{ Key = 'foreachcast'; Prompt = 'foreach Cast<T> 기반 var 변환(foreachcast)을 포함할까요? (Y=포함 / N=제외)' },
        @{ Key = 'objectinitializer'; Prompt = '연속 대입 object initializer 통합(objectinitializer)을 포함할까요? (Y=포함 / N=제외)' },
        @{ Key = 'nullvar'; Prompt = '명시 지역변수 typed null 초기화(nullvar)를 포함할까요? (Y=포함 / N=제외)' },
        @{ Key = 'objectvar-narrowing'; Prompt = '정적 타입 축소 var 변환(objectvar-narrowing)을 포함할까요? (Y=포함 / N=제외)' },
        @{ Key = 'localconst'; Prompt = '지역 const var 전환(localconst)을 포함할까요? (Y=포함 / N=제외)' },
        @{ Key = 'arrayvar-narrowing'; Prompt = '배열 정적 타입 축소 var 변환(arrayvar-narrowing)을 포함할까요? (Y=포함 / N=제외)' }
    )
    foreach ($rule in $optionalRules) {
        $ans = Read-Host $rule.Prompt
        if ($ans -match '^\s*(y|yes|예|ㅛ)\s*$') {
            $Rules += $rule.Key
            Write-Host "-> $($rule.Key) 포함"
        }
        else {
            Write-Host "-> $($rule.Key) 제외"
        }
    }
}

# 0) preflight
if (-not (Test-Path -LiteralPath $Solution)) { throw "솔루션/경로 없음: $Solution" }
$slnFull = (Resolve-Path -LiteralPath $Solution).Path
# .sln 파일이면 그 폴더, 폴더면 그대로 = 소스 루트(툴이 .cs 재귀 + 생성/백업 제외)
$root = if (Test-Path -LiteralPath $slnFull -PathType Leaf) { Split-Path -Parent $slnFull } else { $slnFull }

# 실행 로그
if (-not $LogDir) { $LogDir = (Get-Location).Path }
$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$logPath = Join-Path $LogDir ("Run-SparrowSyntaxFix.$stamp.log")
"Run-SparrowSyntaxFix | root=$root | rules=$($Rules -join ',') | dryrun=$([bool]$DryRun) | commit=$([bool]$Commit) | time=$stamp" | Out-File -LiteralPath $logPath -Encoding utf8
Write-Host "실행 로그(전체): $logPath"
Write-Host "소스 루트      : $root"

# 1) 툴 바이너리 확보: ExePath > publish exe > (소스 있으면) 항상 증분 빌드 > 기존 dll(폐쇄망 fallback)
#    ★ 중요: 소스(csproj)가 있으면 항상 재빌드한다. 오래된 bin\Release\dll을 그대로 쓰면 pull 후에도 옛 규칙이
#    돌아 "안 고쳐졌다"처럼 보이기 때문(과거 실제 발생). 증분 빌드는 최신이면 ~수초로 no-op에 가깝다.
function Resolve-Tool {
    if ($ExePath) {
        if (-not (Test-Path -LiteralPath $ExePath)) { throw "-ExePath 없음: $ExePath" }
        $p = (Resolve-Path -LiteralPath $ExePath).Path
        return @{ kind = $(if ($p -match '\.dll$') { 'dll' } else { 'exe' }); path = $p }
    }
    $pubExe = Join-Path $scriptDir 'publish\SparrowSyntaxFix.exe'
    if (Test-Path -LiteralPath $pubExe) { return @{ kind = 'exe'; path = $pubExe } }

    $dll = Join-Path $scriptDir 'bin\Release\net8.0\SparrowSyntaxFix.dll'
    $csproj = Join-Path $scriptDir 'SparrowSyntaxFix.csproj'

    # 소스 + SDK가 있으면 항상 증분 빌드로 dll을 최신 소스와 일치시킨다.
    if ((Test-Path -LiteralPath $csproj) -and (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        Write-Host "소스에서 빌드(증분, 최신 규칙 보장): dotnet build -c Release"
        Write-Host "  (첫 빌드는 NuGet 복원 포함 — 아래 진행이 흐릅니다. 인터넷 없는 PC면 Ctrl+C 후 -ExePath 로 반입 exe 지정.)"
        # 빌드는 네이티브(dotnet) 호출 — stderr가 EAP=Stop+2>&1에서 종료오류로 throw되는 것을 막기 위해 Continue로 격리.
        # 출력은 삼키지 않고 한 줄씩 콘솔+로그로 흘려 "멈춘 것처럼 보임"을 방지.
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & dotnet build $csproj -c Release --nologo -v minimal 2>&1 | ForEach-Object {
                Write-Host "  | $_"
                Add-Content -LiteralPath $logPath -Value $_
            }
            $buildExit = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $prevEap }
        if ($buildExit -eq 0 -and (Test-Path -LiteralPath $dll)) {
            Write-Host "빌드 완료(최신): $dll"
            return @{ kind = 'dll'; path = $dll }
        }
        if (Test-Path -LiteralPath $dll) {
            Write-Warning "빌드 실패(exit=$buildExit) — 기존 dll을 사용합니다(최신 소스와 다를 수 있음!). 로그: $logPath"
            return @{ kind = 'dll'; path = $dll }
        }
        throw "빌드 실패/미완(exit=$buildExit) + 기존 dll 없음. 인터넷 PC에서 발행한 exe를 -ExePath 로 지정하세요. 로그: $logPath"
    }

    # SDK/소스 없음(폐쇄망 등): 기존 빌드 dll이라도 사용
    if (Test-Path -LiteralPath $dll) {
        Write-Warning "SDK/소스가 없어 기존 빌드 dll을 사용합니다(최신 여부 미검증): $dll"
        return @{ kind = 'dll'; path = $dll }
    }
    throw "실행할 exe/dll이 없고 빌드도 불가합니다(csproj/SDK 없음). 인터넷 PC에서 발행한 exe를 -ExePath 로 지정하세요."
}
$tool = Resolve-Tool
Write-Host "툴            : $($tool.path)"

# 작업트리 오염 경고(자동수정 diff 격리를 위해)
if (-not $DryRun) {
    $dirty = @(& git -C $root status --porcelain 2>$null)
    if ($dirty.Count -gt 0) {
        Write-Warning "작업트리에 미커밋 변경이 있습니다($($dirty.Count)개). 자동수정 diff와 섞일 수 있으니 깨끗한 상태에서 권장."
    }
}

# 1b) -Commit/-DryRun 둘 다 없으면 물어봄(플래그 빼먹는 실수 방지). 비대화형은 안 물어보고 커밋 안 함.
if (-not $Commit -and -not $DryRun) {
    if ([Environment]::UserInteractive) {
        $ans = Read-Host "규칙별로 커밋할까요? (Y=규칙별 자동 커밋 / N=파일만 수정, 커밋 안 함)"
        if ($ans -match '^\s*(y|yes|예|ㅛ)\s*$') { $Commit = $true; Write-Host "-> 규칙별 커밋 진행" }
        else { Write-Host "-> 파일만 수정(커밋 안 함). 나중에 -Commit으로 재실행 가능." }
    }
    else {
        Write-Host "(비대화형: -Commit 미지정 -> 커밋 안 함)"
    }
}

# 2) 규칙별 실행 — native(dotnet/git) stderr가 EAP=Stop에서 throw되는 것을 막기 위해 이 구간은 Continue.
$ErrorActionPreference = 'Continue'
$failed = $false
$grand = 0
foreach ($r in $Rules) {
    $toolArgs = @($root, '--rules', $r, '--root', $root)
    if ($FilesFrom) { $toolArgs += @('--files-from', $FilesFrom) }
    if ($DryRun) { $toolArgs += '--dry-run' }

    if ($tool.kind -eq 'dll') { $out = & dotnet $tool.path @toolArgs 2>&1 }
    else { $out = & $tool.path @toolArgs 2>&1 }
    $code = $LASTEXITCODE
    $text = ($out | Out-String)

    Add-Content -LiteralPath $logPath -Value ("`n========== $r | exit=$code ==========")
    Add-Content -LiteralPath $logPath -Value $text

    $nChanged = [regex]::Match($text, 'files changed:\s*(\d+)').Groups[1].Value
    $nEdits = [regex]::Match($text, [regex]::Escape($r) + ' edits:\s*(\d+)').Groups[1].Value
    if ($nEdits) { $grand += [int]$nEdits }

    Write-Host ""
    Write-Host "=== $r  | exit=$code ==="
    Write-Host "  변경 파일 : $(if ($nChanged) { $nChanged } else { '? (로그 확인)' })"
    Write-Host "  수정 건수 : $(if ($nEdits) { $nEdits } else { '? (로그 확인)' })"

    if ($code -eq 2) { Write-Warning "  사용법 오류(exit 2) - 로그 확인."; $failed = $true; break }
    if ($code -ne 0) { Write-Warning "  실패(exit $code) - 로그 확인."; $failed = $true; break }
    if ($DryRun) { Write-Host "  결과      : [dry-run] 파일 변경 안 함"; continue }

    if ($Commit) {
        & git -C $root add -- '*.cs' 2>&1 | Out-Null
        & git -C $root diff --cached --quiet
        if ($LASTEXITCODE -ne 0) {
            $prefix = if ($labels[$r] -like '검토필요:*') { 'sparrow(A)! ' } else { 'sparrow(A): ' }
            & git -C $root commit -q -m "$prefix$($labels[$r])"
            Write-Host "  커밋      : $prefix$($labels[$r])"
        }
        else { Write-Host "  커밋      : 변경 없음 -> 건너뜀 (이 규칙에서 바뀐 .cs 없음)" }
    }
    else { Write-Host "  커밋      : -Commit 미지정 -> 커밋 안 함 (파일만 수정됨)" }
}

Write-Host ""
if (-not $DryRun) { Write-Host "총 수정 건수(적용된 규칙 합): $grand" }
if ($failed) { Write-Host "일부 규칙 미완 -> 로그 확인." }
Write-Host "전체 로그: $logPath"
Write-Host "다음(필수): (1) 빌드 통과 확인  (2) 스패로우 재분석으로 해당 체커 건수 감소 확인 (Roslyn 경계 != Sparrow 경계)."
if ($failed) { exit 1 }
