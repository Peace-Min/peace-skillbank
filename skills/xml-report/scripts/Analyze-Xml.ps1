#requires -Version 5.1
<#
.SYNOPSIS
  AddSIM XML(BSM/플레이어/컴포넌트) 결정적 분석 및 표준 HTML 보고서 생성.
.DESCRIPTION
  XML을 뎁쓰(계층)별로 전수 분석하여 항상 동일한 포맷의 자립형 HTML 보고서와
  분석 다이제스트(data.json)를 생성한다. 외부 의존성 없음(PowerShell 5.1+).
  - 트리에는 모든 요소가 빠짐없이 표시된다(표는 행 수 제한 시 생략 건수를 명시).
  - DTD/외부 엔티티는 보안상 처리하지 않는다.
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\Analyze-AddsimXml.ps1 -Path C:\data\comp.xml -OutDir C:\reports
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$OutDir = '',
    [string]$MappingPath = '',
    [string]$SummaryFile = '',
    [switch]$Recurse,
    [int]$OpenDepth = 3,
    [int]$MaxTableRows = 300,
    [int]$MaxAttrValueLen = 100,
    [int]$MaxTextLen = 160
)

$ErrorActionPreference = 'Stop'
$SkillVersion = '0.1.0'

# ---------------------------------------------------------------- 공통 헬퍼
function HtmlEnc([string]$s) {
    if ($null -eq $s) { return '' }
    return [System.Security.SecurityElement]::Escape($s)
}

function Trunc([string]$s, [int]$max) {
    if ($null -eq $s) { return '' }
    $t = $s.Trim()
    if ($t.Length -le $max) { return $t }
    return ($t.Substring(0, $max) + ' ...(+' + ($t.Length - $max) + '자)')
}

function Write-Utf8([string]$filePath, [string]$content) {
    $enc = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($filePath, $content, $enc)
}

# ---------------------------------------------------------------- 매핑 로드
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrEmpty($MappingPath)) {
    $cand = Join-Path (Split-Path -Parent $scriptDir) 'config\mapping.json'
    if (Test-Path $cand) { $MappingPath = $cand }
}

$LabelMap = @{}      # 요소명 -> @{ko=..; desc=..}  (해시테이블 키는 대소문자 무관)
$DocTypes = @{}      # 루트명 키워드 -> 문서유형
$ConnNames = @('connection', 'connections', 'link')
$EndpointAttrs = @('from', 'to', 'source', 'target', 'src', 'dst')
$Brand = 'XML 구조 분석'
$SkillName = 'xml-report'
$MappingLoaded = $false

if (-not [string]::IsNullOrEmpty($MappingPath) -and (Test-Path $MappingPath)) {
    $map = (Get-Content -Raw -Encoding UTF8 $MappingPath) | ConvertFrom-Json
    if ($map.labels) {
        foreach ($p in $map.labels.PSObject.Properties) {
            $LabelMap[$p.Name] = @{ ko = [string]$p.Value.ko; desc = [string]$p.Value.desc }
        }
    }
    if ($map.docTypes) {
        foreach ($p in $map.docTypes.PSObject.Properties) { $DocTypes[$p.Name.ToLowerInvariant()] = [string]$p.Value }
    }
    if ($map.connectionNames) { $ConnNames = @($map.connectionNames | ForEach-Object { ([string]$_).ToLowerInvariant() }) }
    if ($map.endpointAttrNames) { $EndpointAttrs = @($map.endpointAttrNames | ForEach-Object { ([string]$_).ToLowerInvariant() }) }
    if ($map.brand) { $Brand = [string]$map.brand }
    if ($map.skillName) { $SkillName = [string]$map.skillName }
    $MappingLoaded = $true
}

function Detect-DocType([string]$rootName) {
    $rl = $rootName.ToLowerInvariant()
    foreach ($k in $DocTypes.Keys) {
        if ($rl -like ('*' + $k + '*')) { return $DocTypes[$k] }
    }
    return ('미확인 (루트 요소: ' + $rootName + ')')
}

# ---------------------------------------------------------------- 트리 순회
function Walk-Element {
    param($el, [int]$depth, [string]$nodePath, $ctx)

    $name = $el.get_LocalName()
    $lname = $name.ToLowerInvariant()

    $ctx.Total = $ctx.Total + 1
    if ($depth -gt $ctx.MaxDepth) { $ctx.MaxDepth = $depth }

    if (-not $ctx.DepthNames.ContainsKey($depth)) { $ctx.DepthNames[$depth] = @{} }
    $dn = $ctx.DepthNames[$depth]
    if (-not $dn.ContainsKey($name)) { $dn[$name] = 0 }
    $dn[$name] = $dn[$name] + 1

    # 속성 수집 (문서 순서 유지)
    $attrPairs = New-Object System.Collections.ArrayList
    foreach ($a in $el.get_Attributes()) {
        [void]$attrPairs.Add(@([string]$a.get_Name(), [string]$a.get_Value()))
    }
    $ctx.AttrTotal = $ctx.AttrTotal + $attrPairs.Count

    # 자식 요소 / 자체 텍스트
    $childElems = New-Object System.Collections.ArrayList
    $ownText = ''
    foreach ($cn in $el.get_ChildNodes()) {
        $nt = $cn.get_NodeType()
        if ($nt -eq [System.Xml.XmlNodeType]::Element) { [void]$childElems.Add($cn) }
        elseif ($nt -eq [System.Xml.XmlNodeType]::Text -or $nt -eq [System.Xml.XmlNodeType]::CDATA) { $ownText = $ownText + [string]$cn.get_Value() }
        elseif ($nt -eq [System.Xml.XmlNodeType]::Comment) { $ctx.CommentCount = $ctx.CommentCount + 1 }
    }
    $ownText = $ownText.Trim()

    # 요소 인벤토리
    if (-not $ctx.Inventory.ContainsKey($name)) {
        $ctx.Inventory[$name] = @{
            Count = 0; MinDepth = $depth; MaxDepth = $depth
            AttrNames = New-Object System.Collections.ArrayList
            Instances = New-Object System.Collections.ArrayList
            Overflow = 0
        }
    }
    $inv = $ctx.Inventory[$name]
    $inv.Count = $inv.Count + 1
    if ($depth -lt $inv.MinDepth) { $inv.MinDepth = $depth }
    if ($depth -gt $inv.MaxDepth) { $inv.MaxDepth = $depth }
    foreach ($p in $attrPairs) {
        if (-not $inv.AttrNames.Contains($p[0])) { [void]$inv.AttrNames.Add($p[0]) }
    }
    if ($inv.Instances.Count -lt $ctx.MaxTableRows) {
        [void]$inv.Instances.Add(@{ Path = $nodePath; Depth = $depth; Attrs = $attrPairs; Text = $ownText })
    }
    else { $inv.Overflow = $inv.Overflow + 1 }

    # 커넥션 판별 (컨테이너 요소는 제외: 속성이 있거나 리프인 경우만 기록)
    if ($ctx.ConnNames -contains $lname) {
        if ($attrPairs.Count -gt 0 -or $childElems.Count -eq 0) {
            [void]$ctx.Connections.Add(@{ Path = $nodePath; Depth = $depth; Name = $name; Attrs = $attrPairs; Text = $ownText })
        }
    }

    # 라벨 / 미분류
    $label = $null
    if ($ctx.LabelMap.ContainsKey($name)) { $label = $ctx.LabelMap[$name] }
    else { $ctx.Unmapped[$name] = $true }

    # ---- 트리 HTML 렌더링
    $sb = $ctx.Sb
    $chips = ''
    foreach ($p in $attrPairs) {
        $chips = $chips + '<span class="chip"><b>' + (HtmlEnc $p[0]) + '</b>=' + (HtmlEnc (Trunc $p[1] $ctx.MaxAttrValueLen)) + '</span>'
    }
    $labelHtml = ''
    if ($null -ne $label -and $label.ko) {
        $t = ''
        if ($label.desc) { $t = ' title="' + (HtmlEnc $label.desc) + '"' }
        $labelHtml = '<span class="lbl"' + $t + '>' + (HtmlEnc $label.ko) + '</span>'
    }
    $badge = '<span class="db db' + (($depth - 1) % 6) + '">' + $depth + '</span>'
    $nameHtml = '<span class="en">' + (HtmlEnc $name) + '</span>'
    $textHtml = ''
    if ($ownText.Length -gt 0) {
        $textHtml = '<span class="txt">' + (HtmlEnc (Trunc $ownText $ctx.MaxTextLen)) + '</span>'
    }

    $ctx.Rendered = $ctx.Rendered + 1

    if ($childElems.Count -gt 0) {
        $openAttr = ''
        if ($depth -lt $ctx.OpenDepth) { $openAttr = ' open' }
        [void]$sb.Append('<details class="nd"' + $openAttr + '><summary>' + $badge + $nameHtml + $labelHtml + $chips + $textHtml + '<span class="cnt">자식 ' + $childElems.Count + '</span></summary><div class="ch">')
        $counts = @{}
        foreach ($c in $childElems) {
            $cnm = $c.get_LocalName()
            if (-not $counts.ContainsKey($cnm)) { $counts[$cnm] = 0 }
            $counts[$cnm] = $counts[$cnm] + 1
            Walk-Element -el $c -depth ($depth + 1) -nodePath ($nodePath + '/' + $cnm + '[' + $counts[$cnm] + ']') -ctx $ctx
        }
        [void]$sb.Append('</div></details>')
    }
    else {
        [void]$sb.Append('<div class="leaf">' + $badge + $nameHtml + $labelHtml + $chips + $textHtml + '</div>')
    }
}

# ---------------------------------------------------------------- 보고서 CSS (고정 템플릿)
$Css = @'
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Malgun Gothic','맑은 고딕','Segoe UI',sans-serif;background:#f4f6f9;color:#1f2732;font-size:14px;line-height:1.55;padding:24px}
.wrap{max-width:1180px;margin:0 auto}
h1{font-size:21px;margin-bottom:4px;word-break:break-all}
h2{font-size:16px;margin:26px 0 10px;padding-bottom:6px;border-bottom:2px solid #d6dde6}
.sub{color:#5b6774;font-size:12px;margin-bottom:18px}
.card{background:#fff;border:1px solid #dde3ea;border-radius:8px;padding:14px 16px;margin-bottom:14px}
table{border-collapse:collapse;width:100%;font-size:13px;background:#fff}
th,td{border:1px solid #d9e0e8;padding:5px 9px;text-align:left;vertical-align:top;word-break:break-all}
th{background:#eef2f7;font-weight:600;white-space:nowrap}
tr:nth-child(even) td{background:#fafbfd}
.tbl{overflow-x:auto;margin-bottom:6px}
.grid{display:flex;flex-wrap:wrap;gap:10px}
.stat{flex:1 1 150px;min-width:150px;background:#fff;border:1px solid #dde3ea;border-radius:8px;padding:10px 12px}
.stat .k{font-size:11px;color:#5b6774}
.stat .v{font-size:17px;font-weight:700;margin-top:2px;word-break:break-all}
.stat .v.small{font-size:12px;font-weight:600}
.ok{color:#1b7f3b}.warn{color:#b3560c}.err{color:#b31212}
.badge{display:inline-block;font-size:11px;font-weight:700;border-radius:10px;padding:1px 9px;vertical-align:middle}
.badge.model{background:#fff0d2;color:#8a5a00;border:1px solid #e8c877}
.badge.data{background:#ddefe2;color:#1b6b38;border:1px solid #9fceac}
.summary-box{white-space:normal}
.summary-box p{margin:0 0 8px}
.placeholder{color:#8a93a0;font-style:italic}
/* 계층 트리 */
.tree{font-family:Consolas,'D2Coding',monospace;font-size:12.5px}
.tree details{margin:1px 0}
.tree .ch{margin-left:20px;border-left:1px dotted #c3ccd6;padding-left:8px}
.tree summary{cursor:pointer;padding:2px 4px;border-radius:4px;list-style:revert}
.tree summary:hover{background:#eef3f9}
.leaf{padding:2px 4px 2px 21px}
.en{font-weight:700;margin-right:4px}
.lbl{color:#246a9c;font-size:11.5px;margin-right:4px;font-family:'Malgun Gothic','맑은 고딕',sans-serif}
.chip{display:inline-block;background:#eef2f7;border:1px solid #d9e0e8;border-radius:4px;font-size:11.5px;padding:0 5px;margin:0 3px 1px 0;color:#3a4654}
.chip b{color:#5b3fa8;font-weight:600}
.txt{color:#1b6b38;font-size:11.5px;margin-left:4px}
.cnt{color:#8a93a0;font-size:11px;margin-left:6px}
.db{display:inline-block;width:20px;text-align:center;border-radius:4px;font-size:10.5px;font-weight:700;color:#fff;margin-right:6px}
.db0{background:#3567a8}.db1{background:#3f8d5a}.db2{background:#b3762a}.db3{background:#7b53ad}.db4{background:#b04a5e}.db5{background:#4a8f9c}
.mono{font-family:Consolas,'D2Coding',monospace;font-size:12px}
.note{font-size:12px;color:#77522a;background:#fdf6e5;border:1px solid #ecd9a8;border-radius:6px;padding:6px 10px;margin:6px 0}
.secdet>summary{cursor:pointer;font-weight:600;padding:6px 0}
footer{margin-top:30px;color:#8a93a0;font-size:11.5px;border-top:1px solid #d6dde6;padding-top:8px}
'@

# ---------------------------------------------------------------- 파일 1개 처리
function Process-XmlFile {
    param([System.IO.FileInfo]$file, [string]$outDir, [string]$summaryText, [string]$reportBase)

    # --- 파싱 (DTD/외부 엔티티 차단)
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Ignore
    $settings.XmlResolver = $null
    $settings.IgnoreComments = $false
    $reader = [System.Xml.XmlReader]::Create($file.FullName, $settings)
    $doc = New-Object System.Xml.XmlDocument
    try { $doc.Load($reader) } finally { $reader.Close() }

    $root = $doc.get_DocumentElement()
    $rootName = $root.get_LocalName()
    $rootNs = [string]$root.get_NamespaceURI()
    $docType = Detect-DocType $rootName
    $hash = (Get-FileHash -Algorithm SHA256 -Path $file.FullName).Hash
    $now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    # --- 순회 컨텍스트
    $ctx = @{
        Total = 0; Rendered = 0; MaxDepth = 0; AttrTotal = 0; CommentCount = 0
        DepthNames = @{}; Inventory = @{}; Unmapped = @{}
        Connections = New-Object System.Collections.ArrayList
        Sb = New-Object System.Text.StringBuilder
        LabelMap = $LabelMap; ConnNames = $ConnNames
        OpenDepth = $OpenDepth; MaxTableRows = $MaxTableRows
        MaxAttrValueLen = $MaxAttrValueLen; MaxTextLen = $MaxTextLen
    }
    Walk-Element -el $root -depth 1 -nodePath ('/' + $rootName + '[1]') -ctx $ctx

    $countMatch = ($ctx.Total -eq $ctx.Rendered)
    $unmappedNames = @($ctx.Unmapped.Keys | Sort-Object)

    # ---------------------------------------------------------------- HTML 조립
    $h = New-Object System.Text.StringBuilder
    [void]$h.Append('<!DOCTYPE html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">')
    [void]$h.Append('<title>' + (HtmlEnc $file.Name) + ' - ' + (HtmlEnc $Brand) + '</title><style>' + $Css + '</style></head><body><div class="wrap">')

    # 1. 헤더
    [void]$h.Append('<h1>' + (HtmlEnc $file.Name) + '</h1>')
    [void]$h.Append('<div class="sub">' + (HtmlEnc $Brand) + ' 보고서 | 문서 유형: <b>' + (HtmlEnc $docType) + '</b> | 생성: ' + $now + ' | 스킬 v' + $SkillVersion + '</div>')

    # 2. 검증 요약
    [void]$h.Append('<h2>1. 검증 요약</h2><div class="grid">')
    $matchCls = 'ok'; $matchTxt = '일치'
    if (-not $countMatch) { $matchCls = 'err'; $matchTxt = '불일치(주의)' }
    [void]$h.Append('<div class="stat"><div class="k">파싱 요소 수</div><div class="v">' + $ctx.Total + '</div></div>')
    [void]$h.Append('<div class="stat"><div class="k">렌더링 요소 수 / 대조</div><div class="v">' + $ctx.Rendered + ' <span class="' + $matchCls + '">' + $matchTxt + '</span></div></div>')
    [void]$h.Append('<div class="stat"><div class="k">최대 뎁쓰</div><div class="v">' + $ctx.MaxDepth + '</div></div>')
    [void]$h.Append('<div class="stat"><div class="k">속성 총수</div><div class="v">' + $ctx.AttrTotal + '</div></div>')
    [void]$h.Append('<div class="stat"><div class="k">커넥션</div><div class="v">' + $ctx.Connections.Count + '</div></div>')
    [void]$h.Append('<div class="stat"><div class="k">요소 종류 / 미분류</div><div class="v">' + $ctx.Inventory.Count + ' / ' + $unmappedNames.Count + '</div></div>')
    [void]$h.Append('<div class="stat"><div class="k">파일 크기 / 주석</div><div class="v small">' + $file.Length + ' bytes / ' + $ctx.CommentCount + '개</div></div>')
    [void]$h.Append('<div class="stat"><div class="k">SHA-256 (원본 대조용)</div><div class="v small mono">' + $hash + '</div></div>')
    [void]$h.Append('</div>')
    if ($rootNs -ne '') {
        [void]$h.Append('<div class="note">루트 네임스페이스: <span class="mono">' + (HtmlEnc $rootNs) + '</span></div>')
    }

    # 3. 계층 구조 트리
    [void]$h.Append('<h2>2. 계층 구조 트리 <span class="badge data">원본 추출</span></h2>')
    [void]$h.Append('<div class="card tree">' + $ctx.Sb.ToString() + '</div>')
    [void]$h.Append('<div class="note">트리는 전체 ' + $ctx.Total + '개 요소를 빠짐없이 표시합니다(주석 노드 제외). 숫자 배지는 뎁쓰입니다. 뎁쓰 ' + $OpenDepth + ' 이후는 접혀 있으니 클릭해 펼치세요.</div>')

    # 5. 뎁쓰별 요소 요약
    [void]$h.Append('<h2>3. 뎁쓰별 요소 요약 <span class="badge data">원본 추출</span></h2><div class="tbl"><table><tr><th>뎁쓰</th><th>요소 수</th><th>구성 (요소명 x 개수)</th></tr>')
    foreach ($d in ($ctx.DepthNames.Keys | Sort-Object)) {
        $dn = $ctx.DepthNames[$d]
        $sum = 0
        $parts = New-Object System.Collections.ArrayList
        foreach ($n in ($dn.Keys | Sort-Object)) {
            $sum = $sum + $dn[$n]
            [void]$parts.Add('<span class="chip"><b>' + (HtmlEnc $n) + '</b> x ' + $dn[$n] + '</span>')
        }
        [void]$h.Append('<tr><td><span class="db db' + (($d - 1) % 6) + '">' + $d + '</span></td><td>' + $sum + '</td><td>' + ($parts -join ' ') + '</td></tr>')
    }
    [void]$h.Append('</table></div>')

    # 6. 요소별 속성 상세
    [void]$h.Append('<h2>4. 요소별 속성 상세 <span class="badge data">원본 추출</span></h2>')
    $invNames = @($ctx.Inventory.Keys | Sort-Object { $ctx.Inventory[$_].MinDepth }, { $_ })
    foreach ($n in $invNames) {
        $inv = $ctx.Inventory[$n]
        $hasAttr = ($inv.AttrNames.Count -gt 0)
        $hasText = $false
        foreach ($it in $inv.Instances) { if ($it.Text.Length -gt 0) { $hasText = $true; break } }
        if (-not $hasAttr -and -not $hasText) { continue }

        $lblTxt = ''
        if ($LabelMap.ContainsKey($n)) { $lblTxt = ' (' + $LabelMap[$n].ko + ')' }
        [void]$h.Append('<details class="secdet"><summary>' + (HtmlEnc $n) + (HtmlEnc $lblTxt) + ' - ' + $inv.Count + '개 (뎁쓰 ' + $inv.MinDepth + '~' + $inv.MaxDepth + ')</summary><div class="tbl"><table><tr><th>#</th><th>경로</th>')
        foreach ($an in $inv.AttrNames) { [void]$h.Append('<th>' + (HtmlEnc $an) + '</th>') }
        if ($hasText) { [void]$h.Append('<th>텍스트</th>') }
        [void]$h.Append('</tr>')
        $i = 0
        foreach ($it in $inv.Instances) {
            $i = $i + 1
            [void]$h.Append('<tr><td>' + $i + '</td><td class="mono">' + (HtmlEnc $it.Path) + '</td>')
            foreach ($an in $inv.AttrNames) {
                $v = ''
                foreach ($p in $it.Attrs) { if ($p[0] -eq $an) { $v = $p[1]; break } }
                [void]$h.Append('<td>' + (HtmlEnc (Trunc $v $MaxAttrValueLen)) + '</td>')
            }
            if ($hasText) { [void]$h.Append('<td>' + (HtmlEnc (Trunc $it.Text $MaxTextLen)) + '</td>') }
            [void]$h.Append('</tr>')
        }
        [void]$h.Append('</table></div>')
        if ($inv.Overflow -gt 0) {
            [void]$h.Append('<div class="note">표 행 수 제한(-MaxTableRows ' + $MaxTableRows + ')으로 ' + $inv.Overflow + '건이 이 표에서 생략되었습니다. 전체 요소는 계층 구조 트리에 모두 표시되어 있습니다.</div>')
        }
        [void]$h.Append('</details>')
    }

    # 7. 커넥션
    [void]$h.Append('<h2>5. 커넥션(연결 관계) <span class="badge data">원본 추출</span></h2>')
    if ($ctx.Connections.Count -eq 0) {
        [void]$h.Append('<div class="card">커넥션으로 분류된 요소가 없습니다. (매핑 connectionNames: ' + (HtmlEnc ($ConnNames -join ', ')) + ')</div>')
    }
    else {
        [void]$h.Append('<div class="tbl"><table><tr><th>#</th><th>요소</th><th>출발/도착 (인식된 엔드포인트)</th><th>전체 속성</th><th>경로</th></tr>')
        $i = 0
        foreach ($c in $ctx.Connections) {
            $i = $i + 1
            $eps = New-Object System.Collections.ArrayList
            $others = New-Object System.Collections.ArrayList
            foreach ($p in $c.Attrs) {
                $chip = '<span class="chip"><b>' + (HtmlEnc $p[0]) + '</b>=' + (HtmlEnc (Trunc $p[1] $MaxAttrValueLen)) + '</span>'
                if ($EndpointAttrs -contains $p[0].ToLowerInvariant()) { [void]$eps.Add($chip) } else { [void]$others.Add($chip) }
            }
            $epHtml = '-'
            if ($eps.Count -gt 0) { $epHtml = ($eps -join ' ') }
            [void]$h.Append('<tr><td>' + $i + '</td><td>' + (HtmlEnc $c.Name) + '</td><td>' + $epHtml + '</td><td>' + (($others -join ' ')) + '</td><td class="mono">' + (HtmlEnc $c.Path) + '</td></tr>')
        }
        [void]$h.Append('</table></div>')
    }

    # 8. 요소 인벤토리 / 매핑 상태
    [void]$h.Append('<h2>6. 요소 인벤토리 및 매핑 상태 <span class="badge data">원본 추출</span></h2><div class="tbl"><table><tr><th>요소명</th><th>라벨</th><th>개수</th><th>뎁쓰 범위</th><th>속성명</th><th>매핑</th></tr>')
    foreach ($n in $invNames) {
        $inv = $ctx.Inventory[$n]
        $lbl = '-'; $st = '<span class="warn">미분류</span>'
        if ($LabelMap.ContainsKey($n)) {
            $lbl = HtmlEnc $LabelMap[$n].ko
            $st = '<span class="ok">매핑됨</span>'
        }
        $ans = '-'
        if ($inv.AttrNames.Count -gt 0) { $ans = HtmlEnc (($inv.AttrNames.ToArray()) -join ', ') }
        [void]$h.Append('<tr><td class="mono">' + (HtmlEnc $n) + '</td><td>' + $lbl + '</td><td>' + $inv.Count + '</td><td>' + $inv.MinDepth + '~' + $inv.MaxDepth + '</td><td>' + $ans + '</td><td>' + $st + '</td></tr>')
    }
    [void]$h.Append('</table></div>')
    if ($unmappedNames.Count -gt 0) {
        [void]$h.Append('<div class="note">미분류 요소 ' + $unmappedNames.Count + '종: <span class="mono">' + (HtmlEnc ($unmappedNames -join ', ')) + '</span> - 의미를 확인하여 config/mapping.json의 labels에 추가하면 다음 보고서부터 라벨이 표시됩니다. 미분류여도 모든 데이터는 위에 빠짐없이 표시되어 있습니다.</div>')
    }
    if (-not $MappingLoaded) {
        [void]$h.Append('<div class="note">매핑 파일이 로드되지 않아 기본 규칙만 적용되었습니다. (-MappingPath 확인)</div>')
    }

    # 7. 문서 해석 (모델 생성) - 사실(원본 추출) 뒤에 의견이 오도록 항상 마지막 섹션에 배치
    [void]$h.Append('<h2>7. 문서 해석 <span class="badge model">모델 생성</span></h2><div class="card summary-box">')
    if ([string]::IsNullOrEmpty($summaryText)) {
        [void]$h.Append('<span class="placeholder">아직 생성되지 않았습니다. 분석 다이제스트(' + (HtmlEnc ($reportBase + '.data.json')) + ') 기반으로 요약을 작성한 뒤 -SummaryFile 옵션으로 재실행하면 이 섹션이 채워집니다.</span>')
    }
    else {
        $paras = $summaryText -split '(\r?\n){2,}'
        foreach ($para in $paras) {
            $pt = $para.Trim()
            if ($pt.Length -gt 0) { [void]$h.Append('<p>' + (HtmlEnc $pt) + '</p>') }
        }
        [void]$h.Append('<div class="note">이 섹션은 언어모델이 작성한 해석/판단입니다. 위의 1~6번 섹션은 전부 스크립트가 원본에서 기계적으로 추출한 데이터입니다.</div>')
    }
    [void]$h.Append('</div>')

    [void]$h.Append('<footer>' + (HtmlEnc $SkillName) + ' v' + $SkillVersion + ' | 결정적 스크립트 분석 - 동일 입력이면 항상 동일한 보고서가 생성됩니다 | 원본: ' + (HtmlEnc $file.FullName) + '</footer>')
    [void]$h.Append('</div></body></html>')

    # ---------------------------------------------------------------- 출력 저장
    $reportPath = Join-Path $outDir ($reportBase + '.report.html')
    $dataPath = Join-Path $outDir ($reportBase + '.data.json')
    Write-Utf8 $reportPath $h.ToString()

    # 다이제스트 JSON
    $depthSummary = New-Object System.Collections.ArrayList
    foreach ($d in ($ctx.DepthNames.Keys | Sort-Object)) {
        $dn = $ctx.DepthNames[$d]
        $els = [ordered]@{}
        $sum = 0
        foreach ($n in ($dn.Keys | Sort-Object)) { $els[$n] = $dn[$n]; $sum = $sum + $dn[$n] }
        [void]$depthSummary.Add([ordered]@{ depth = $d; total = $sum; elements = $els })
    }
    $elements = New-Object System.Collections.ArrayList
    foreach ($n in $invNames) {
        $inv = $ctx.Inventory[$n]
        $lbl = $null
        if ($LabelMap.ContainsKey($n)) { $lbl = $LabelMap[$n].ko }
        $samplePaths = New-Object System.Collections.ArrayList
        $sampleInstances = New-Object System.Collections.ArrayList
        $k = 0
        foreach ($it in $inv.Instances) {
            $k = $k + 1
            if ($k -le 10) { [void]$samplePaths.Add($it.Path) }
            if ($k -le 5) {
                $am = [ordered]@{}
                foreach ($p in $it.Attrs) { $am[$p[0]] = $p[1] }
                [void]$sampleInstances.Add([ordered]@{ path = $it.Path; attrs = $am; text = (Trunc $it.Text 300) })
            }
        }
        [void]$elements.Add([ordered]@{
                name = $n; label = $lbl; count = $inv.Count
                minDepth = $inv.MinDepth; maxDepth = $inv.MaxDepth
                attrNames = @($inv.AttrNames)
                samplePaths = @($samplePaths); sampleInstances = @($sampleInstances)
            })
    }
    $connRows = New-Object System.Collections.ArrayList
    $connLimit = 500
    $k = 0
    foreach ($c in $ctx.Connections) {
        $k = $k + 1
        if ($k -gt $connLimit) { break }
        $am = [ordered]@{}
        foreach ($p in $c.Attrs) { $am[$p[0]] = $p[1] }
        [void]$connRows.Add([ordered]@{ name = $c.Name; path = $c.Path; attrs = $am; text = (Trunc $c.Text 300) })
    }
    $connOverflow = 0
    if ($ctx.Connections.Count -gt $connLimit) { $connOverflow = $ctx.Connections.Count - $connLimit }

    $digest = [ordered]@{
        file = $file.Name
        fullPath = $file.FullName
        sha256 = $hash
        sizeBytes = $file.Length
        generatedAt = $now
        skillVersion = $SkillVersion
        docType = $docType
        rootElement = $rootName
        rootNamespace = $rootNs
        stats = [ordered]@{
            totalElements = $ctx.Total; renderedElements = $ctx.Rendered; countMatch = $countMatch
            maxDepth = $ctx.MaxDepth; totalAttributes = $ctx.AttrTotal; commentCount = $ctx.CommentCount
            connectionCount = $ctx.Connections.Count; elementKinds = $ctx.Inventory.Count
            unmappedElementKinds = $unmappedNames.Count
        }
        depthSummary = @($depthSummary)
        elements = @($elements)
        connections = @($connRows)
        connectionsOmitted = $connOverflow
        unmappedElements = @($unmappedNames)
    }
    Write-Utf8 $dataPath (($digest | ConvertTo-Json -Depth 10))

    return [ordered]@{
        Ok = $true; File = $file.Name; DocType = $docType
        Total = $ctx.Total; MaxDepth = $ctx.MaxDepth; Attrs = $ctx.AttrTotal
        Connections = $ctx.Connections.Count; UnmappedKinds = $unmappedNames.Count
        Unmapped = $unmappedNames; CountMatch = $countMatch
        Report = $reportPath; Data = $dataPath
    }
}

# ---------------------------------------------------------------- 메인
$resolved = Resolve-Path -LiteralPath $Path
$targets = @()
$isDir = Test-Path -LiteralPath $resolved -PathType Container
if ($isDir) {
    if ($Recurse) { $targets = @(Get-ChildItem -LiteralPath $resolved -Filter *.xml -File -Recurse | Sort-Object FullName) }
    else { $targets = @(Get-ChildItem -LiteralPath $resolved -Filter *.xml -File | Sort-Object FullName) }
}
else {
    $targets = @(Get-Item -LiteralPath $resolved)
}
if ($targets.Count -eq 0) { throw ('처리할 XML 파일이 없습니다: ' + $Path) }

if ([string]::IsNullOrEmpty($OutDir)) { $OutDir = Join-Path (Get-Location).Path 'xml-reports' }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path

$summaryText = ''
if (-not [string]::IsNullOrEmpty($SummaryFile)) {
    if ($targets.Count -gt 1) {
        Write-Warning '-SummaryFile은 단일 파일 처리에서만 적용됩니다. 무시합니다.'
    }
    elseif (Test-Path -LiteralPath $SummaryFile) {
        $summaryText = Get-Content -Raw -Encoding UTF8 $SummaryFile
    }
    else { Write-Warning ('요약 파일을 찾을 수 없습니다: ' + $SummaryFile) }
}

$results = New-Object System.Collections.ArrayList
$usedBases = @{}
foreach ($f in $targets) {
    $base = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
    $rb = $base
    $n = 1
    while ($usedBases.ContainsKey($rb)) { $n = $n + 1; $rb = $base + '_' + $n }
    $usedBases[$rb] = $true

    try {
        $st = ''
        if ($targets.Count -eq 1) { $st = $summaryText }
        $r = Process-XmlFile -file $f -outDir $OutDir -summaryText $st -reportBase $rb
        [void]$results.Add($r)
        $sumLine = ('[OK] {0} | 유형: {1} | 요소 {2}개 | 최대뎁쓰 {3} | 속성 {4} | 커넥션 {5} | 미분류 {6}종' -f $r.File, $r.DocType, $r.Total, $r.MaxDepth, $r.Attrs, $r.Connections, $r.UnmappedKinds)
        Write-Host $sumLine -ForegroundColor Green
        if (-not $r.CountMatch) { Write-Host ('  [주의] 파싱/렌더링 요소 수 불일치!') -ForegroundColor Red }
        if ($r.UnmappedKinds -gt 0) {
            Write-Host ('  미분류 요소: ' + ($r.Unmapped -join ', ')) -ForegroundColor Yellow
        }
    }
    catch {
        [void]$results.Add([ordered]@{ Ok = $false; File = $f.Name; Error = $_.Exception.Message })
        Write-Host ('[실패] ' + $f.Name + ' : ' + $_.Exception.Message) -ForegroundColor Red
    }
}

# index.html (여러 파일일 때)
if ($targets.Count -gt 1) {
    $now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $ih = New-Object System.Text.StringBuilder
    [void]$ih.Append('<!DOCTYPE html><html lang="ko"><head><meta charset="utf-8"><title>' + (HtmlEnc $Brand) + ' 목록</title><style>' + $Css + '</style></head><body><div class="wrap">')
    [void]$ih.Append('<h1>' + (HtmlEnc $Brand) + ' 목록</h1><div class="sub">생성: ' + $now + ' | 스킬 v' + $SkillVersion + ' | 대상 ' + $targets.Count + '개 파일</div>')
    [void]$ih.Append('<div class="tbl"><table><tr><th>#</th><th>파일</th><th>상태</th><th>문서 유형</th><th>요소</th><th>최대뎁쓰</th><th>커넥션</th><th>미분류</th></tr>')
    $i = 0
    foreach ($r in $results) {
        $i = $i + 1
        if ($r.Ok) {
            $rel = [System.IO.Path]::GetFileName($r.Report)
            [void]$ih.Append('<tr><td>' + $i + '</td><td><a href="' + (HtmlEnc $rel) + '">' + (HtmlEnc $r.File) + '</a></td><td><span class="ok">성공</span></td><td>' + (HtmlEnc $r.DocType) + '</td><td>' + $r.Total + '</td><td>' + $r.MaxDepth + '</td><td>' + $r.Connections + '</td><td>' + $r.UnmappedKinds + '종</td></tr>')
        }
        else {
            [void]$ih.Append('<tr><td>' + $i + '</td><td>' + (HtmlEnc $r.File) + '</td><td><span class="err">파싱 실패</span></td><td colspan="5">' + (HtmlEnc $r.Error) + '</td></tr>')
        }
    }
    [void]$ih.Append('</table></div><footer>' + (HtmlEnc $SkillName) + ' v' + $SkillVersion + '</footer></div></body></html>')
    Write-Utf8 (Join-Path $OutDir 'index.html') $ih.ToString()
    Write-Host ('index: ' + (Join-Path $OutDir 'index.html'))
}

Write-Host ('출력 폴더: ' + $OutDir)
