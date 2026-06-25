#requires -Version 5.1
<#
    Offline gate for the #29 A/B eval SCORER (no dump / tool / Ollama needed -- those are dev/manual).
    Proves the deterministic rubric rewards correct attribution and rejects parroting/mis-attribution,
    using the committed canned answers under fixtures/rootchain-eval/.
#>
param([string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path)

$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
. (Join-Path $here "score-rootchain.ps1")
$fx = Join-Path $here "fixtures\rootchain-eval"

$failures = @()
function Check($name, [scriptblock]$cond) {
    try { if (& $cond) { Write-Host "  [ok]   $name" } else { $script:failures += $name } }
    catch { $script:failures += "$name ($($_.Exception.Message))" }
}
function Test-Syntax($path) { $t = $null; $e = $null; [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$t, [ref]$e) | Out-Null; return ($e.Count -eq 0) }

Check "score-rootchain.ps1 parses" { Test-Syntax (Join-Path $here "score-rootchain.ps1") }
Check "run-rootchain-eval-loop.ps1 parses" { Test-Syntax (Join-Path $here "run-rootchain-eval-loop.ps1") }
foreach ($f in @("A_synthetic.md", "B_synthetic.md", "B_negative.md")) {
    Check "canned answer present: $f" { Test-Path (Join-Path $fx $f) }
}

$a = Score-RootChainAnalysis ([System.IO.File]::ReadAllText((Join-Path $fx "A_synthetic.md")))
$b = Score-RootChainAnalysis ([System.IO.File]::ReadAllText((Join-Path $fx "B_synthetic.md")))
$neg = Score-RootChainAnalysis ([System.IO.File]::ReadAllText((Join-Path $fx "B_negative.md")))
$c = Score-RootChainAnalysis ([System.IO.File]::ReadAllText((Join-Path $fx "C_synthetic.md")))

# enrichment-style answer beats baseline-style, and on the discriminators the rubric was built on
Check "B beats A on Total" { $b.Total -gt $a.Total }
Check "B finds the timer path A structurally cannot (TimerHit)" { $b.TimerHit -eq 1 -and $a.TimerHit -eq 0 }
Check "B finds the static path + sticky root" { $b.StaticHit -eq 1 -and $b.RootKindHit -eq 1 }
Check "B does not hallucinate; A does" { $b.Hallucination -eq 0 -and $a.Hallucination -ge 1 }
Check "B is actionable (both fix loci)" { $b.Actionability -eq 2 }

# negative control: a B-shaped answer that mis-attributes (claims Bitmap is the leak) must be rejected
Check "negative control penalized below real B" { $neg.Total -lt $b.Total }
Check "negative control flagged as hallucination" { $neg.Hallucination -ge 1 }
Check "negative control does not get root-cause credit" { $neg.RootCause -lt $b.RootCause }

# --- Arm C (wrong-evidence control): a model that faithfully USES falsified evidence must land in the
#     low-RootCause / high-Hallucination region B never touches (proves the rubric tests correctness). ---
Check "C (faithful-to-wrong-evidence) scores below B on root cause" { $c.RootCause -lt $b.RootCause }
Check "C is flagged as hallucination (wrong holders asserted)" { $c.Hallucination -ge ($b.Hallucination + 1) }
Check "C does not beat the no-evidence baseline on root cause" { $c.RootCause -le $a.RootCause }

# --- Convert-ToWrongEvidence invariant: falsifying real enrichment must neutralize EVERY discriminator
#     (so if a model parrots C verbatim it scores RootCause=0 + a hallucination spike), at ~B length. ---
$enrReal = [System.IO.File]::ReadAllText((Join-Path $fx "B_enrichment_sample.txt"))
$enrWrong = Convert-ToWrongEvidence $enrReal
$enrWrongScore = Score-RootChainAnalysis $enrWrong
Check "falsifier neutralizes all root-cause discriminators (RootCause=0)" { $enrWrongScore.RootCause -eq 0 }
Check "falsifier injects hallucination tokens (>=2)" { $enrWrongScore.Hallucination -ge 2 }
Check "falsifier keeps the leak TYPE intact (DeviceViewModel still present)" { $enrWrong -match 'DeviceViewModel' }
Check "falsifier preserves length (no degenerate-to-empty)" { [math]::Abs($enrWrong.Length - $enrReal.Length) -le ($enrReal.Length * 0.30) }

# --- statistics helpers must compute the verdict math correctly ---
Check "sign-test: 8/8 is significant (p<=0.05)" { (Get-SignTestP 8 8) -le 0.05 }
Check "sign-test: 6/8 is NOT significant (p>0.05)" { (Get-SignTestP 6 8) -gt 0.05 }
Check "Wilson lower: 8/8 > 0.5" { (Get-WilsonLower 8 8) -gt 0.5 }
Check "Wilson lower: 5/8 <= 0.5 (not above chance)" { (Get-WilsonLower 5 8) -le 0.5 }

if ($failures.Count) { throw ("rootchain-eval scorer fixtures failed:`n  " + ($failures -join "`n  ")) }
Write-Host "rootchain-eval scorer fixtures passed (A=$($a.Total) B=$($b.Total) C=$($c.Total) neg=$($neg.Total))."
