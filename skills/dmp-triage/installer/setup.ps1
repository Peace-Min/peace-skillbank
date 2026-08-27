<#
 dmp-triage offline installer  (no admin rights, no network, no MSI)
 ---------------------------------------------------------------------------
 One call does everything an air-gapped machine needs:
   1) reassemble the split payload (parts\*.001,.002,... -> payload zip)
   2) verify SHA256 against SHA256SUMS.txt
   3) unpack the debuggers (cdb + dbgeng + SOS) into the skill
   4) install the skill for Claude Code (~\.claude\skills + ~\.claude\commands)
   5) self-test: run the CLI end to end and prove cdb loads
 Everything is a plain file copy. Nothing is written outside the user profile
 and this folder; no registry, no service, no PATH change, no elevation.
#>
[CmdletBinding()]
param(
    [string]$InstallDir,                 # default: %USERPROFILE%\.claude\skills\dmp-triage
    [switch]$PortableOnly,               # only unpack here; do not install into ~\.claude
    [switch]$SkipVerify,                 # skip SHA256 (use only if SHA256SUMS.txt is absent)
    [switch]$Force,                      # overwrite an existing install without asking
    [switch]$NoRegisterEnv               # skip the DMP_TRIAGE_HOME / DMP_TRIAGE_CDB user variables
)

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Status = 0

function Say([string]$m)  { Write-Host "[setup] $m" }
function Warn([string]$m) { Write-Host "[setup] WARNING: $m" -ForegroundColor Yellow; $script:Status = 1 }
function Die([string]$m)  { Write-Host "[setup] ERROR: $m" -ForegroundColor Red; exit 2 }
function Step([string]$m) { Write-Host ""; Write-Host "== $m" -ForegroundColor Cyan }

Write-Host ""
Write-Host "  dmp-triage - offline installer" -ForegroundColor White
Write-Host "  Windows process dump (.dmp) triage for air-gapped machines"
Write-Host "  ------------------------------------------------------------"

# ---------------------------------------------------------------- 0. sanity
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Die "Windows PowerShell 5.1+ is required (found $($PSVersionTable.PSVersion))."
}
$payloadDir = Join-Path $Here 'payload'
$partsDir   = Join-Path $Here 'parts'
$sumsFile   = Join-Path $Here 'SHA256SUMS.txt'
$payloadZip = Join-Path $payloadDir 'debuggers.zip'

# ------------------------------------------------------- 1. reassemble parts
Step "1/6  Payload"
if (-not (Test-Path -LiteralPath $payloadZip)) {
    if (Test-Path -LiteralPath $partsDir) {
        $parts = Get-ChildItem -LiteralPath $partsDir -Filter 'debuggers.zip.*' | Sort-Object Name
        if ($parts.Count -eq 0) { Die "no payload: neither payload\debuggers.zip nor parts\debuggers.zip.NNN found." }
        Say "reassembling $($parts.Count) part(s) -> payload\debuggers.zip"
        New-Item -ItemType Directory -Force -Path $payloadDir | Out-Null
        $out = [System.IO.File]::Create($payloadZip)
        try {
            foreach ($p in $parts) {
                $in = [System.IO.File]::OpenRead($p.FullName)
                try { $in.CopyTo($out) } finally { $in.Dispose() }
            }
        } finally { $out.Dispose() }
    } else {
        Die "no payload: neither payload\debuggers.zip nor parts\ found next to setup.ps1."
    }
} else {
    Say "payload\debuggers.zip present"
}
$zipSizeMB = [math]::Round((Get-Item -LiteralPath $payloadZip).Length / 1MB, 1)
Say "payload size: $zipSizeMB MB"

# ------------------------------------------------------------- 2. verify hash
Step "2/6  Integrity"
if ($SkipVerify) {
    Warn "SHA256 verification skipped by -SkipVerify"
} elseif (-not (Test-Path -LiteralPath $sumsFile)) {
    Warn "SHA256SUMS.txt not found - cannot verify payload integrity"
} else {
    $expected = $null
    foreach ($line in (Get-Content -LiteralPath $sumsFile)) {
        if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$') {
            # capture BEFORE any further -match: that operator overwrites $Matches
            $sumHash = $Matches[1]
            $sumName = ($Matches[2] -replace '/', '\')
            if ($sumName.EndsWith('debuggers.zip')) { $expected = $sumHash.ToUpperInvariant() }
        }
    }
    if (-not $expected) { Warn "no debuggers.zip entry inside SHA256SUMS.txt" }
    else {
        Say "computing SHA256 (this takes a few seconds)..."
        $actual = (Get-FileHash -LiteralPath $payloadZip -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actual -ne $expected) {
            Die "payload CORRUPT.`n         expected $expected`n         actual   $actual`n         Re-copy the package from the source media."
        }
        Say "SHA256 OK ($($actual.Substring(0,16))...)"
    }
}

# ----------------------------------------------------------- 3. choose target
Step "3/6  Install location"
if ($PortableOnly) {
    $target = $Here
    Say "portable mode: staying in $target"
} else {
    if (-not $InstallDir) { $InstallDir = Join-Path $env:USERPROFILE '.claude\skills\dmp-triage' }
    $target = $InstallDir
    if ((Test-Path -LiteralPath $target) -and -not $Force) {
        $existing = Get-ChildItem -LiteralPath $target -File -Recurse -ErrorAction SilentlyContinue
        if ($existing) { Say "existing install found at $target - it will be updated (files overwritten)" }
    }
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Say "target: $target"
}

# --------------------------------------------- 4. unpack + install skill files
Step "4/6  Installing"
$binDir = Join-Path $target 'bin\debuggers'
if (Test-Path -LiteralPath $binDir) { Remove-Item -LiteralPath $binDir -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $binDir | Out-Null
Say "unpacking debuggers -> bin\debuggers"
try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    [System.IO.Compression.ZipFile]::ExtractToDirectory($payloadZip, $binDir)
} catch {
    Expand-Archive -LiteralPath $payloadZip -DestinationPath $binDir -Force
}
$cdb = Join-Path $binDir 'cdb.exe'
if (-not (Test-Path -LiteralPath $cdb)) {
    $found = Get-ChildItem -LiteralPath $binDir -Filter cdb.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $cdb = $found.FullName } else { Die "cdb.exe missing from the payload after unpack." }
}
Say "cdb: $cdb"

if (-not $PortableOnly) {
    foreach ($item in @('SKILL.md', 'scripts', 'references', 'tools')) {
        $src = Join-Path $Here "skill\$item"
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination $target -Recurse -Force
        }
    }
    Say "skill files installed"

    $cmdSrc = Join-Path $Here 'skill\command\dmp-triage.md'
    if (Test-Path -LiteralPath $cmdSrc) {
        $cmdDir = Join-Path $env:USERPROFILE '.claude\commands'
        New-Item -ItemType Directory -Force -Path $cmdDir | Out-Null
        Copy-Item -LiteralPath $cmdSrc -Destination (Join-Path $cmdDir 'dmp-triage.md') -Force
        Say "slash command installed: /dmp-triage"
    }
}

# ------------------------------------------------- 5. environment contract
Step "5/6  Environment"
if ($NoRegisterEnv) {
    Say "-NoRegisterEnv: skipping DMP_TRIAGE_HOME / DMP_TRIAGE_CDB"
} else {
    try {
        # User scope: no admin needed, survives reboots. .NET API instead of setx
        # (setx truncates at 1024 chars and would be a hazard on long paths).
        [Environment]::SetEnvironmentVariable('DMP_TRIAGE_HOME', $target, 'User')
        [Environment]::SetEnvironmentVariable('DMP_TRIAGE_CDB', $cdb, 'User')
        # make them usable inside THIS session too (setx would not do this)
        $env:DMP_TRIAGE_HOME = $target
        $env:DMP_TRIAGE_CDB = $cdb
        Say "DMP_TRIAGE_HOME = $target"
        Say "DMP_TRIAGE_CDB  = $cdb"
        Say "(user-scope variables; already-open terminals need a restart to see them)"
    } catch {
        Warn "could not register environment variables: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------- 6. self-test
Step "6/6  Self-test"
$cli = Join-Path $target 'scripts\dmp-triage.ps1'
if (-not (Test-Path -LiteralPath $cli)) { $cli = Join-Path $target 'dmp-triage.ps1' }
if (-not (Test-Path -LiteralPath $cli)) {
    Warn "CLI not found after install - skipping self-test"
} else {
    $ver = & $cdb -version 2>&1 | Select-Object -First 1
    Say "cdb reports: $ver"
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $cli check 2>&1
    $cdbLine = $out | Where-Object { $_ -match 'cdb\.exe' } | Select-Object -First 1
    if ($cdbLine -match 'NOT FOUND') {
        Warn "the CLI could not resolve cdb - check $binDir"
    } else {
        Say "CLI resolves its own bundled cdb: OK"
    }
}

# ------------------------------------------------------------------- done
Write-Host ""
if ($Status -eq 0) {
    Write-Host "  INSTALL COMPLETE" -ForegroundColor Green
} else {
    Write-Host "  INSTALL COMPLETE (with warnings)" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  Analyze a dump:" -ForegroundColor White
Write-Host "    powershell -NoProfile -ExecutionPolicy Bypass -File `"$cli`" analyze -Dump C:\dumps\app.dmp"
if (-not $PortableOnly) {
    Write-Host ""
    Write-Host "  In Claude Code (restart it once to pick up the new skill):" -ForegroundColor White
    Write-Host "    /dmp-triage C:\dumps\app.dmp"
}
Write-Host ""
Write-Host "  Give the LLM report-slim.md from the output folder."
Write-Host "  Verify anytime with check.cmd. Remove with uninstall.cmd."
Write-Host ""
exit $Status
