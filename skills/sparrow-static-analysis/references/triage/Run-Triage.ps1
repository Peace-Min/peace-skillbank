#requires -Version 5.1
<#
    Run-Triage.ps1 — Sparrow Track C 요청 패키지 결정론 오케스트레이터.
    LLM/판단 없음: 체커키→가이드 사전조회로 수정 작업 요청을 조립(prepare)한다.

    사용:
      # 요청 조립(결정론)
      .\Run-Triage.ps1 prepare -Index out\index.csv -ItemsDir out\items -GuidesDir ..\checkers -Out triage `
                               [-Checker FORWARD_NULL] [-Severity 매우위험,높음] [-Tracks C] [-Max 50] [-PromptPath triage-prompt.md]
      # -Tracks: 요청을 생성할 가이드 트랙 집합(쉼표구분, 기본 C만). 예) -Tracks A,B,C 로 Track A/B 체커도 포함.
    산출물(prepare): Out\requests\{체커키}\{ID}_{체커키}.md · Out\worklist.csv · Out\unresolved.csv
    멱등: 재실행 시 prepare 산출물을 깨끗이 덮어씀.
#>
param(
    [Parameter(Position = 0)][ValidateSet('prepare')][string]$Mode,

    # prepare
    [string]$Index,
    [string]$ItemsDir,
    [string]$GuidesDir,
    [string]$Checker,
    [string]$Severity,
    [string]$Tracks,
    [int]$Max,
    [string]$PromptPath,
    [string]$ConventionsPath,
    [string]$TemplatePath,

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

# project-conventions.md 를 '## <이름>' 섹션 사전으로 파싱. 값 = 헤더 다음~다음 '## '까지 본문(Trim).
# '### ' 하위헤딩은 섹션 경계가 아님('## ' prefix 아님). H1('# ')은 섹션 밖에서 무시.
function Get-ConventionSections {
    param([string]$Text)
    $norm = $Text -replace "`r`n", "`n"
    $lines = $norm -split "`n"
    $sections = [ordered]@{}
    $current = $null
    $buffer = New-Object System.Collections.Generic.List[string]
    foreach ($ln in $lines) {
        if ($ln.StartsWith('## ')) {
            if ($null -ne $current) { $sections[$current] = ($buffer -join "`n").Trim() }
            $current = $ln.Substring(3).Trim()
            $buffer = New-Object System.Collections.Generic.List[string]
        }
        else {
            if ($null -ne $current) { [void]$buffer.Add($ln) }
        }
    }
    if ($null -ne $current) { $sections[$current] = ($buffer -join "`n").Trim() }
    return $sections
}

# 체커 가이드에서 한글명(H1 '# KEY — 이름')과 심각도('**심각도**: 값 |')를 추출.
function Get-GuideMeta {
    param([string]$GuideText, [string]$CheckerKey)
    $norm = $GuideText -replace "`r`n", "`n"
    $lines = $norm -split "`n"
    $name = $CheckerKey
    $sev = ''
    foreach ($ln in $lines) {
        if ($name -eq $CheckerKey -and $ln.StartsWith('# ')) {
            $dash = $ln.IndexOf([char]0x2014)
            if ($dash -ge 0) { $name = $ln.Substring($dash + 1).Trim() }
        }
        if ($sev -eq '') {
            $sevIdx = $ln.IndexOf('심각도', [System.StringComparison]::Ordinal)
            if ($sevIdx -ge 0) {
                $colon = $ln.IndexOf(':', $sevIdx)
                if ($colon -ge 0) {
                    $rest = $ln.Substring($colon + 1)
                    $bar = $rest.IndexOf('|')
                    if ($bar -ge 0) { $sev = $rest.Substring(0, $bar).Trim() } else { $sev = $rest.Trim() }
                }
            }
        }
    }
    return [pscustomobject]@{ Name = $name; Severity = $sev }
}

# 체커 가이드 헤더의 '**트랙**: X'(X=A/B/C)를 추출. 파싱 불가/누락 시 'C'(안전 기본 — 무필터 회귀 방지).
function Get-GuideTrack {
    param([string]$GuideText)
    if ($GuideText -match '\*\*트랙\*\*:\s*([ABC])') { return $Matches[1] }
    return 'C'
}

function New-FallbackGuide {
    param([string]$CheckerKey, [string]$CheckerName, [string]$Severity)
    $title = if ($CheckerName -and $CheckerName.Trim().Length -gt 0) { $CheckerName.Trim() } else { $CheckerKey }
    $sev = if ($Severity -and $Severity.Trim().Length -gt 0) { $Severity.Trim() } else { '미확인' }
    return @"
# $CheckerKey — $title

**트랙**: C  |  **심각도**: $sev  |  **가이드 상태**: XLS 기반 자동 생성

## 진성 판별 기준

- 이 체커는 ``references/checkers/$CheckerKey.md`` 가이드가 아직 없다.
- Sparrow XLS의 ``체커 설명``, ``소스 코드``, ``파일명``, ``라인``, ``체커명``을 1차 근거로 삼는다.
- 실제 소스 파일에서 해당 라인 주변의 최소 문맥을 확인하고, Sparrow가 요구한 결함을 제거하는 방향으로 수정한다.

## 이렇게 보여도 넘기지 말 것

- 가이드가 없다는 이유로 false-positive 처리하거나 스킵하지 않는다.
- 코드상 문제가 없어 보인다는 이유만으로 방치하지 않는다. Sparrow 검출 항목은 전건 수정 정책의 대상이다.
- 문맥이 부족하면 ``문맥 필요``로 두고 필요한 파일, 심볼, 호출부, 소유권 정보를 명시한다.

## 수정 패턴 (C# 예시)

- 이 체커의 전용 예시는 아직 없다.
- 요청 md의 ``[검출 항목]``에 포함된 Sparrow 설명과 소스 스니펫을 기준으로 Before/After를 작성한다.
- .NET Framework 4.7.2 / C# 7.3 문법만 사용한다.
"@
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

    # OSTES 프로젝트 정책 소스(공통) + 폴더 지침 템플릿. 기본값은 스크립트 기준 상대경로로 해석.
    if (-not $ConventionsPath) { $ConventionsPath = Join-Path (Split-Path -Parent (Get-ScriptDir)) 'project-conventions.md' }
    if (-not (Test-Path -LiteralPath $ConventionsPath)) { throw "프로젝트 규약 문서 없음: $ConventionsPath" }
    if (-not $TemplatePath) { $TemplatePath = Join-Path (Get-ScriptDir) 'folder-instruction-template.md' }
    if (-not (Test-Path -LiteralPath $TemplatePath)) { throw "폴더 지침 템플릿 없음: $TemplatePath" }
    $conventions = Get-ConventionSections -Text (Read-TextNoBom -Path $ConventionsPath)
    $folderTemplate = Read-TextNoBom -Path $TemplatePath
    $commonPolicy = if ($conventions.Contains('(공통) 처리 정책')) { [string]$conventions['(공통) 처리 정책'] } else { '' }
    $generalNote = if ($conventions.Contains('프로젝트 규약')) { [string]$conventions['프로젝트 규약'] } else { '' }

    $sevSet = @()
    if ($Severity) { $sevSet = @($Severity.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 }) }

    # 트랙 필터: 요청을 생성할 가이드 트랙 집합. 기본 = C만(A/B 가이드 추가 이전과 동일한 'C 전용' 기본 복원).
    # -Tracks A,B,C 처럼 명시하면 그 집합으로 대체(GUI는 항상 C를 포함해 값을 만든다).
    $trackSet = @('C')
    if ($Tracks) { $trackSet = @($Tracks.Split(',') | ForEach-Object { $_.Trim().ToUpperInvariant() } | Where-Object { $_.Length -gt 0 }) }

    # 출력 폴더 준비(멱등: prepare 산출물만 초기화).
    [void](New-Item -ItemType Directory -Force -Path $Out)
    $reqDir = Join-Path $Out 'requests'
    if (Test-Path -LiteralPath $reqDir) { Remove-Item -LiteralPath $reqDir -Recurse -Force }
    [void](New-Item -ItemType Directory -Force -Path $reqDir)

    $rows = @(Read-CsvNoBom -Path $Index)   # @() 강제: 1행 CSV 스칼라 접힘 방지(foreach 안정)

    $worklist = New-Object System.Collections.Generic.List[string]
    $worklist.Add('id,체커키,위험도,파일명,라인,item_md,guide,상태')
    $unresolved = New-Object System.Collections.Generic.List[string]
    $unresolved.Add('id,체커키,위험도,파일명,라인,item_md,사유')

    $requestCount = 0
    $unresolvedCount = 0
    $trackFilteredCount = 0
    $perChecker = @{}
    $perCheckerMeta = @{}   # 체커키 → @{ Name; Severity }(가이드에서 1회 추출)
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
        $checkerName = [string]$row.'체커명'

        # 필터(AND). checker=정확 일치(체커 키), severity=집합 포함.
        if ($Checker -and ($checkerKey -ne $Checker)) { continue }
        if ($sevSet.Count -gt 0 -and ($sevSet -notcontains $sev.Trim())) { continue }
        if ($Max -gt 0 -and $requestCount + $unresolvedCount -ge $Max) { break }

        $idPart = if ($id -and $id.Trim().Length -gt 0) { $id.Trim() } else { $ordinal.ToString('D5') }
        $itemLeaf = if ($mdField) { Split-Path -Leaf $mdField } else { '' }
        $itemPath = if ($itemLeaf) { Join-Path $ItemsDir $itemLeaf } else { '' }

        $guidePath = Join-Path $GuidesDir ("{0}.md" -f $checkerKey)
        $fallbackGuide = $false

        if (-not $checkerKey) {
            $unresolvedCount++
            $unresolved.Add((@(
                        (ConvertTo-CsvField $idPart), (ConvertTo-CsvField $checkerKey), (ConvertTo-CsvField $sev),
                        (ConvertTo-CsvField $file), (ConvertTo-CsvField $line), (ConvertTo-CsvField $itemLeaf),
                        (ConvertTo-CsvField '체커 키 없음')
                    ) -join ','))
            continue
        }

        if (Test-Path -LiteralPath $guidePath) {
            $guideText = Read-TextNoBom -Path $guidePath
        }
        else {
            $fallbackGuide = $true
            $guidePath = ('__generated_fallback__/{0}.md' -f $checkerKey)
            $guideText = New-FallbackGuide -CheckerKey $checkerKey -CheckerName $checkerName -Severity $sev
        }

        # 가이드 존재 또는 fallback 생성 → 트랙 필터. 트랙이 요청 집합에 없으면 이 행을 건너뜀
        # (요청도, 미해결도 아님 — 단순 제외). fallback guide는 Track C로 취급한다.
        $guideTrack = Get-GuideTrack -GuideText $guideText
        if ($trackSet -notcontains $guideTrack) {
            $trackFilteredCount++
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

        if (-not $perCheckerMeta.ContainsKey($checkerKey)) {
            $perCheckerMeta[$checkerKey] = (Get-GuideMeta -GuideText $guideText -CheckerKey $checkerKey)
        }
        if (-not $fallbackGuide -and $checkerKey -eq 'NULL_RETURN_STD') {
            $contractPath = Join-Path (Split-Path -Parent $GuidesDir) 'dotnet-contracts\null-return-std.md'
            if (Test-Path -LiteralPath $contractPath) {
                $guideText = $guideText + "`n`n---`n`n## [추가 계약표: .NET null-return API]`n`n" + (Read-TextNoBom -Path $contractPath)
            }
        }
        $itemText = Read-TextNoBom -Path $itemPath

        # 자리표시자 치환(리터럴). -replace 는 정규식이라 부작용 위험 → .Replace() 사용.
        $reqText = $promptTemplate.Replace('{{GUIDE}}', $guideText).Replace('{{ITEM}}', $itemText)

        # OSTES 정책 임베드: 모든 요청에 공통 Policy A 를 붙여 self-contained 로 만든다(frontier-handoff 견고).
        $reqText = $reqText + "`n`n---`n`n## 처리 정책 (이 프로젝트)`n`n" + $commonPolicy + "`n"
        # 체커별 섹션이 있으면(OVERLY_BROAD_CATCH/EMPTY_CATCH_BLOCK/LEAK.SYSTEM_INFORMATION/TOCTOU_RACE_CONDITION) 추가로 붙인다.
        if ($conventions.Contains($checkerKey)) {
            $reqText = $reqText + "`n---`n`n## " + $checkerKey + " — 프로젝트 의무`n`n" + [string]$conventions[$checkerKey] + "`n"
        }

        $safeChecker = Get-SafeName $checkerKey
        $reqName = ('{0}_{1}.md' -f (Get-SafeName $idPart), $safeChecker)
        $subDir = Join-Path $reqDir $safeChecker
        [void](New-Item -ItemType Directory -Force -Path $subDir)
        $reqPath = Join-Path $subDir $reqName
        Write-Utf8Lf -Path $reqPath -Content $reqText
        $requestCount++
        if ($perChecker.ContainsKey($checkerKey)) { $perChecker[$checkerKey]++ } else { $perChecker[$checkerKey] = 1 }

        $worklist.Add((@(
                    (ConvertTo-CsvField $idPart), (ConvertTo-CsvField $checkerKey), (ConvertTo-CsvField $sev),
                    (ConvertTo-CsvField $file), (ConvertTo-CsvField $line),
                    (ConvertTo-CsvField ('requests/' + $safeChecker + '/' + $reqName)),
                    (ConvertTo-CsvField $guidePath), 'TODO'
                ) -join ','))
    }
    $ErrorActionPreference = 'Stop'

    # 체커별 _작업지침.md (요청 ≥1건 받은 폴더에만). 결정론: perChecker 카운트 + 가이드 메타 + 규약 섹션.
    foreach ($ck in ($perChecker.Keys | Sort-Object)) {
        $safeChecker = Get-SafeName $ck
        $meta = $perCheckerMeta[$ck]
        $mandate = if ($conventions.Contains($ck)) { [string]$conventions[$ck] } else { $generalNote }
        $instr = $folderTemplate.
            Replace('{{CHECKER_KEY}}', $ck).
            Replace('{{CHECKER_NAME}}', [string]$meta.Name).
            Replace('{{COUNT}}', [string]$perChecker[$ck]).
            Replace('{{SEVERITY}}', [string]$meta.Severity).
            Replace('{{COMMON_POLICY}}', $commonPolicy).
            Replace('{{CHECKER_MANDATE}}', $mandate)
        Write-Utf8Lf -Path (Join-Path (Join-Path $reqDir $safeChecker) '_작업지침.md') -Content $instr
    }

    Write-Utf8Lf -Path (Join-Path $Out 'worklist.csv') -Content (($worklist -join "`n") + "`n")
    Write-Utf8Lf -Path (Join-Path $Out 'unresolved.csv') -Content (($unresolved -join "`n") + "`n")

    Write-Host "=== prepare 요약 ==="
    Write-Host ("  트랙 필터   : {0}" -f ($trackSet -join ','))
    Write-Host ("  요청 생성수 : {0}" -f $requestCount)
    Write-Host ("  미해결수    : {0}" -f $unresolvedCount)
    Write-Host ("  트랙 제외수 : {0}" -f $trackFilteredCount)
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

# ---------------------------------------------------------------- dispatch
if (-not $Mode) { throw "첫 인자로 모드(prepare)를 지정하세요. 예: .\Run-Triage.ps1 prepare -Index ... " }
switch ($Mode) {
    'prepare' { Invoke-Prepare }
}
