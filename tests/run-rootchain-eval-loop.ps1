#requires -Version 5.1
<#
    Rigorous self-running A/B/C eval for the issue-#29 root-chain enrichment.

      A = HeapStat-only        (baseline; a strict string prefix of B and C)
      B = A + REAL root-cause evidence (correct chains, from enrich-root-chains.ps1)
      C = A + FALSIFIED evidence (B's structure/length, holders/roots corrupted to the WRONG ones)

    A-vs-B asks "does the evidence help?". B-vs-C closes the central validity threat ("B trivially
    contains the answer, so the model might just parrot"): if B beats C -- byte-similar inputs that
    differ ONLY in whether the holders are CORRECT -- the gain comes from evidence correctness, not
    presence. Answers are scored deterministically against the fixture's known ground truth; verdict
    uses paired sign-test + Wilson bounds over N trials, with per-trial arm-order shuffling and temp=0.

    Graders: ollama (qwen via /api/generate, temp0+seed) | synthetic (canned answers, offline).
    Never gated on live qwen; the deterministic machinery+scorer are gated by rootchain-eval-fixtures.ps1.
#>
[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [int]$Trials = 8,
    [ValidateSet("ollama", "synthetic")][string]$Grader = "synthetic",
    [string]$OllamaModel = "qwen2.5-coder:7b",
    [int]$OllamaTimeoutSeconds = 300,
    [int]$MaxRetries = 1,
    [string]$OutputDirectory
)

$ErrorActionPreference = "Stop"
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $RepositoryRoot) { $RepositoryRoot = (Resolve-Path (Join-Path $here "..")).Path }
. (Join-Path $here "score-rootchain.ps1")   # scorer + Convert-ToWrongEvidence + stats helpers

$skill = Join-Path $RepositoryRoot "skills\diagsession-memory-analysis"
$scripts = Join-Path $skill "scripts"
$fixDir = Join-Path $here "fixtures\diagsession-rootchain"
$evalFix = Join-Path $here "fixtures\rootchain-eval"
$dump = Join-Path $skill "tools\_leaksample\after.dmp"
$toolExe = Join-Path $skill "tools\ClrMdRootChainReport\pub\ClrMdRootChainReport.exe"
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $RepositoryRoot ("out\rootchain-eval-loop\" + (Get-Date -Format "yyyyMMdd-HHmmss")) }
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$arms = @("A", "B", "C")

# ---------- build A, B (real evidence), C (falsified evidence) ----------
function Build-Inputs {
    $reps = Join-Path $OutputDirectory "reps"; New-Item -ItemType Directory -Force -Path $reps | Out-Null
    Copy-Item (Join-Path $fixDir "before.heapstat.txt") (Join-Path $reps "01-before.heapstat.txt")
    Copy-Item (Join-Path $fixDir "after.heapstat.txt") (Join-Path $reps "02-after.heapstat.txt")
    $base = "Snapshot 1: before.gcdump`r`nSnapshot 2: after.gcdump`r`n`r`n## HeapStat (before)`r`n" +
    [System.IO.File]::ReadAllText((Join-Path $reps "01-before.heapstat.txt")) +
    "`r`n## HeapStat (after)`r`n" + [System.IO.File]::ReadAllText((Join-Path $reps "02-after.heapstat.txt"))
    $u8 = New-Object System.Text.UTF8Encoding($false)
    foreach ($a in $arms) { New-Item -ItemType Directory -Force -Path (Join-Path $OutputDirectory $a) | Out-Null }
    $aIn = Join-Path $OutputDirectory "A\LLM_MEMORY_INPUT.txt"; [System.IO.File]::WriteAllText($aIn, $base, $u8)
    $bIn = Join-Path $OutputDirectory "B\LLM_MEMORY_INPUT.txt"; [System.IO.File]::WriteAllText($bIn, $base, $u8)
    & (Join-Path $scripts "enrich-root-chains.ps1") -ReportsDir $reps -DumpPath $dump -ToolExe $toolExe -OutputDir (Join-Path $OutputDirectory "B\enrich") -MemoryInput $bIn | Out-Null
    $bText = [System.IO.File]::ReadAllText($bIn)
    $cIn = Join-Path $OutputDirectory "C\LLM_MEMORY_INPUT.txt"; [System.IO.File]::WriteAllText($cIn, (Convert-ToWrongEvidence $bText), $u8)
    return @{ A = $aIn; B = $bIn; C = $cIn }
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

# ---------- grader (temp=0 + fixed seed via /api/generate; clean text, no CLI ANSI noise) ----------
function Invoke-Ollama([string]$promptText, [string]$outPath) {
    $body = @{ model = $OllamaModel; prompt = $promptText; stream = $false; options = @{ temperature = 0; seed = 42; top_p = 1 } } | ConvertTo-Json -Depth 6
    try {
        $resp = Invoke-RestMethod -Uri "http://localhost:11434/api/generate" -Method Post -Body $body -ContentType "application/json" -TimeoutSec $OllamaTimeoutSeconds
    }
    catch { return $false }
    if (-not $resp.response -or $resp.response.Trim().Length -eq 0) { return $false }
    [System.IO.File]::WriteAllText($outPath, $resp.response, (New-Object System.Text.UTF8Encoding($false)))
    return $true
}
function Get-Answer([string]$arm, [string]$requestPath, [string]$trialDir) {
    $out = Join-Path $trialDir "ANALYSIS.md"
    if ($Grader -eq "synthetic") { Copy-Item (Join-Path $evalFix "$arm`_synthetic.md") $out -Force; return $true }
    for ($r = 0; $r -le $MaxRetries; $r++) { if (Invoke-Ollama -promptText ([System.IO.File]::ReadAllText($requestPath)) -outPath $out) { return $true } }
    [System.IO.File]::WriteAllText($out, "(no answer -- grader failed after retries)", (New-Object System.Text.UTF8Encoding($false))); return $false
}

# ---------- preflight ----------
if ($Grader -eq "ollama") {
    try { $tags = Invoke-RestMethod -Uri "http://localhost:11434/api/tags" -TimeoutSec 15
        if (-not ($tags.models.name -contains $OllamaModel)) { Write-Warning "model $OllamaModel absent; -> synthetic"; $Grader = "synthetic" } }
    catch { Write-Warning "Ollama unreachable; -> synthetic"; $Grader = "synthetic" }
}

# ---------- run (per-trial shuffled arm order; same prompt; blind scoring) ----------
$inputs = Build-Inputs
$req = @{}
foreach ($a in $arms) { $p = Join-Path $OutputDirectory "$a\LLM_REQUEST.md"; [System.IO.File]::WriteAllText($p, (Build-Request $inputs[$a]), (New-Object System.Text.UTF8Encoding($false))); $req[$a] = $p }
$aBase = [System.IO.File]::ReadAllText($inputs.A)
$invariants = [pscustomobject]@{
    aPrefixOfB = ([System.IO.File]::ReadAllText($inputs.B)).StartsWith($aBase)
    aPrefixOfC = ([System.IO.File]::ReadAllText($inputs.C)).StartsWith($aBase)
    cLenVsB = [math]::Round(([System.IO.File]::ReadAllText($inputs.C)).Length / [double]([System.IO.File]::ReadAllText($inputs.B)).Length, 3)
}

$rows = @()
for ($i = 1; $i -le $Trials; $i++) {
    $order = @(Get-Random -InputObject $arms -Count $arms.Count -SetSeed $i)
    $score = @{}; $usable = @{}
    Write-Host "trial $i/$Trials ($Grader) order=$($order -join ',') :" -NoNewline
    foreach ($a in $order) {
        $td = Join-Path $OutputDirectory "$a\trial-$i"; New-Item -ItemType Directory -Force -Path $td | Out-Null
        Write-Host " $a" -NoNewline
        $usable[$a] = Get-Answer $a $req[$a] $td
        $s = Score-RootChainAnalysis ([System.IO.File]::ReadAllText((Join-Path $td "ANALYSIS.md")))
        ($s | ConvertTo-Json) | Set-Content (Join-Path $td "SCORE.json") -Encoding UTF8
        $score[$a] = $s
    }
    Write-Host ""
    $rows += [pscustomobject]@{ Trial = $i; Order = ($order -join ','); A = $score.A; B = $score.B; C = $score.C
        UsableAll = ($usable.A -and $usable.B -and $usable.C); WinBA = ($score.B.Total -gt $score.A.Total); WinBC = ($score.B.Total -gt $score.C.Total) }
}

# ---------- aggregate (paired stats) ----------
$ok = @($rows | Where-Object { $_.UsableAll }); $n = $ok.Count
function Mean($v) { $x = @($v); if ($x.Count -eq 0) { return 0 } ; return [math]::Round(($x | Measure-Object -Average).Average, 2) }
function Stat($arm, $field) {
    $vals = @($ok | ForEach-Object { $_.$arm.$field })
    return [pscustomobject]@{ mean = (Mean $vals); sd = (Get-Stdev $vals); min = ($vals | Measure-Object -Minimum).Minimum; max = ($vals | Measure-Object -Maximum).Maximum }
}
$winBA = @($ok | Where-Object { $_.WinBA }).Count
$winBC = @($ok | Where-Object { $_.WinBC }).Count
$st = @{}; foreach ($a in $arms) { $st[$a] = @{}; foreach ($f in @("RootCause", "Hallucination", "Actionability", "Total")) { $st[$a][$f] = (Stat $a $f) } }
$pBA = Get-SignTestP $winBA $n; $pBC = Get-SignTestP $winBC $n; $wilBA = Get-WilsonLower $winBA $n

# three-zone verdict
$aRC = $st.A.RootCause.mean; $bRC = $st.B.RootCause.mean; $cRC = $st.C.RootCause.mean
$aH = $st.A.Hallucination.mean; $bH = $st.B.Hallucination.mean; $cH = $st.C.Hallucination.mean
$correctnessHeld = (($bRC - $cRC) -ge 1.5) -and (($cH - $bH) -ge 1) -and ($cRC -le ($aRC + 0.5)) -and ($pBC -le 0.05)
$baHeld = (($bRC - $aRC) -ge 1.0) -and (($st.B.Total.mean - $st.A.Total.mean) -ge 1.5) -and ($pBA -le 0.05) -and ($wilBA -gt 0.5) -and ($bH -le 0.5) -and ($bH -le $aH)
$verdict =
if ($n -lt 6) { "INCONCLUSIVE (usable=$n < 6: under-powered)" }
elseif ($aRC -ge 2.5) { "INCONCLUSIVE (baseline saturates: A.RootCause=$aRC)" }
elseif (($bRC - $aRC) -le 0) { "FAIL (enrichment does not help: dRootCause(B-A)<=0)" }
elseif (($bRC - $cRC) -lt 1.0) { "FAIL (parroting confound: B ~= C, the model scores wrong evidence as high as right)" }
elseif ($baHeld -and $correctnessHeld) { "PASS (rigorously verified: enrichment helps AND the gain requires CORRECT evidence)" }
else { "INCONCLUSIVE (directionally right but a rigor criterion missed -- see numbers)" }

$summary = [pscustomobject]@{
    graderMode = $Grader; model = $OllamaModel; trials = $Trials; usableTrials = $n
    invariants = $invariants
    arms = $st
    paired = [pscustomobject]@{ winBA = "$winBA/$n"; pBA = $pBA; wilsonLowerBA = $wilBA; winBC = "$winBC/$n"; pBC = $pBC }
    gates = [pscustomobject]@{ baHeld = $baHeld; correctnessHeld = $correctnessHeld }
    verdict = $verdict
    perTrial = @($rows | ForEach-Object { [pscustomobject]@{ t = $_.Trial; order = $_.Order; A = $_.A.Total; B = $_.B.Total; C = $_.C.Total; bRC = $_.B.RootCause; cRC = $_.C.RootCause } })
}
($summary | ConvertTo-Json -Depth 8) | Set-Content (Join-Path $OutputDirectory "EVAL_SUMMARY.json") -Encoding UTF8

$r = New-Object System.Text.StringBuilder
[void]$r.AppendLine("# Root-chain enrichment A/B/C eval (rigorous)")
[void]$r.AppendLine("grader=$Grader  model=$OllamaModel  trials=$Trials  usable=$n")
[void]$r.AppendLine("invariants: A-prefix-of-B=$($invariants.aPrefixOfB)  A-prefix-of-C=$($invariants.aPrefixOfC)  len(C)/len(B)=$($invariants.cLenVsB)")
[void]$r.AppendLine("")
[void]$r.AppendLine("| arm | RootCause(mean±sd, 0-3) | Hallucination | Actionability | Total |")
[void]$r.AppendLine("|---|---|---|---|---|")
foreach ($a in $arms) { [void]$r.AppendLine("| $a | $($st[$a].RootCause.mean)±$($st[$a].RootCause.sd) | $($st[$a].Hallucination.mean)±$($st[$a].Hallucination.sd) | $($st[$a].Actionability.mean) | $($st[$a].Total.mean)±$($st[$a].Total.sd) |") }
[void]$r.AppendLine("")
[void]$r.AppendLine("paired: B>A in $winBA/$n (sign-test p=$pBA, Wilson lower=$wilBA)  |  B>C in $winBC/$n (p=$pBC)")
[void]$r.AppendLine("gates: B-beats-A held=$baHeld  correctness(B>>C) held=$correctnessHeld")
[void]$r.AppendLine("")
[void]$r.AppendLine("| trial | order | A.Total | B.Total | C.Total | B.RootCause | C.RootCause |")
[void]$r.AppendLine("|---|---|---|---|---|---|---|")
foreach ($x in $rows) { [void]$r.AppendLine("| $($x.Trial) | $($x.Order) | $($x.A.Total) | $($x.B.Total) | $($x.C.Total) | $($x.B.RootCause) | $($x.C.RootCause) |") }
[void]$r.AppendLine("")
[void]$r.AppendLine("## VERDICT: $verdict")
[System.IO.File]::WriteAllText((Join-Path $OutputDirectory "EVAL_REPORT.md"), $r.ToString(), (New-Object System.Text.UTF8Encoding($false)))

Write-Host ""; Get-Content (Join-Path $OutputDirectory "EVAL_REPORT.md"); Write-Host "`nout: $OutputDirectory"
