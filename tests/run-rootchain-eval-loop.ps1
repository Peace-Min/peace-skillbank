#requires -Version 5.1
<#
    Self-running A/B eval for the issue-#29 root-chain enrichment: does giving a WEAK local model the
    root-cause evidence (B) improve its managed-leak diagnosis vs HeapStat-only (A)?  Only the evidence
    differs between arms (A is a strict prefix of B). Answers are scored DETERMINISTICALLY against the
    synthetic fixture's known ground truth (static-cache Dictionary path + timer path retain
    DeviceViewModel), so the verdict is auditable, not subjective.

    Graders:
      ollama     -- qwen2.5-coder:7b via Ollama (the air-gapped-weak-model proxy); slow/flaky, timeouts+retries
      synthetic  -- canned A/B answer files (offline, deterministic; proves the scorer+pipeline)

    Never hangs: every external call is Start-Process + WaitForExit(timeout) + Kill. Not gated on live qwen.
#>
[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [int]$Trials = 3,
    [ValidateSet("ollama", "synthetic")][string]$Grader = "synthetic",
    [string]$OllamaModel = "qwen2.5-coder:7b",
    [int]$OllamaTimeoutSeconds = 300,
    [int]$MaxRetries = 1,
    [string]$OutputDirectory
)

$ErrorActionPreference = "Stop"
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $RepositoryRoot) { $RepositoryRoot = (Resolve-Path (Join-Path $here "..")).Path }
$skill = Join-Path $RepositoryRoot "skills\diagsession-memory-analysis"
$scripts = Join-Path $skill "scripts"
$fixDir = Join-Path $here "fixtures\diagsession-rootchain"
$evalFix = Join-Path $here "fixtures\rootchain-eval"
$dump = Join-Path $skill "tools\_leaksample\after.dmp"
$toolExe = Join-Path $skill "tools\ClrMdRootChainReport\pub\ClrMdRootChainReport.exe"
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $RepositoryRoot ("out\rootchain-eval-loop\" + (Get-Date -Format "yyyyMMdd-HHmmss")) }
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

# ---------- scorer (shared; scores the ANSWER, never the evidence) ----------
. (Join-Path $here "score-rootchain.ps1")

# ---------- build A and B inputs (only evidence differs; A is a prefix of B) ----------
function Build-Inputs {
    $reps = Join-Path $OutputDirectory "reps"; New-Item -ItemType Directory -Force -Path $reps | Out-Null
    Copy-Item (Join-Path $fixDir "before.heapstat.txt") (Join-Path $reps "01-before.heapstat.txt")
    Copy-Item (Join-Path $fixDir "after.heapstat.txt") (Join-Path $reps "02-after.heapstat.txt")
    $base = "Snapshot 1: before.gcdump`r`nSnapshot 2: after.gcdump`r`n`r`n## HeapStat (before)`r`n" +
    [System.IO.File]::ReadAllText((Join-Path $reps "01-before.heapstat.txt")) +
    "`r`n## HeapStat (after)`r`n" + [System.IO.File]::ReadAllText((Join-Path $reps "02-after.heapstat.txt"))
    $aDir = Join-Path $OutputDirectory "A"; $bDir = Join-Path $OutputDirectory "B"
    New-Item -ItemType Directory -Force -Path $aDir, $bDir | Out-Null
    $aIn = Join-Path $aDir "LLM_MEMORY_INPUT.txt"; $bIn = Join-Path $bDir "LLM_MEMORY_INPUT.txt"
    [System.IO.File]::WriteAllText($aIn, $base, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($bIn, $base, (New-Object System.Text.UTF8Encoding($false)))
    & (Join-Path $scripts "enrich-root-chains.ps1") -ReportsDir $reps -DumpPath $dump -ToolExe $toolExe -OutputDir (Join-Path $bDir "enrich") -MemoryInput $bIn | Out-Null
    return @{ A = $aIn; B = $bIn }
}
function Build-Request([string]$memoryInputPath) {
    $prompt = @"
You are diagnosing a .NET MANAGED memory leak from profiler evidence. From the evidence ONLY, state:
1. the leaking type,
2. WHAT keeps each leaked object alive -- the retention path / GC-root holder (name the holder and the container),
3. exactly where to fix it.
Ground every claim in the evidence. Do NOT invent a retention cause you cannot see in the evidence; if the
evidence does not show what retains the objects, say so rather than guessing.

=== EVIDENCE ===
"@
    return $prompt + "`r`n" + [System.IO.File]::ReadAllText($memoryInputPath)
}

# ---------- graders ----------
function Invoke-Ollama([string]$requestPath, [string]$outPath) {
    $err = "$outPath.err"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "ollama"; $psi.Arguments = "run $OllamaModel"
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $p = [System.Diagnostics.Process]::Start($psi)
    $null = $p.Handle
    $stdoutTask = $p.StandardOutput.ReadToEndAsync()
    $stderrTask = $p.StandardError.ReadToEndAsync()
    $p.StandardInput.Write([System.IO.File]::ReadAllText($requestPath)); $p.StandardInput.Close()
    if (-not $p.WaitForExit($OllamaTimeoutSeconds * 1000)) { try { $p.Kill() } catch {}; return $false }
    [System.IO.File]::WriteAllText($outPath, $stdoutTask.Result, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($err, $stderrTask.Result, (New-Object System.Text.UTF8Encoding($false)))
    return ($stdoutTask.Result.Trim().Length -gt 0)
}
function Get-Answer([string]$arm, [string]$requestPath, [string]$trialDir) {
    $out = Join-Path $trialDir "ANALYSIS.md"
    if ($Grader -eq "synthetic") {
        Copy-Item (Join-Path $evalFix "$arm`_synthetic.md") $out -Force; return $true
    }
    for ($r = 0; $r -le $MaxRetries; $r++) { if (Invoke-Ollama -requestPath $requestPath -outPath $out) { return $true } }
    [System.IO.File]::WriteAllText($out, "(no answer -- grader failed after retries)", (New-Object System.Text.UTF8Encoding($false)))
    return $false
}

# ---------- preflight ----------
if ($Grader -eq "ollama") {
    try {
        $tags = Invoke-RestMethod -Uri "http://localhost:11434/api/tags" -TimeoutSec 15
        if (-not ($tags.models.name -contains $OllamaModel)) { Write-Warning "model $OllamaModel not in Ollama; falling back to synthetic"; $Grader = "synthetic" }
    }
    catch { Write-Warning "Ollama not reachable; falling back to synthetic"; $Grader = "synthetic" }
}

# ---------- run ----------
$inputs = Build-Inputs
$aReq = Join-Path $OutputDirectory "A\LLM_REQUEST.md"; $bReq = Join-Path $OutputDirectory "B\LLM_REQUEST.md"
[System.IO.File]::WriteAllText($aReq, (Build-Request $inputs.A), (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText($bReq, (Build-Request $inputs.B), (New-Object System.Text.UTF8Encoding($false)))
$aIsPrefixOfB = ([System.IO.File]::ReadAllText($inputs.B)).StartsWith([System.IO.File]::ReadAllText($inputs.A))

$rows = @()
for ($i = 1; $i -le $Trials; $i++) {
    $aTrial = Join-Path $OutputDirectory "A\trial-$i"; $bTrial = Join-Path $OutputDirectory "B\trial-$i"
    New-Item -ItemType Directory -Force -Path $aTrial, $bTrial | Out-Null
    Write-Host "trial $i/$Trials ($Grader): A..." -NoNewline
    $okA = Get-Answer "A" $aReq $aTrial; Write-Host " B..." -NoNewline
    $okB = Get-Answer "B" $bReq $bTrial; Write-Host " scoring"
    $sA = Score-RootChainAnalysis ([System.IO.File]::ReadAllText((Join-Path $aTrial "ANALYSIS.md")))
    $sB = Score-RootChainAnalysis ([System.IO.File]::ReadAllText((Join-Path $bTrial "ANALYSIS.md")))
    ($sA | ConvertTo-Json) | Set-Content (Join-Path $aTrial "SCORE.json") -Encoding UTF8
    ($sB | ConvertTo-Json) | Set-Content (Join-Path $bTrial "SCORE.json") -Encoding UTF8
    $rows += [pscustomobject]@{ Trial = $i; UsableA = $okA; UsableB = $okB; A = $sA; B = $sB; Win = ($sB.Total -gt $sA.Total) }
}

# ---------- aggregate + verdict ----------
$usable = @($rows | Where-Object { $_.UsableA -and $_.UsableB })
function Mean($vals) { $a = @($vals); if ($a.Count -eq 0) { return 0 } ; return [math]::Round(($a | Measure-Object -Average).Average, 2) }
$aRC = Mean ($usable | ForEach-Object { $_.A.RootCause }); $bRC = Mean ($usable | ForEach-Object { $_.B.RootCause })
$aH = Mean ($usable | ForEach-Object { $_.A.Hallucination }); $bH = Mean ($usable | ForEach-Object { $_.B.Hallucination })
$aAct = Mean ($usable | ForEach-Object { $_.A.Actionability }); $bAct = Mean ($usable | ForEach-Object { $_.B.Actionability })
$aT = Mean ($usable | ForEach-Object { $_.A.Total }); $bT = Mean ($usable | ForEach-Object { $_.B.Total })
$wins = @($usable | Where-Object { $_.Win }).Count
$winNeed = [math]::Ceiling(0.6 * $usable.Count)
$verdict =
if ($usable.Count -lt [math]::Ceiling($Trials / 2.0)) { "INCONCLUSIVE (too few usable trials: $($usable.Count)/$Trials)" }
elseif ($aRC -ge 2.5) { "INCONCLUSIVE (baseline saturates: A.RootCause=$aRC)" }
elseif (($bRC - $aRC) -ge 1.0 -and $bH -le $aH -and $wins -ge $winNeed) { "PASS (enrichment improves the weak model)" }
else { "FAIL (no significant improvement)" }

$summary = [pscustomobject]@{
    graderMode = $Grader; model = $OllamaModel; trials = $Trials; usableTrials = $usable.Count
    aIsPrefixOfB = $aIsPrefixOfB
    a = [pscustomobject]@{ rootCause = $aRC; halluc = $aH; action = $aAct; total = $aT }
    b = [pscustomobject]@{ rootCause = $bRC; halluc = $bH; action = $bAct; total = $bT }
    deltas = [pscustomobject]@{ rootCause = [math]::Round($bRC - $aRC, 2); halluc = [math]::Round($bH - $aH, 2); total = [math]::Round($bT - $aT, 2) }
    winRate = "$wins/$($usable.Count)"; verdict = $verdict
}
($summary | ConvertTo-Json -Depth 5) | Set-Content (Join-Path $OutputDirectory "EVAL_SUMMARY.json") -Encoding UTF8

$rep = New-Object System.Text.StringBuilder
[void]$rep.AppendLine("# Root-chain enrichment A/B eval")
[void]$rep.AppendLine("grader=$Grader  model=$OllamaModel  trials=$Trials  usable=$($usable.Count)  A-prefix-of-B=$aIsPrefixOfB")
[void]$rep.AppendLine("")
[void]$rep.AppendLine("| arm | RootCause(0-3) | Hallucination | Actionability(0-2) | Total |")
[void]$rep.AppendLine("|---|---|---|---|---|")
[void]$rep.AppendLine("| A (HeapStat-only) | $aRC | $aH | $aAct | $aT |")
[void]$rep.AppendLine("| B (enriched)      | $bRC | $bH | $bAct | $bT |")
[void]$rep.AppendLine("| delta (B-A)       | $([math]::Round($bRC-$aRC,2)) | $([math]::Round($bH-$aH,2)) | $([math]::Round($bAct-$aAct,2)) | $([math]::Round($bT-$aT,2)) |")
[void]$rep.AppendLine("")
[void]$rep.AppendLine("B wins on Total: $wins/$($usable.Count) (need >= $winNeed)")
[void]$rep.AppendLine("")
[void]$rep.AppendLine("## VERDICT: $verdict")
[System.IO.File]::WriteAllText((Join-Path $OutputDirectory "EVAL_REPORT.md"), $rep.ToString(), (New-Object System.Text.UTF8Encoding($false)))

Write-Host ""
Get-Content (Join-Path $OutputDirectory "EVAL_REPORT.md")
Write-Host "`nout: $OutputDirectory"
