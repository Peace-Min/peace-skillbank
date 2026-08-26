<#
 build-offline-installer.ps1 - run on a machine that HAS the debuggers staged.
 Produces the one-call offline installer package that gets carried into the
 closed network:

   dmp-triage-offline-<date>\
     setup.cmd / setup.ps1        one call: verify -> unpack -> install -> self-test
     check.cmd / check.ps1        verify an existing install
     uninstall.cmd / uninstall.ps1
     README.txt                   what to do (Korean)
     SHA256SUMS.txt               integrity of the payload
     payload\debuggers.zip        cdb + dbgeng + SOS (single file), OR
     parts\debuggers.zip.001..NNN when -SplitMB is used (for git/GitHub limits)
     skill\                       SKILL.md, scripts\, references\, tools\, command\

 The package installs with NO admin rights, NO registry, NO service, NO PATH
 change and NO network access.
#>
[CmdletBinding()]
param(
    [string]$SkillDir,                   # source skill (default: parent of this tools\ folder)
    [string]$OutDir,                     # where to build (default: alongside the skill)
    [string]$BinDir,                     # staged debuggers (default: <SkillDir>in\debuggers)
    [int]$SplitMB = 0,                   # >0 splits the payload into NN MB parts (GitHub: use 90)
    [switch]$Zip                         # also produce a single .zip of the whole package
)

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $SkillDir) { $SkillDir = Split-Path -Parent $Here }
$SkillDir = (Resolve-Path -LiteralPath $SkillDir).Path

function Say([string]$m) { Write-Host "[build] $m" }
function Die([string]$m) { Write-Host "[build] ERROR: $m" -ForegroundColor Red; exit 2 }

# ---- locate the staged debuggers
$binDir = if ($BinDir) { $BinDir } else { Join-Path $SkillDir 'bin\debuggers' }
if (-not (Test-Path -LiteralPath (Join-Path $binDir 'cdb.exe'))) {
    Die "debuggers not staged at $binDir`n       Run tools\get-debuggers.ps1 first (needs internet, once)."
}

$stamp = Get-Date -Format 'yyyyMMdd'
if (-not $OutDir) { $OutDir = Join-Path (Split-Path -Parent $SkillDir) "dmp-triage-offline-$stamp" }
if (Test-Path -LiteralPath $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Say "building -> $OutDir"

# ---- 1. payload: zip the debuggers
$payloadDir = Join-Path $OutDir 'payload'
New-Item -ItemType Directory -Force -Path $payloadDir | Out-Null
$payloadZip = Join-Path $payloadDir 'debuggers.zip'
Say "compressing debuggers (this takes a minute)..."
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($binDir, $payloadZip,
    [System.IO.Compression.CompressionLevel]::Optimal, $false)
$payloadMB = [math]::Round((Get-Item -LiteralPath $payloadZip).Length / 1MB, 1)
Say "payload: $payloadMB MB"

# ---- 2. checksum (of the assembled payload, like the reference offline repos)
$hash = (Get-FileHash -LiteralPath $payloadZip -Algorithm SHA256).Hash.ToUpperInvariant()
Set-Content -Path (Join-Path $OutDir 'SHA256SUMS.txt') -Encoding ASCII -Value @(
    "# dmp-triage offline payload",
    "# verify:  certutil -hashfile payload\debuggers.zip SHA256",
    "$hash *payload/debuggers.zip"
)
Say "sha256: $($hash.Substring(0,32))..."

# ---- 3. optional split for git/GitHub 100MB limits
if ($SplitMB -gt 0) {
    $partsDir = Join-Path $OutDir 'parts'
    New-Item -ItemType Directory -Force -Path $partsDir | Out-Null
    $chunk = $SplitMB * 1MB
    $in = [System.IO.File]::OpenRead($payloadZip)
    try {
        $buf = New-Object byte[] 1048576
        $idx = 1; $written = 0; $out = $null
        while (($read = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            if ($null -eq $out) {
                $out = [System.IO.File]::Create((Join-Path $partsDir ('debuggers.zip.{0:D3}' -f $idx)))
                $written = 0
            }
            $out.Write($buf, 0, $read); $written += $read
            if ($written -ge $chunk) { $out.Dispose(); $out = $null; $idx++ }
        }
        if ($null -ne $out) { $out.Dispose() }
    } finally { $in.Dispose() }
    Remove-Item -LiteralPath $payloadZip -Force
    Remove-Item -LiteralPath $payloadDir -Force
    $n = (Get-ChildItem -LiteralPath $partsDir).Count
    Say "split into $n part(s) of ${SplitMB}MB (payload\ removed; setup.cmd reassembles)"
}

# ---- 4. installer scripts
$instSrc = Join-Path $SkillDir 'installer'
if (-not (Test-Path -LiteralPath $instSrc)) { $instSrc = Join-Path (Split-Path -Parent $Here) 'installer' }
if (-not (Test-Path -LiteralPath $instSrc)) { Die "installer\ templates not found next to the skill" }
Copy-Item -Path (Join-Path $instSrc '*') -Destination $OutDir -Force
Say "installer scripts copied"

# ---- 5. the skill itself
$skillOut = Join-Path $OutDir 'skill'
New-Item -ItemType Directory -Force -Path $skillOut | Out-Null
foreach ($item in @('SKILL.md', 'scripts', 'references', 'tools')) {
    $src = Join-Path $SkillDir $item
    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $skillOut -Recurse -Force }
}
# the slash-command alias, if the repo layout has one
$cmdOut = Join-Path $skillOut 'command'
New-Item -ItemType Directory -Force -Path $cmdOut | Out-Null
$cmdSrc = Join-Path (Split-Path -Parent (Split-Path -Parent $SkillDir)) 'commands\dmp-triage.md'
if (Test-Path -LiteralPath $cmdSrc) { Copy-Item -LiteralPath $cmdSrc -Destination $cmdOut -Force; Say "command alias included" }

# ---- 6. README for the person carrying the USB
Set-Content -Path (Join-Path $OutDir 'README.txt') -Encoding UTF8 -Value @"
dmp-triage - 폐쇄망 오프라인 설치 패키지
=========================================

이 폴더를 통째로 폐쇄망 PC에 복사한 뒤, setup.cmd 를 더블클릭하세요.
그게 전부입니다. 관리자 권한, 인터넷, 설치 프로그램 모두 필요 없습니다.

setup.cmd 가 하는 일
  1) parts\ 가 있으면 payload\debuggers.zip 으로 자동 재조립
  2) SHA256SUMS.txt 로 무결성 검증
  3) 디버거(cdb + dbgeng + SOS)를 스킬 폴더에 풀기
  4) Claude Code용 스킬 설치 (%USERPROFILE%\.claude\skills\dmp-triage)
     + 슬래시 커맨드 /dmp-triage 등록
  5) 자기 점검(cdb 로딩까지 실제 확인)

설치 후 사용
  powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.claude\skills\dmp-triage\scripts\dmp-triage.ps1" analyze -Dump C:\dumps\app.dmp

  Claude Code 안에서는 (한 번 재시작 후):  /dmp-triage C:\dumps\app.dmp

  결과 폴더의 report-slim.md 를 LLM에게 주세요. (약 8KB, 소형 모델도 처리 가능)
  전체 리포트는 report.md 입니다.

옵션
  setup.cmd -PortableOnly      설치하지 않고 이 폴더에서만 사용
  setup.cmd -InstallDir D:\x   다른 위치에 설치
  check.cmd                    설치 상태 점검
  uninstall.cmd                제거 (덤프/리포트는 건드리지 않음)

문제가 생기면
  - "cdb.exe not found" 가 보이면: 압축이 덜 풀린 것입니다. 패키지를 다시 복사하세요.
  - payload CORRUPT: USB 복사 중 손상입니다. 원본에서 다시 복사하세요.
  - 스킬이 Claude Code에 안 보이면: Claude Code를 재시작하세요.

payload SHA256: $hash
빌드: $stamp
"@

# ---- 7. optional single zip
if ($Zip) {
    $zipPath = "$OutDir.zip"
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    Say "zipping package..."
    [System.IO.Compression.ZipFile]::CreateFromDirectory($OutDir, $zipPath,
        [System.IO.Compression.CompressionLevel]::Optimal, $true)
    Say "zip: $zipPath ($([math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 1)) MB)"
}

$total = [math]::Round(((Get-ChildItem -LiteralPath $OutDir -Recurse -File | Measure-Object Length -Sum).Sum) / 1MB, 1)
Say "DONE. package: $OutDir ($total MB)"
Say "Carry it in, double-click setup.cmd."
