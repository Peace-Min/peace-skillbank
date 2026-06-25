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
