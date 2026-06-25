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

if ($failures.Count) { throw ("rootchain-eval scorer fixtures failed:`n  " + ($failures -join "`n  ")) }
Write-Host "rootchain-eval scorer fixtures passed (A.Total=$($a.Total) B.Total=$($b.Total) neg.Total=$($neg.Total))."
