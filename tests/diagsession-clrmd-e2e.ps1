#requires -Version 5.1
<#
    Opt-in end-to-end smoke test for the ClrMD root-chain path (issue #35). NOT run by the default
    validate gate (needs the .NET SDK + builds a real dump -- time/env heavy). Run it manually, or via
    `validate.ps1 -IncludeClrMdE2E`, before a release or in a deep local validation.

    It builds the synthetic leak sample, has it self-dump a heap .dmp, builds ClrMdRootChainReport, runs
    it against the known `DeviceViewModel` leak, and asserts the report is produced and correct
    (reached > 0, >= 1 group, a sticky StrongHandle path through the DeviceManager holder). Skips
    cleanly (not fails) when the .NET SDK is unavailable.
#>
param([string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path)

$ErrorActionPreference = "Stop"
$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if (-not $dotnet) { Write-Host "dotnet SDK not found; skipping ClrMD E2E smoke test."; return }

$tools = Join-Path $RepositoryRoot "skills\diagsession-memory-analysis\tools"
$sample = Join-Path $tools "_leaksample\LeakSample.csproj"
$tool = Join-Path $tools "ClrMdRootChainReport\ClrMdRootChainReport.csproj"
foreach ($p in @($sample, $tool)) { if (-not (Test-Path -LiteralPath $p)) { throw "missing project: $p" } }

$work = Join-Path $env:TEMP ("clrmd-e2e-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$failures = @()
function Check($name, [scriptblock]$cond) {
    try { if (& $cond) { Write-Host "  [ok]   $name" } else { $script:failures += $name } }
    catch { $script:failures += "$name ($($_.Exception.Message))" }
}

try {
    $dump = Join-Path $work "e2e.dmp"
    Write-Host "  building + dumping leak sample..."
    & $dotnet.Source build $sample -c Release -v q 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "leak sample build failed" }
    & $dotnet.Source run --project $sample -c Release --no-build -- $dump 4000 2>&1 | Out-Null
    Check "self-dump produced a heap .dmp" { (Test-Path $dump) -and ((Get-Item $dump).Length -gt 1MB) }

    Write-Host "  building + running ClrMdRootChainReport..."
    & $dotnet.Source build $tool -c Release -v q 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "ClrMdRootChainReport build failed" }
    $out = Join-Path $work "report"
    & $dotnet.Source run --project $tool -c Release --no-build -- $dump --types DeviceViewModel --out $out 2>&1 | Out-Null
    Check "exit 0 from the tool" { $LASTEXITCODE -eq 0 }

    foreach ($f in @("reference-chains.json", "reference-chains.md", "reference-chains.html")) {
        Check "produced $f" { Test-Path (Join-Path $out $f) }
    }
    $json = Get-Content (Join-Path $out "reference-chains.json") -Raw | ConvertFrom-Json
    $dvm = $json.candidates | Where-Object { $_.type -match "DeviceViewModel" } | Select-Object -First 1
    Check "DeviceViewModel candidate found" { $null -ne $dvm }
    Check "rootReached > 0" { $dvm.rootReached -gt 0 }
    Check "at least one path group" { @($dvm.pathGroups).Count -ge 1 }
    Check "a sticky StrongHandle root group exists" { @($dvm.pathGroups | Where-Object { $_.rootKind -eq 'StrongHandle' }).Count -ge 1 }
    Check "path reaches the DeviceManager holder (field edge present)" { @($dvm.pathGroups | Where-Object { $_.signature -match 'DeviceManager' }).Count -ge 1 }
    Check "dump path redacted to filename in json (#34)" { $json.dump -notmatch '[\\/]' }
    Check "rootKindSummary present (#32)" { $null -ne $json.rootKindSummary }
    # #37: HTML must carry the same root-kind meaning as md/json (summary table + interpretation column).
    $html = Get-Content (Join-Path $out "reference-chains.html") -Raw
    Check "html shows root-kind summary table (#37)" { $html -match 'Root kinds reached' }
    Check "html shows per-group interpretation (#37)" { ($html -match 'how to read') -and ($html -match 'cache') }
}
finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }

if ($failures.Count) { throw ("ClrMD E2E smoke test failed:`n  " + ($failures -join "`n  ")) }
Write-Host "ClrMD E2E smoke test passed."
