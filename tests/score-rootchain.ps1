#requires -Version 5.1
<#
    Deterministic, ground-truth-based scorer for the #29 root-chain A/B eval. Dot-source this to get
    Score-RootChainAnalysis; it scores a model ANSWER (never the evidence) against the synthetic
    fixture's known retention truth (static-cache Dictionary path + timer path retain DeviceViewModel).
    Shared by run-rootchain-eval-loop.ps1 and the offline rootchain-eval-fixtures gate.
#>

function Normalize-Text([string]$t) { return (($t -replace '[`|]', ' ') -replace '\s+', ' ').ToLowerInvariant() }

function Test-Proximity([string]$t, [string]$rxA, [string]$rxB, [int]$window = 600) {
    $ma = [regex]::Matches($t, $rxA, 'IgnoreCase'); $mb = [regex]::Matches($t, $rxB, 'IgnoreCase')
    foreach ($a in $ma) { foreach ($b in $mb) { if ([math]::Abs($a.Index - $b.Index) -le $window) { return $true } } }
    return $false
}

# Arm C generator: deterministically FALSIFY the enrichment block's holder/root tokens (the HeapStat
# base -- shared with A -- is left untouched). A model that merely PARROTS its input will now assert
# the WRONG holders near DeviceViewModel => the scorer gives 0 RootCause + a Hallucination spike. So if
# B still beats C, B's advantage comes from the evidence being CORRECT, not merely PRESENT.
function Convert-ToWrongEvidence([string]$fullText) {
    $marker = "## Heap growth summary"
    $idx = $fullText.IndexOf($marker)
    if ($idx -lt 0) { return $fullText }   # no enrichment -> nothing to falsify
    $base = $fullText.Substring(0, $idx); $enr = $fullText.Substring($idx)
    # ordered, case-sensitive swaps (longer tokens first to avoid partial overwrite)
    $enr = $enr -creplace 'TimerQueueTimer', 'EventHandlerState'
    $enr = $enr -creplace 'TimerQueue\[\]', 'EventDispatch[]'
    $enr = $enr -creplace 'TimerQueue', 'EventDispatch'
    $enr = $enr -creplace 'TimerHolder', 'EventManager'
    $enr = $enr -creplace '\bTimer\b', 'EventHub'
    $enr = $enr -creplace 'DeviceManager', 'BitmapCache'
    $enr = $enr -creplace 'Dictionary', 'ObservableCollection'
    $enr = $enr -creplace '\bList\b', 'EventHandlerList'
    $enr = $enr -creplace 'StrongHandle', 'Stack'
    $enr = $enr -creplace 'STICKY', 'in-use'
    $enr = $enr -creplace 'sticky', 'stack'
    $enr = $enr -creplace 'static', 'local'
    $enr = $enr -creplace 'Object\[\]', 'Frame'
    return $base + $enr
}

# Two-sided sign-test p-value for `wins` of `n` paired trials (closed form, no library).
function Get-SignTestP([int]$wins, [int]$n) {
    if ($n -le 0) { return 1.0 }
    $k = [math]::Max($wins, $n - $wins)
    function Choose([int]$a, [int]$b) { $r = 1.0; for ($i = 1; $i -le $b; $i++) { $r = $r * ($a - $b + $i) / $i }; return $r }
    $tail = 0.0; for ($i = $k; $i -le $n; $i++) { $tail += (Choose $n $i) * [math]::Pow(0.5, $n) }
    return [math]::Min(1.0, [math]::Round(2.0 * $tail, 4))
}
# Wilson score lower bound for k/n at 95%.
function Get-WilsonLower([int]$k, [int]$n, [double]$z = 1.96) {
    if ($n -le 0) { return 0.0 }
    $p = $k / $n; $z2 = $z * $z
    $center = $p + $z2 / (2 * $n); $half = $z * [math]::Sqrt(($p * (1 - $p) + $z2 / (4 * $n)) / $n)
    return [math]::Round(($center - $half) / (1 + $z2 / $n), 3)
}
function Get-Stdev($vals) { $a = @($vals); if ($a.Count -lt 2) { return 0 } ; $m = ($a | Measure-Object -Average).Average; $s = ($a | ForEach-Object { ($_ - $m) * ($_ - $m) } | Measure-Object -Sum).Sum; return [math]::Round([math]::Sqrt($s / ($a.Count - 1)), 2) }

function Score-RootChainAnalysis([string]$raw) {
    $t = Normalize-Text $raw
    $rxLeak = 'deviceviewmodel'
    $rxStaticHolder = '(devicemanager|s_manager|static (cache|field|dictionary|manager))'
    $rxTimerHolder = '(timerholder|timerqueuetimer|timer queue|\btimer\b)'
    $rxStickyRoot = '(stronghandle|sticky root|gc root|static root|rooted by a static)'
    # (a) root-cause hit (0..3): static path, timer path (A structurally cannot know it), root nature
    $staticHit = [int](Test-Proximity $t $rxLeak $rxStaticHolder)
    $timerHit = [int](Test-Proximity $t $rxLeak $rxTimerHolder)
    $rootKindHit = [int]($t -match $rxStickyRoot)
    $rootCause = $staticHit + $timerHit + $rootKindHit
    # (b) hallucination: a wrong retention mechanism ASSERTED as the cause (proximity to retention verbs)
    $retVerb = '(retain|root|held|holds|keeps? alive|never released|leak|because|caused by)'
    $halluc = @('event ?handler', '\+=', 'unsubscrib', 'propertychanged', 'inotify',
        'observablecollection', 'static event', 'closure', 'lambda captur',
        'dispatcher', 'async state', 'task continuation', 'weakreference',
        'conditionalweaktable', 'concurrentdictionary', 'hashset',
        'database connection', 'httpclient', 'bitmap')
    $hCount = 0
    foreach ($p in $halluc) { if (Test-Proximity $t $p $retVerb 200) { $hCount++ } }
    # (c) actionability (0..2): right fix locus
    $fixStatic = [int](Test-Proximity $t $rxStaticHolder '(clear|remove|evict|bound|dispose|unregister|cache eviction|empty)' 300)
    $fixTimer = [int](Test-Proximity $t $rxTimerHolder '(dispose|stop|release|unsubscrib)' 300)
    $action = $fixStatic + $fixTimer
    $total = $rootCause + $action - $hCount
    return [pscustomobject]@{
        StaticHit = $staticHit; TimerHit = $timerHit; RootKindHit = $rootKindHit
        RootCause = $rootCause; Hallucination = $hCount; Actionability = $action; Total = $total
    }
}
