<#
 uninstall-peace-skillbank.ps1
 ---------------------------------------------------------------------------
 Removes EVERYTHING peace-skillbank puts on a machine, whether it arrived via
 the plugin marketplace, a manual copy, or the dmp-triage offline installer.

 Safe by design:
   * DRY RUN by default - it prints the plan and deletes nothing until you
     confirm (or pass -Confirm).
   * Only the known peace-skillbank skill names are touched. Skills that
     belong to other bundles - including symlinked ones - are never removed.
   * Takes a timestamped backup of any JSON it edits.

 Usage
   uninstall-peace-skillbank.cmd                 show the plan, then ask y/N
   uninstall-peace-skillbank.ps1 -Confirm        delete without asking
   uninstall-peace-skillbank.ps1 -WhatIfOnly     plan only, never prompt
   uninstall-peace-skillbank.ps1 -KeepConfig     do not touch ~\.claude.json
#>
[CmdletBinding()]
param(
    [switch]$Confirm,
    [switch]$WhatIfOnly,
    [switch]$KeepConfig
)

$ErrorActionPreference = 'Stop'
$ClaudeDir = Join-Path $env:USERPROFILE '.claude'
$ConfigJson = Join-Path $env:USERPROFILE '.claude.json'
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

# The complete list of skills this bank ships. Nothing outside it is deleted.
$BankSkills = @(
    'dmp-triage',
    'diagsession-memory-analysis',
    'frontier-handoff',
    'lightningchart-72',
    'sparrow-static-analysis',
    'addsim-xml-report',
    'xml-report'
)
$BankEnvVars = @('DMP_TRIAGE_HOME', 'DMP_TRIAGE_CDB')

# PowerShell 5.1's -Encoding UTF8 writes a BOM, which breaks strict JSON readers
# (Claude Code's own config among them). Always write JSON BOM-less.
function Write-JsonNoBom([string]$Path, $Object) {
    $json = $Object | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Say([string]$m)  { Write-Host "  $m" }
function Head([string]$m) { Write-Host ""; Write-Host $m -ForegroundColor Cyan }
function Warn([string]$m) { Write-Host "  ! $m" -ForegroundColor Yellow }

Write-Host ""
Write-Host "  peace-skillbank - complete uninstall" -ForegroundColor White
Write-Host "  ---------------------------------------------------------"
Write-Host "  Scans for every trace and shows a plan before deleting."

$plan = New-Object System.Collections.Generic.List[object]
function Plan([string]$kind, [string]$path, [string]$note) {
    $size = 0
    try {
        if (Test-Path -LiteralPath $path) {
            $item = Get-Item -LiteralPath $path -Force
            if ($item.PSIsContainer) {
                $size = (Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue |
                         Measure-Object Length -Sum).Sum
            } else { $size = $item.Length }
        }
    } catch { }
    $plan.Add([pscustomobject]@{ Kind = $kind; Path = $path; Note = $note; Size = [int64]$size })
}

# ---------------------------------------------------------- 1. plugin install
Head "1. Plugin install"
$pluginsDir = Join-Path $ClaudeDir 'plugins'
if (Test-Path -LiteralPath $pluginsDir) {
    # cache\<marketplace>\<plugin>\<version>\  and marketplace clones
    Get-ChildItem -LiteralPath $pluginsDir -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $sub = $_.FullName
        Get-ChildItem -LiteralPath $sub -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like '*peace-skillbank*' } |
            ForEach-Object { Plan 'dir' $_.FullName "plugin $($_.Parent.Name)" }
    }
    # registry files that may name the marketplace
    Get-ChildItem -LiteralPath $pluginsDir -Filter *.json -Force -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object {
            if (Select-String -LiteralPath $_.FullName -Pattern 'peace-skillbank' -Quiet -ErrorAction SilentlyContinue) {
                Plan 'json' $_.FullName 'remove peace-skillbank entries'
            }
        }
} else {
    Say "no ~\.claude\plugins directory (plugin was never installed here)"
}

# ------------------------------------------------------------- 2. skills
Head "2. Skills"
$skillsDir = Join-Path $ClaudeDir 'skills'
foreach ($n in $BankSkills) {
    $p = Join-Path $skillsDir $n
    if (Test-Path -LiteralPath $p) {
        $item = Get-Item -LiteralPath $p -Force
        $isLink = [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
        if ($isLink) {
            # a symlink here belongs to some other bundle's layout - report, do not delete
            Warn "$n is a symlink (managed by another bundle) - LEFT ALONE"
        } else {
            Plan 'dir' $p 'skill'
        }
    }
}

# ----------------------------------------------------------- 3. commands
Head "3. Slash commands"
$cmdDir = Join-Path $ClaudeDir 'commands'
foreach ($n in $BankSkills) {
    $p = Join-Path $cmdDir "$n.md"
    if (Test-Path -LiteralPath $p) { Plan 'file' $p 'slash command' }
}

# ------------------------------------------------- 4. environment variables
Head "4. Environment variables"
$envHits = @()
foreach ($v in $BankEnvVars) {
    $val = [Environment]::GetEnvironmentVariable($v, 'User')
    if ($val) { $envHits += $v; Say "$v = $val" }
}
if (-not $envHits) { Say "none set" }

# ------------------------------------------------------ 5. usage records
Head "5. Config records (~\.claude.json)"
$cfgKeys = @()
if (-not $KeepConfig -and (Test-Path -LiteralPath $ConfigJson)) {
    try {
        $cfg = Get-Content -LiteralPath $ConfigJson -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($section in @('pluginUsage', 'skillUsage')) {
            if ($cfg.PSObject.Properties.Name -contains $section -and $cfg.$section) {
                foreach ($k in $cfg.$section.PSObject.Properties.Name) {
                    if ($k -like '*peace-skillbank*' -or ($BankSkills | Where-Object { $k -like "*$_*" })) {
                        $cfgKeys += [pscustomobject]@{ Section = $section; Key = $k }
                        Say "$section : $k"
                    }
                }
            }
        }
    } catch { Warn "could not read ~\.claude.json ($($_.Exception.Message))" }
}
if (-not $cfgKeys) { Say "no records to clean" }

# ----------------------------------------------------------------- summary
Head "Plan"
if ($plan.Count -eq 0 -and -not $envHits -and -not $cfgKeys) {
    Write-Host "  Nothing to remove - this machine is already clean." -ForegroundColor Green
    exit 0
}
$total = ($plan | Measure-Object Size -Sum).Sum
foreach ($p in $plan) {
    $mb = if ($p.Size -gt 1MB) { ' ({0:N1} MB)' -f ($p.Size / 1MB) } else { '' }
    Write-Host ("  DELETE {0,-5} {1}{2}" -f $p.Kind, $p.Path, $mb)
}
foreach ($v in $envHits) { Write-Host "  UNSET  var   $v" }
foreach ($k in $cfgKeys) { Write-Host "  EDIT   json  ~\.claude.json -> $($k.Section).$($k.Key)" }
Write-Host ""
Write-Host ("  {0} path(s), {1:N1} MB total" -f $plan.Count, ($total / 1MB))

if ($WhatIfOnly) { Write-Host ""; Write-Host "  (plan only - nothing was changed)" -ForegroundColor Yellow; exit 0 }

if (-not $Confirm) {
    Write-Host ""
    Warn "Close Claude Code before continuing, so nothing rewrites its config afterwards."
    $ans = Read-Host "  Proceed with deletion? (y/N)"
    if ($ans -notmatch '^[Yy]') { Write-Host "  Cancelled. Nothing was changed."; exit 0 }
}

# ----------------------------------------------------------------- execute
Head "Removing"
$failed = 0
foreach ($p in $plan) {
    try {
        if ($p.Kind -eq 'json') {
            $bak = "$($p.Path).$Stamp.bak"
            Copy-Item -LiteralPath $p.Path -Destination $bak -Force
            $txt = Get-Content -LiteralPath $p.Path -Raw -Encoding UTF8
            $obj = $txt | ConvertFrom-Json
            # drop marketplace/plugin entries by name wherever they appear
            foreach ($prop in @($obj.PSObject.Properties)) {
                if ($prop.Value -is [System.Management.Automation.PSCustomObject]) {
                    foreach ($k in @($prop.Value.PSObject.Properties.Name)) {
                        if ($k -like '*peace-skillbank*') { $prop.Value.PSObject.Properties.Remove($k) }
                    }
                }
            }
            Write-JsonNoBom $p.Path $obj
            Say "edited $($p.Path)  (backup: $(Split-Path -Leaf $bak))"
        } else {
            Remove-Item -LiteralPath $p.Path -Recurse -Force
            Say "removed $($p.Path)"
        }
    } catch {
        Warn "FAILED $($p.Path) : $($_.Exception.Message)"
        $failed++
    }
}
foreach ($v in $envHits) {
    try { [Environment]::SetEnvironmentVariable($v, $null, 'User'); Say "unset $v" }
    catch { Warn "FAILED to unset $v"; $failed++ }
}
if ($cfgKeys -and (Test-Path -LiteralPath $ConfigJson)) {
    try {
        $bak = "$ConfigJson.$Stamp.bak"
        Copy-Item -LiteralPath $ConfigJson -Destination $bak -Force
        $cfg = Get-Content -LiteralPath $ConfigJson -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in $cfgKeys) {
            if ($cfg.$($k.Section)) { $cfg.$($k.Section).PSObject.Properties.Remove($k.Key) }
        }
        Write-JsonNoBom $ConfigJson $cfg
        Say "cleaned ~\.claude.json  (backup: $(Split-Path -Leaf $bak))"
    } catch {
        Warn "could not clean ~\.claude.json : $($_.Exception.Message)"
        $failed++
    }
}

Write-Host ""
if ($failed -eq 0) {
    Write-Host "  UNINSTALL COMPLETE" -ForegroundColor Green
} else {
    Write-Host "  FINISHED WITH $failed PROBLEM(S) - see the lines marked ! above" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  Not touched: dumps, analysis reports, other bundles' skills, and"
Write-Host "  any peace-skillbank git clone on your Desktop (delete that folder"
Write-Host "  yourself if you want it gone too)."
Write-Host ""
exit $(if ($failed -eq 0) { 0 } else { 1 })
