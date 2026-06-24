#requires -Version 5.1
<#
    Behavioral fixtures for the issue #29 root-cause enrichment that need NO .dmp (Phase 1/3/4):
    candidate selection from HeapStat diff, the native boundary, native-wrapper flagging, and the
    enrich orchestrator's graceful fallback. The ClrMD root-chain stage itself needs a (large, local)
    dump, so it is exercised by the tools/_leaksample dev fixture, not gated here.
#>
param([string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path)

$ErrorActionPreference = "Stop"
$scripts = Join-Path $RepositoryRoot "skills\diagsession-memory-analysis\scripts"
$select = Join-Path $scripts "select-candidates.ps1"
$enrich = Join-Path $scripts "enrich-root-chains.ps1"
$toolDir = Join-Path $RepositoryRoot "skills\diagsession-memory-analysis\tools\ClrMdRootChainReport"
$fix = Join-Path $PSScriptRoot "fixtures\diagsession-rootchain"
$before = Join-Path $fix "before.heapstat.txt"
$after = Join-Path $fix "after.heapstat.txt"

$failures = @()
function Check($name, [scriptblock]$cond) {
    try { if (& $cond) { Write-Host "  [ok]   $name" } else { $script:failures += $name } }
    catch { $script:failures += "$name ($($_.Exception.Message))" }
}
function Test-Syntax($path) {
    $t = $null; $e = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$t, [ref]$e) | Out-Null
    return ($e.Count -eq 0)
}

Check "select-candidates.ps1 parses" { Test-Syntax $select }
Check "enrich-root-chains.ps1 parses" { Test-Syntax $enrich }
Check "ClrMdRootChainReport source present" {
    (Test-Path (Join-Path $toolDir "ClrMdRootChainReport.csproj")) -and (Test-Path (Join-Path $toolDir "Program.cs"))
}

$tmp = Join-Path $env:TEMP ("rc-fix-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    $md = & $select -BeforeReport $before -AfterReport $after -OutTypeList (Join-Path $tmp "c.txt") | Out-String
    Check "app-owned both-increased candidate detected" { $md -match "Both-increased app-owned" -and $md -match "LeakSample\.DeviceViewModel" }
    Check "native boundary + GC heap growth (+19,000,000)" { $md -match "Native / unmanaged boundary" -and $md -match "GC Heap grew by \+19,000,000" }
    Check "native-wrapper (Bitmap) flagged" { $md -match "native-wrapper.*Bitmap" }
    Check "retention container (Dictionary) flagged" { ($md -match "Retention containers") -and ($md -match "Dictionary") }
    Check "candidate list has DeviceViewModel" { ((Get-Content (Join-Path $tmp "c.txt") -Raw)) -match "DeviceViewModel" }

    $reps = Join-Path $tmp "reps"; New-Item -ItemType Directory -Force -Path $reps | Out-Null
    Copy-Item $before (Join-Path $reps "01-before.heapstat.txt")
    Copy-Item $after (Join-Path $reps "02-after.heapstat.txt")
    $out = Join-Path $tmp "out"
    # No -DumpPath -> deterministic graceful "root-chain unavailable" while still emitting candidates.
    $ev = & $enrich -ReportsDir $reps -OutputDir $out | Out-String
    Check "enrich graceful fallback note" { ($ev -match "Root-chain unavailable") -and ($ev -match "Both-increased app-owned") }
    Check "enrich wrote root-cause-evidence.md" { Test-Path (Join-Path $out "root-cause-evidence.md") }

    # one report only -> skip-with-note path
    $one = Join-Path $tmp "one"; New-Item -ItemType Directory -Force -Path $one | Out-Null
    Copy-Item $after (Join-Path $one "only.heapstat.txt")
    $ev1 = & $enrich -ReportsDir $one -OutputDir (Join-Path $tmp "out1") | Out-String
    Check "enrich single-snapshot skip note" { $ev1 -match "need before\+after" }
}
finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

if ($failures.Count) { throw ("diagsession-rootchain fixture tests failed:`n  " + ($failures -join "`n  ")) }
Write-Host "diagsession-rootchain fixture tests passed."
