#requires -Version 5.1
<#
    Compare-Sparrow.ps1 — Track C G2 게이트 툴.
    수정 전/후 Sparrow .xls 두 개를 SparrowXlsExport.exe로 파싱해 index.csv를 비교한다.
    - 체커별 before/after 건수·delta
    - AFTER에는 있고 BEFORE에는 없는 (체커키,파일명,라인) 집합 = 신규 검출
    -Checker 지정 시 그 체커 게이트: PASS = 그 체커 after-count 0(검출 소멸) AND 신규 검출 0(전체).
    -Checker 미지정 시: 신규 검출 0(전체) = PASS(회귀 확인).
    PASS면 exit 0, 아니면 exit 1.

    사용:
      .\Compare-Sparrow.ps1 -Before before.xls -After after.xls -Checker FORWARD_NULL `
                            [-Exe C:\...\SparrowXlsExport.exe] [-Work C:\temp\g2]
#>
param(
    [Parameter(Mandatory = $true)][string]$Before,
    [Parameter(Mandatory = $true)][string]$After,
    [string]$Checker,
    [string]$Exe,
    [string]$Work
)

$ErrorActionPreference = 'Stop'

function Get-DefaultParserExe {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $refsDir = Split-Path -Parent $scriptDir
    $skillDir = Split-Path -Parent $refsDir
    return (Join-Path $skillDir 'tools\_internal\SparrowXlsExport\bin\Release\net8.0\SparrowXlsExport.exe')
}

function Read-TextNoBom {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($text.Length -gt 0 -and [int][char]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }
    return $text
}
function Read-CsvNoBom {
    param([string]$Path)
    $text = Read-TextNoBom -Path $Path
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    return @($text | ConvertFrom-Csv)
}

if (-not (Test-Path -LiteralPath $Before)) { throw "before xls 없음: $Before" }
if (-not (Test-Path -LiteralPath $After)) { throw "after xls 없음: $After" }

if (-not $Exe) { $Exe = Get-DefaultParserExe }
if (-not (Test-Path -LiteralPath $Exe)) {
    throw "SparrowXlsExport.exe 없음: $Exe`n  -Exe 로 경로를 지정하세요(기본 추정 경로: $KnownExe)."
}

if (-not $Work) { $Work = Join-Path ([System.IO.Path]::GetTempPath()) ('sparrow-g2-' + [System.IO.Path]::GetRandomFileName()) }
$beforeOut = Join-Path $Work 'before'
$afterOut = Join-Path $Work 'after'
[void](New-Item -ItemType Directory -Force -Path $beforeOut)
[void](New-Item -ItemType Directory -Force -Path $afterOut)

# native exe 실행: stderr를 throwing 경로(2>&1+Stop)에 넣지 않고 $LASTEXITCODE로 판정.
function Invoke-Parser {
    param([string]$Xls, [string]$OutDir)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $Exe $Xls --out $OutDir | Out-Null
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($code -ne 0) { throw "파서 실패(exit $code): $Xls" }
    $idx = Join-Path $OutDir 'index.csv'
    if (-not (Test-Path -LiteralPath $idx)) { throw "index.csv 생성 안 됨: $idx" }
    return $idx
}

$beforeIdx = Invoke-Parser -Xls (Resolve-Path -LiteralPath $Before).Path -OutDir $beforeOut
$afterIdx = Invoke-Parser -Xls (Resolve-Path -LiteralPath $After).Path -OutDir $afterOut

$beforeRows = @(Read-CsvNoBom -Path $beforeIdx)   # @() 강제: 1행 CSV가 스칼라로 접혀 .Count 가 null 되는 것 방지
$afterRows = @(Read-CsvNoBom -Path $afterIdx)

function Get-KeySet {
    param($Rows)
    $set = New-Object System.Collections.Generic.HashSet[string]
    foreach ($r in $Rows) {
        $k = ('{0}|{1}|{2}' -f [string]$r.'체커 키', [string]$r.'파일명', [string]$r.'라인')
        [void]$set.Add($k)
    }
    return $set
}

$beforeKeys = Get-KeySet $beforeRows
$afterKeys = Get-KeySet $afterRows

# 신규 = AFTER 키 - BEFORE 키
$newKeys = New-Object System.Collections.Generic.List[string]
foreach ($k in $afterKeys) { if (-not $beforeKeys.Contains($k)) { [void]$newKeys.Add($k) } }

# 체커별 카운트
$checkers = New-Object System.Collections.Generic.SortedSet[string]
$beforeByChk = @{}; $afterByChk = @{}
foreach ($r in $beforeRows) { $c = [string]$r.'체커 키'; [void]$checkers.Add($c); if ($beforeByChk.ContainsKey($c)) { $beforeByChk[$c]++ } else { $beforeByChk[$c] = 1 } }
foreach ($r in $afterRows) { $c = [string]$r.'체커 키'; [void]$checkers.Add($c); if ($afterByChk.ContainsKey($c)) { $afterByChk[$c]++ } else { $afterByChk[$c] = 1 } }

# 신규를 체커별로 집계
$newByChk = @{}
foreach ($k in $newKeys) { $c = $k.Split('|')[0]; if ($newByChk.ContainsKey($c)) { $newByChk[$c]++ } else { $newByChk[$c] = 1 } }

Write-Host ""
Write-Host "=== Sparrow 비교 (G2) ==="
Write-Host ("before : {0}" -f (Resolve-Path -LiteralPath $Before).Path)
Write-Host ("after  : {0}" -f (Resolve-Path -LiteralPath $After).Path)
Write-Host ""
Write-Host ("{0,-45} {1,8} {2,8} {3,8} {4,8}" -f '체커 키', 'before', 'after', 'delta', '신규')
Write-Host ("-" * 80)
foreach ($c in $checkers) {
    $b = if ($beforeByChk.ContainsKey($c)) { $beforeByChk[$c] } else { 0 }
    $a = if ($afterByChk.ContainsKey($c)) { $afterByChk[$c] } else { 0 }
    $n = if ($newByChk.ContainsKey($c)) { $newByChk[$c] } else { 0 }
    Write-Host ("{0,-45} {1,8} {2,8} {3,8} {4,8}" -f $c, $b, $a, ($a - $b), $n)
}
Write-Host ("-" * 80)
Write-Host ("{0,-45} {1,8} {2,8} {3,8} {4,8}" -f '(합계)', $beforeRows.Count, $afterRows.Count, ($afterRows.Count - $beforeRows.Count), $newKeys.Count)

$overallNew = $newKeys.Count
Write-Host ""
if ($Checker) {
    $afterChk = if ($afterByChk.ContainsKey($Checker)) { $afterByChk[$Checker] } else { 0 }
    $newChk = if ($newByChk.ContainsKey($Checker)) { $newByChk[$Checker] } else { 0 }
    Write-Host ("게이트 대상 체커: {0}" -f $Checker)
    Write-Host ("  after-count(검출 소멸 목표=0) : {0}" -f $afterChk)
    Write-Host ("  이 체커 신규                   : {0}" -f $newChk)
    Write-Host ("  전체 신규(회귀 확인, 목표=0)   : {0}" -f $overallNew)
    $pass = ($afterChk -eq 0) -and ($overallNew -eq 0)
}
else {
    Write-Host ("전체 신규(회귀 확인, 목표=0) : {0}" -f $overallNew)
    $pass = ($overallNew -eq 0)
}

Write-Host ""
if ($pass) {
    Write-Host "결과: PASS"
    exit 0
}
else {
    Write-Host "결과: FAIL"
    if ($overallNew -gt 0) {
        Write-Host "  신규 검출(상위 20):"
        $shown = 0
        foreach ($k in ($newKeys | Sort-Object)) {
            Write-Host ("    - {0}" -f $k)
            $shown++; if ($shown -ge 20) { break }
        }
    }
    exit 1
}
