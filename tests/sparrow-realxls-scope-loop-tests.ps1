#requires -Version 5.1
<#
    REAL-XLS SCOPE LOOP regression for Track C directory/file scope selection (team collaboration).

    Reconstructs the REAL project structure from the OSTES Sparrow xls into a MIRROR checkout at a
    DIFFERENT drive/root (a temp dir) — i.e. a teammate whose checkout path differs from the path baked
    into the shared xls — and drives many folder/file scope selections through SparrowXlsExport
    (--files-from + --root), asserting the cross-PC (Tier-2 relative-tail) matcher narrows exactly to the
    selection: correct per-folder counts, directory-boundary correctness (View vs ViewModel), single file,
    disjoint union, full selection, wrong-selection [범위 불일치] diagnostic, mixed real+ghost, idempotency,
    and no cross-folder leakage.

    The .xls is NOT in the repo (it lives in Downloads). SELF-SKIPS (not fails) when the .xls or .NET SDK
    is absent. Run: validate.ps1 -IncludeSparrowRealXlsScopeLoopTests   (or run this file directly).
#>
param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$XlsPath = (Join-Path $env:USERPROFILE "Downloads\issues_ktlee_GUI_15259_6899.xls")
)

$ErrorActionPreference = 'Stop'
$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if (-not $dotnet) { Write-Host "dotnet SDK not found; skipping scope-loop tests."; return }
if (-not (Test-Path -LiteralPath $XlsPath)) {
    Write-Host "Sparrow xls not found at '$XlsPath'; skipping scope-loop tests (the .xls is not in the repo)."
    return
}

$proj = Join-Path $RepositoryRoot "skills\sparrow-static-analysis\tools\_internal\SparrowXlsExport\SparrowXlsExport.csproj"
if (-not (Test-Path -LiteralPath $proj)) { throw "missing project: $proj" }
$exe = Join-Path $RepositoryRoot "skills\sparrow-static-analysis\tools\_internal\SparrowXlsExport\bin\Release\net8.0\SparrowXlsExport.exe"
Write-Host "  building SparrowXlsExport (Release)..."
$p = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
try { & $dotnet.Source build $proj -c Release -v q 2>&1 | Out-Null } finally { $ErrorActionPreference = $p }
if (-not (Test-Path -LiteralPath $exe)) { throw "build produced no exe: $exe" }

$W = Join-Path $env:TEMP ('scopeloop-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$mirror = Join-Path $W 'mirror'
New-Item -ItemType Directory -Force $mirror | Out-Null

function Invoke-Exe([string[]]$a) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $o = & $exe @a 2>&1 | Out-String } finally { $ErrorActionPreference = $prev }
    return $o
}

Invoke-Exe @($XlsPath, '--out', "$W\all") | Out-Null
$idx = Import-Csv "$W\all\index.csv" -Encoding UTF8
$totalAll = $idx.Count

function Get-Tail([string]$p) { if ($p -match 'release\\[^\\]+\\(.+)$') { return $matches[1] } else { return $null } }
$rows = @()
foreach ($r in $idx) {
    $tail = Get-Tail $r.'경로'
    if (-not $tail) { continue }
    $rows += [pscustomobject]@{ Tail = $tail; MirrorFull = (Join-Path $mirror $tail) }
}
if ($rows.Count -eq 0) { Write-Host "  xls has no usable '경로' tails; skipping."; Remove-Item -Recurse -Force $W -ErrorAction SilentlyContinue; return }
$rows | Select-Object -ExpandProperty MirrorFull -Unique | ForEach-Object {
    New-Item -ItemType Directory -Force (Split-Path $_ -Parent) | Out-Null
    Set-Content $_ "public class Mirror {}" -Encoding UTF8
}
$mirrorCount = ($rows.MirrorFull | Sort-Object -Unique).Count
$byTail = $rows | Group-Object Tail

function New-Manifest([string[]]$mirrorFiles) {
    $mp = Join-Path $W ('m-' + [guid]::NewGuid().ToString('N').Substring(0,6) + '.csv')
    $sb = New-Object System.Text.StringBuilder; [void]$sb.AppendLine('파일명')
    foreach ($f in ($mirrorFiles | Sort-Object -Unique)) { [void]$sb.AppendLine('"' + $f + '"') }
    [System.IO.File]::WriteAllText($mp, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    return $mp
}
function Files-UnderFolder([string]$pre) { ($rows | Where-Object { $_.Tail -eq $pre -or $_.Tail.StartsWith($pre + '\') } | Select-Object -ExpandProperty MirrorFull -Unique) }
function Expected-UnderFolder([string]$pre) { ($rows | Where-Object { $_.Tail -eq $pre -or $_.Tail.StartsWith($pre + '\') }).Count }

function Run-Scope([string]$manifest) {
    $out = Join-Path $W ('o-' + [guid]::NewGuid().ToString('N').Substring(0,6))
    $so = Invoke-Exe @($XlsPath, '--out', $out, '--files-from', $manifest, '--root', $mirror)
    $mism = ($so -match '범위 불일치')
    $n = (Get-ChildItem "$out\items" -Filter *.md -ErrorAction SilentlyContinue).Count
    $paths = @()
    if (Test-Path "$out\index.csv") { $paths = (Import-Csv "$out\index.csv" -Encoding UTF8).'경로' | Sort-Object -Unique }
    return [pscustomobject]@{ N = $n; Mismatch = $mism; Paths = $paths }
}

$fails = 0
function Check($name, $cond) { if ($cond) { Write-Host "  [ok]   $name" } else { Write-Host "  [FAIL] $name"; $script:fails++ } }

Write-Host ("  scope loop (real xls, mirror at different root): 총 {0} / 미러 {1}" -f $totalAll, $mirrorCount)

# 실제 폴더 선택 → 정확 건수 + 결과가 전부 범위 내
foreach ($folder in @('OSTES\Service', 'OSTES\Chart', 'Core\Log', 'AddSIM\CompDAScenario')) {
    $exp = Expected-UnderFolder $folder
    if ($exp -eq 0) { continue }   # 이 xls에 해당 폴더가 없으면 스킵(다른 xls 대비 방어)
    $r = Run-Scope (New-Manifest (Files-UnderFolder $folder))
    Check ("폴더 '{0}' → 기대 {1} / 실 {2}" -f $folder, $exp, $r.N) ($r.N -eq $exp)
    $outside = @($r.Paths | Where-Object { -not ((Get-Tail $_).StartsWith($folder)) })
    Check ("폴더 '{0}' 결과 전부 범위내 (범위밖 {1})" -f $folder, $outside.Count) ($outside.Count -eq 0)
}

# 경계: View 가 ViewModel 을 오매칭하면 안 됨(디렉토리 경계)
$expView = Expected-UnderFolder 'OSTES\View'
if ($expView -gt 0) {
    $rView = Run-Scope (New-Manifest (Files-UnderFolder 'OSTES\View'))
    Check ("경계: 'OSTES\View' → 기대 {0} / 실 {1}" -f $expView, $rView.N) ($rView.N -eq $expView)
    $leakVM = @($rView.Paths | Where-Object { (Get-Tail $_) -like 'OSTES\ViewModel\*' })
    Check ("경계: 'OSTES\View'가 'OSTES\ViewModel' 오매칭 안함 (누출 {0})" -f $leakVM.Count) ($leakVM.Count -eq 0)
}

# 단일 파일
$topFile = $byTail | Sort-Object Count -Descending | Select-Object -First 1
$rf = Run-Scope (New-Manifest @((Join-Path $mirror $topFile.Name)))
Check ("단일 파일 '{0}' → 기대 {1} / 실 {2}" -f $topFile.Name, $topFile.Count, $rf.N) ($rf.N -eq $topFile.Count)
Check ("단일 파일: 결과 경로 1개 (실 {0})" -f (@($rf.Paths).Count)) ((@($rf.Paths)).Count -eq 1)

# 서로 다른 두 폴더 합집합
if ((Expected-UnderFolder 'OSTES\Service') -gt 0 -and (Expected-UnderFolder 'Core') -gt 0) {
    $expSum = (Expected-UnderFolder 'OSTES\Service') + (Expected-UnderFolder 'Core')
    $rSum = Run-Scope (New-Manifest (@(Files-UnderFolder 'OSTES\Service') + @(Files-UnderFolder 'Core')))
    Check ("두 폴더(Service+Core) 합집합 → 기대 {0} / 실 {1}" -f $expSum, $rSum.N) ($rSum.N -eq $expSum)
}

# 전체 선택 → 전건
$rAll = Run-Scope (New-Manifest ($rows.MirrorFull | Sort-Object -Unique))
Check ("전체 파일 선택 → 기대 {0} / 실 {1}" -f $totalAll, $rAll.N) ($rAll.N -eq $totalAll)

# 틀린 선택 → 0 + [범위 불일치]
$fake = Join-Path $mirror 'Nonexistent\Ghost.cs'; New-Item -ItemType Directory -Force (Split-Path $fake -Parent) | Out-Null; Set-Content $fake "x" -Encoding UTF8
$rWrong = Run-Scope (New-Manifest @($fake))
Check "틀린 선택 → 0건" ($rWrong.N -eq 0)
Check "틀린 선택 → [범위 불일치] 예외 전시" ($rWrong.Mismatch)

# 혼합(실+가짜) → 실 파일만, 예외 없음
$rMix = Run-Scope (New-Manifest @((Join-Path $mirror $topFile.Name), $fake))
Check ("혼합(실+가짜) → 실 파일 {0}건만 (실 {1})" -f $topFile.Count, $rMix.N) ($rMix.N -eq $topFile.Count)
Check "혼합: 일부 매칭이므로 [범위 불일치] 없음" (-not $rMix.Mismatch)

# 멱등
$man = New-Manifest (Files-UnderFolder 'OSTES\Chart')
$a = Run-Scope $man; $b = Run-Scope $man
Check ("멱등: 'OSTES\Chart' 2회 동일 ({0}={1})" -f $a.N, $b.N) ($a.N -eq $b.N)

# 비선택 폴더 완전 배제
if ((Expected-UnderFolder 'OSTES\Service') -gt 0) {
    $rSvc = Run-Scope (New-Manifest (Files-UnderFolder 'OSTES\Service'))
    $leak = @($rSvc.Paths | Where-Object { (Get-Tail $_) -notlike 'OSTES\Service*' })
    Check ("비선택 폴더 완전 배제: Service 결과에 타폴더 {0}건" -f $leak.Count) ($leak.Count -eq 0)
}

Remove-Item -Recurse -Force $W -ErrorAction SilentlyContinue
if ($fails -eq 0) { Write-Host "Sparrow real-xls scope-loop tests passed." }
else { Write-Host ("Sparrow real-xls scope-loop tests FAILED ({0})." -f $fails); exit 1 }
