#requires -Version 5.1
<#
    Run-Triage.ps1 — Sparrow Track C 트리아지 결정론 오케스트레이터.
    LLM/판단 없음: 체커키→가이드 사전조회로 요청 조립(prepare), verdict JSON 검증·집계(collect)만 한다.
    판정 자체는 사람/LLM이 triage-prompt 규칙대로 별도 수행(triage-contract.md 참조).

    사용:
      # 요청 조립(결정론)
      .\Run-Triage.ps1 prepare -Index out\index.csv -ItemsDir out\items -GuidesDir ..\checkers -Out triage `
                               [-Checker FORWARD_NULL] [-Severity 매우위험,높음] [-Max 50] [-PromptPath triage-prompt.md]
      # verdict 수거·검증·집계(결정론)
      .\Run-Triage.ps1 collect -VerdictsDir triage\verdicts -Worklist triage\worklist.csv -Out triage

    산출물(prepare): Out\requests\{ID}_{체커키}.md · Out\worklist.csv · Out\unresolved.csv · Out\verdicts\(빈 폴더)
    산출물(collect): Out\triage-ledger.csv · Out\by-checker\<체커>.md · Out\invalid.csv
    멱등: 재실행 시 산출물을 깨끗이 덮어씀(verdicts\는 입력이라 보존).
#>
param(
    [Parameter(Position = 0)][ValidateSet('prepare', 'collect')][string]$Mode,

    # prepare
    [string]$Index,
    [string]$ItemsDir,
    [string]$GuidesDir,
    [string]$Checker,
    [string]$Severity,
    [int]$Max,
    [string]$PromptPath,

    # collect
    [string]$VerdictsDir,
    [string]$Worklist,

    # 공통
    [string]$Out
)

$ErrorActionPreference = 'Stop'

function Get-ScriptDir {
    if ($PSScriptRoot) { return $PSScriptRoot }
    return (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

# BOM 인지 UTF-8 텍스트 읽기(첫 문자의 U+FEFF 제거).
function Read-TextNoBom {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($text.Length -gt 0 -and [int][char]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }
    return $text
}

# BOM 인지 CSV 파싱 → PSCustomObject 배열(Korean 헤더/따옴표 처리).
function Read-CsvNoBom {
    param([string]$Path)
    $text = Read-TextNoBom -Path $Path
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    return @($text | ConvertFrom-Csv)
}

# UTF-8(BOM 없음) + LF 로 기록. 다른 툴이 읽는 산출물 표준.
function Write-Utf8Lf {
    param([string]$Path, [string]$Content)
    $lf = $Content -replace "`r`n", "`n"
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $lf, $enc)
}

# 파일명 안전화(공백·유효하지 않은 문자 → '-'). 파서 San()과 동일 개념.
function Get-SafeName {
    param([string]$s)
    if ($null -eq $s) { return '' }
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        if ($ch -eq ' ' -or $invalid -contains $ch) { [void]$sb.Append('-') } else { [void]$sb.Append($ch) }
    }
    return $sb.ToString()
}

function ConvertTo-Csv1Line {
    param([string]$s)
    if ($null -eq $s) { return '' }
    $one = ($s -replace "`r`n", ' ') -replace "`n", ' ' -replace "`r", ' '
    return $one.Trim()
}

function ConvertTo-CsvField {
    param([string]$s)
    if ($null -eq $s) { $s = '' }
    if ($s.IndexOfAny([char[]]@(',', '"', "`n", "`r")) -ge 0) {
        return '"' + ($s -replace '"', '""') + '"'
    }
    return $s
}

# ---------------------------------------------------------------- prepare
function Invoke-Prepare {
    if (-not $Index) { throw "prepare: -Index <index.csv> 필요" }
    if (-not $ItemsDir) { throw "prepare: -ItemsDir <items 폴더> 필요" }
    if (-not $GuidesDir) { throw "prepare: -GuidesDir <checkers 폴더> 필요" }
    if (-not $Out) { throw "prepare: -Out <출력 폴더> 필요" }

    if (-not (Test-Path -LiteralPath $Index)) { throw "index.csv 없음: $Index" }
    if (-not (Test-Path -LiteralPath $ItemsDir)) { throw "items 폴더 없음: $ItemsDir" }
    if (-not (Test-Path -LiteralPath $GuidesDir)) { throw "checkers(가이드) 폴더 없음: $GuidesDir" }

    if (-not $PromptPath) { $PromptPath = Join-Path (Get-ScriptDir) 'triage-prompt.md' }
    if (-not (Test-Path -LiteralPath $PromptPath)) { throw "프롬프트 템플릿 없음: $PromptPath" }
    $promptTemplate = Read-TextNoBom -Path $PromptPath

    $sevSet = @()
    if ($Severity) { $sevSet = @($Severity.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 }) }

    # 출력 폴더 준비(멱등: prepare 산출물만 초기화, verdicts\는 보존).
    [void](New-Item -ItemType Directory -Force -Path $Out)
    $reqDir = Join-Path $Out 'requests'
    if (Test-Path -LiteralPath $reqDir) { Remove-Item -LiteralPath $reqDir -Recurse -Force }
    [void](New-Item -ItemType Directory -Force -Path $reqDir)
    $verDir = Join-Path $Out 'verdicts'
    [void](New-Item -ItemType Directory -Force -Path $verDir)   # 입력 폴더 — 있으면 보존

    $rows = @(Read-CsvNoBom -Path $Index)   # @() 강제: 1행 CSV 스칼라 접힘 방지(foreach 안정)

    $worklist = New-Object System.Collections.Generic.List[string]
    $worklist.Add('id,체커키,위험도,파일명,라인,item_md,guide,상태')
    $unresolved = New-Object System.Collections.Generic.List[string]
    $unresolved.Add('id,체커키,위험도,파일명,라인,item_md,사유')

    $requestCount = 0
    $unresolvedCount = 0
    $perChecker = @{}
    $ordinal = 0

    # 항목 md 파싱을 회피(오차 소지)하기 위해 index.csv 순서를 그대로 안정 정렬로 사용.
    $ErrorActionPreference = 'Continue'
    foreach ($row in $rows) {
        $ordinal++
        $id = [string]$row.'ID'
        $checkerKey = [string]$row.'체커 키'
        $sev = [string]$row.'위험도'
        $file = [string]$row.'파일명'
        $line = [string]$row.'라인'
        $mdField = [string]$row.'md_file'

        # 필터(AND). checker=정확 일치(체커 키), severity=집합 포함.
        if ($Checker -and ($checkerKey -ne $Checker)) { continue }
        if ($sevSet.Count -gt 0 -and ($sevSet -notcontains $sev.Trim())) { continue }
        if ($Max -gt 0 -and $requestCount + $unresolvedCount -ge $Max) { break }

        $idPart = if ($id -and $id.Trim().Length -gt 0) { $id.Trim() } else { $ordinal.ToString('D5') }
        $itemLeaf = if ($mdField) { Split-Path -Leaf $mdField } else { '' }
        $itemPath = if ($itemLeaf) { Join-Path $ItemsDir $itemLeaf } else { '' }

        $guidePath = Join-Path $GuidesDir ("{0}.md" -f $checkerKey)

        if (-not $checkerKey -or -not (Test-Path -LiteralPath $guidePath)) {
            $unresolvedCount++
            $reason = if (-not $checkerKey) { '체커 키 없음' } else { '가이드 없음(Track A/B 또는 무가이드)' }
            $unresolved.Add((@(
                        (ConvertTo-CsvField $idPart), (ConvertTo-CsvField $checkerKey), (ConvertTo-CsvField $sev),
                        (ConvertTo-CsvField $file), (ConvertTo-CsvField $line), (ConvertTo-CsvField $itemLeaf),
                        (ConvertTo-CsvField $reason)
                    ) -join ','))
            continue
        }

        if (-not $itemPath -or -not (Test-Path -LiteralPath $itemPath)) {
            $unresolvedCount++
            $unresolved.Add((@(
                        (ConvertTo-CsvField $idPart), (ConvertTo-CsvField $checkerKey), (ConvertTo-CsvField $sev),
                        (ConvertTo-CsvField $file), (ConvertTo-CsvField $line), (ConvertTo-CsvField $itemLeaf),
                        (ConvertTo-CsvField ('항목 md 없음: ' + $itemLeaf))
                    ) -join ','))
            continue
        }

        $guideText = Read-TextNoBom -Path $guidePath
        if ($checkerKey -eq 'NULL_RETURN_STD') {
            $contractPath = Join-Path (Split-Path -Parent $GuidesDir) 'dotnet-contracts\null-return-std.md'
            if (Test-Path -LiteralPath $contractPath) {
                $guideText = $guideText + "`n`n---`n`n## [추가 계약표: .NET null-return API]`n`n" + (Read-TextNoBom -Path $contractPath)
            }
        }
        $itemText = Read-TextNoBom -Path $itemPath

        # 자리표시자 치환(리터럴). -replace 는 정규식이라 부작용 위험 → .Replace() 사용.
        $reqText = $promptTemplate.Replace('{{GUIDE}}', $guideText).Replace('{{ITEM}}', $itemText)

        $reqName = ('{0}_{1}.md' -f (Get-SafeName $idPart), (Get-SafeName $checkerKey))
        $reqPath = Join-Path $reqDir $reqName
        Write-Utf8Lf -Path $reqPath -Content $reqText
        $requestCount++
        if ($perChecker.ContainsKey($checkerKey)) { $perChecker[$checkerKey]++ } else { $perChecker[$checkerKey] = 1 }

        $worklist.Add((@(
                    (ConvertTo-CsvField $idPart), (ConvertTo-CsvField $checkerKey), (ConvertTo-CsvField $sev),
                    (ConvertTo-CsvField $file), (ConvertTo-CsvField $line),
                    (ConvertTo-CsvField ('requests/' + $reqName)),
                    (ConvertTo-CsvField $guidePath), 'TODO'
                ) -join ','))
    }
    $ErrorActionPreference = 'Stop'

    Write-Utf8Lf -Path (Join-Path $Out 'worklist.csv') -Content (($worklist -join "`n") + "`n")
    Write-Utf8Lf -Path (Join-Path $Out 'unresolved.csv') -Content (($unresolved -join "`n") + "`n")

    Write-Host "=== prepare 요약 ==="
    Write-Host ("  요청 생성수 : {0}" -f $requestCount)
    Write-Host ("  미해결수    : {0}" -f $unresolvedCount)
    Write-Host "  체커별 카운트:"
    if ($perChecker.Count -eq 0) {
        Write-Host "    (없음)"
    }
    else {
        foreach ($k in ($perChecker.Keys | Sort-Object { -$perChecker[$_] }, { $_ })) {
            Write-Host ("    {0} : {1}" -f $k, $perChecker[$k])
        }
    }
    Write-Host ("  출력 폴더   : {0}" -f (Resolve-Path -LiteralPath $Out).Path)
}

# ---------------------------------------------------------------- collect
function Test-Verdict {
    # 반환: 문제 사유(정상이면 $null).
    param($v)
    if ($null -eq $v) { return 'JSON 파싱 실패' }
    foreach ($k in @('id', 'checker', 'file', 'line', 'verdict')) {
        if (-not ($v.PSObject.Properties.Name -contains $k)) { return "필수 키 없음: $k" }
    }
    $verdict = [string]$v.verdict
    if (@('진성', '위양성', '보류') -notcontains $verdict) { return "verdict 값 오류: '$verdict'" }
    foreach ($boolKey in @('needs_context', 'needs_frontier')) {
        if ($v.PSObject.Properties.Name -contains $boolKey) {
            if (-not ($v.$boolKey -is [bool])) { return "$boolKey 값은 boolean이어야 함" }
        }
    }
    $needsContext = ($v.PSObject.Properties.Name -contains 'needs_context' -and $v.needs_context)
    $needsFrontier = ($v.PSObject.Properties.Name -contains 'needs_frontier' -and $v.needs_frontier)
    if ($needsContext -and $needsFrontier) { return 'needs_context와 needs_frontier를 동시에 true로 둘 수 없음' }
    if ($verdict -ne '보류' -and ($needsContext -or $needsFrontier)) {
        return '진성/위양성 verdict에는 needs_context/needs_frontier=true를 사용할 수 없음'
    }

    if ($verdict -eq '진성') {
        if (-not ($v.PSObject.Properties.Name -contains 'fix') -or $null -eq $v.fix) { return '진성인데 fix 없음' }
        $before = [string]$v.fix.before
        $after = [string]$v.fix.after
        if ([string]::IsNullOrWhiteSpace($before) -or [string]::IsNullOrWhiteSpace($after)) {
            return '진성인데 fix.before/after 비어있음'
        }
    }
    elseif ($verdict -eq '위양성') {
        if ([string]::IsNullOrWhiteSpace([string]$v.false_positive_reason)) { return '위양성인데 false_positive_reason 없음' }
    }
    elseif ($verdict -eq '보류') {
        if ([string]::IsNullOrWhiteSpace([string]$v.hold_reason)) { return '보류인데 hold_reason 없음' }
        if ($needsContext) {
            if (-not ($v.PSObject.Properties.Name -contains 'missing_context') -or $null -eq $v.missing_context) {
                return 'needs_context=true인데 missing_context 없음'
            }
            $missing = @($v.missing_context)
            if ($missing.Count -eq 0 -or [string]::IsNullOrWhiteSpace(($missing -join ' '))) {
                return 'needs_context=true인데 missing_context 비어있음'
            }
        }
    }
    return $null
}

function Invoke-Collect {
    if (-not $VerdictsDir) { throw "collect: -VerdictsDir <*.json 폴더> 필요" }
    if (-not $Out) { throw "collect: -Out <출력 폴더> 필요" }
    if (-not (Test-Path -LiteralPath $VerdictsDir)) { throw "verdicts 폴더 없음: $VerdictsDir" }
    if ($Worklist -and -not (Test-Path -LiteralPath $Worklist)) { Write-Warning "worklist 없음(무시): $Worklist" }

    [void](New-Item -ItemType Directory -Force -Path $Out)
    $byCheckerDir = Join-Path $Out 'by-checker'
    if (Test-Path -LiteralPath $byCheckerDir) { Remove-Item -LiteralPath $byCheckerDir -Recurse -Force }
    [void](New-Item -ItemType Directory -Force -Path $byCheckerDir)

    $files = @(Get-ChildItem -LiteralPath $VerdictsDir -Filter '*.json' -File | Sort-Object Name)

    $valid = New-Object System.Collections.Generic.List[object]
    $invalid = New-Object System.Collections.Generic.List[string]
    $invalid.Add('verdict_file,사유')

    $cntJin = 0; $cntWi = 0; $cntBo = 0; $cntBad = 0

    $ErrorActionPreference = 'Continue'
    foreach ($f in $files) {
        $obj = $null
        $parseErr = $null
        try { $obj = (Read-TextNoBom -Path $f.FullName | ConvertFrom-Json) } catch { $parseErr = $_.Exception.Message }
        $reason = if ($parseErr) { "JSON 파싱 실패: $parseErr" } else { Test-Verdict $obj }
        if ($reason) {
            $cntBad++
            $invalid.Add((@((ConvertTo-CsvField $f.Name), (ConvertTo-CsvField $reason)) -join ','))
            continue
        }
        $valid.Add($obj)
        switch ([string]$obj.verdict) {
            '진성' { $cntJin++ }
            '위양성' { $cntWi++ }
            '보류' { $cntBo++ }
        }
    }
    $ErrorActionPreference = 'Stop'

    # 결정론 정렬: 체커 → id → 파일 → 라인.
    $sorted = @($valid | Sort-Object `
        @{ Expression = { [string]$_.checker } }, `
        @{ Expression = { [string]$_.id } }, `
        @{ Expression = { [string]$_.file } }, `
        @{ Expression = { [string]$_.line } })

    # 원장(ledger)
    $ledger = New-Object System.Collections.Generic.List[string]
    $ledger.Add('id,체커,파일,라인,verdict,cwe,needs_context,missing_context,needs_frontier,근거요약')
    foreach ($v in $sorted) {
        $nc = if ($v.PSObject.Properties.Name -contains 'needs_context' -and $v.needs_context) { 'true' } else { 'false' }
        $mc = if ($v.PSObject.Properties.Name -contains 'missing_context' -and $null -ne $v.missing_context) { (@($v.missing_context) -join '; ') } else { '' }
        $nf = if ($v.PSObject.Properties.Name -contains 'needs_frontier' -and $v.needs_frontier) { 'true' } else { 'false' }
        $summary = if ([string]$v.verdict -eq '위양성') { [string]$v.false_positive_reason }
        elseif ([string]$v.verdict -eq '보류') { [string]$v.hold_reason }
        else { [string]$v.rationale }
        $ledger.Add((@(
                    (ConvertTo-CsvField ([string]$v.id)), (ConvertTo-CsvField ([string]$v.checker)),
                    (ConvertTo-CsvField ([string]$v.file)), (ConvertTo-CsvField ([string]$v.line)),
                    (ConvertTo-CsvField ([string]$v.verdict)), (ConvertTo-CsvField ([string]$v.cwe)),
                    $nc, (ConvertTo-CsvField (ConvertTo-Csv1Line $mc)),
                    $nf, (ConvertTo-CsvField (ConvertTo-Csv1Line $summary))
                ) -join ','))
    }
    Write-Utf8Lf -Path (Join-Path $Out 'triage-ledger.csv') -Content (($ledger -join "`n") + "`n")
    Write-Utf8Lf -Path (Join-Path $Out 'invalid.csv') -Content (($invalid -join "`n") + "`n")

    # by-checker/<체커>.md
    $groups = $sorted | Group-Object { [string]$_.checker } | Sort-Object Name
    foreach ($g in $groups) {
        $checkerKey = $g.Name
        $jin = @($g.Group | Where-Object { [string]$_.verdict -eq '진성' })
        $wi = @($g.Group | Where-Object { [string]$_.verdict -eq '위양성' })
        $bo = @($g.Group | Where-Object { [string]$_.verdict -eq '보류' })

        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append("# $checkerKey — 트리아지 결과`n`n")
        [void]$sb.Append("## 진성 (수정 대상 — 커밋 단위 후보)`n`n")
        if ($jin.Count -eq 0) { [void]$sb.Append("- (없음)`n") }
        foreach ($v in $jin) {
            $lines = if ($v.PSObject.Properties.Name -contains 'fix' -and $v.fix) { [string]$v.fix.lines } else { '' }
            [void]$sb.Append(("- [{0}] {1}:{2}" -f [string]$v.id, [string]$v.file, [string]$v.line))
            if ($lines) { [void]$sb.Append(" (수정 라인 $lines)") }
            [void]$sb.Append(" — " + (ConvertTo-Csv1Line ([string]$v.rationale)) + "`n")
        }
        [void]$sb.Append("`n## 위양성 (사유서)`n`n")
        if ($wi.Count -eq 0) { [void]$sb.Append("- (없음)`n") }
        foreach ($v in $wi) {
            [void]$sb.Append(("- [{0}] {1}:{2} — {3}`n" -f [string]$v.id, [string]$v.file, [string]$v.line, (ConvertTo-Csv1Line ([string]$v.false_positive_reason))))
        }
        [void]$sb.Append("`n## 보류 (문맥 보강 또는 frontier 검토 후보)`n`n")
        if ($bo.Count -eq 0) { [void]$sb.Append("- (없음)`n") }
        foreach ($v in $bo) {
            $nc = if ($v.PSObject.Properties.Name -contains 'needs_context' -and $v.needs_context) { 'true' } else { 'false' }
            $mc = if ($v.PSObject.Properties.Name -contains 'missing_context' -and $null -ne $v.missing_context) { (@($v.missing_context) -join '; ') } else { '' }
            $nf = if ($v.PSObject.Properties.Name -contains 'needs_frontier' -and $v.needs_frontier) { 'true' } else { 'false' }
            [void]$sb.Append(("- [{0}] {1}:{2} — {3} (needs_context={4}; missing_context={5}; needs_frontier={6})`n" -f [string]$v.id, [string]$v.file, [string]$v.line, (ConvertTo-Csv1Line ([string]$v.hold_reason)), $nc, (ConvertTo-Csv1Line $mc), $nf))
        }
        Write-Utf8Lf -Path (Join-Path $byCheckerDir ((Get-SafeName $checkerKey) + '.md')) -Content $sb.ToString()
    }

    Write-Host "=== collect 요약 ==="
    Write-Host ("  진성 : {0}" -f $cntJin)
    Write-Host ("  위양성 : {0}" -f $cntWi)
    Write-Host ("  보류 : {0}" -f $cntBo)
    Write-Host ("  무효 : {0}" -f $cntBad)
    Write-Host ("  원장 : {0}" -f (Join-Path (Resolve-Path -LiteralPath $Out).Path 'triage-ledger.csv'))
}

# ---------------------------------------------------------------- dispatch
if (-not $Mode) { throw "첫 인자로 모드(prepare | collect)를 지정하세요. 예: .\Run-Triage.ps1 prepare -Index ... " }
switch ($Mode) {
    'prepare' { Invoke-Prepare }
    'collect' { Invoke-Collect }
}
