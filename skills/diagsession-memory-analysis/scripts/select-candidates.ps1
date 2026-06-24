#requires -Version 5.1
<#
    Phase 1 of issue #29 (no dependencies): turn two `dotnet-gcdump report` HeapStat texts
    (before / after) into a ranked candidate set for root-chain analysis.

    HeapStat tells us WHAT grew (Count / Size deltas). It does NOT tell us WHY objects are retained --
    that needs the after.dmp + ClrMD root-chain stage (ClrMdRootChainReport). This script produces:
      - a markdown "Heap growth summary" block for LLM_MEMORY_INPUT.txt
      - a plain candidate type list (comma-joined) to feed `ClrMdRootChainReport --types`

    Candidate policy (agreed in #29): rank by BOTH DeltaSize (impact) and DeltaCount (leak pattern);
    both-increased app-owned types are top priority; retention-container types are flagged as clues.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BeforeReport,
    [Parameter(Mandatory = $true)][string]$AfterReport,
    [int]$TopN = 10,
    [string]$OutMarkdown,
    [string]$OutTypeList
)

$ErrorActionPreference = "Stop"

# Container / wiring types that commonly *hold* the leaking object (retention clue, not necessarily the leak itself).
$script:RetentionHints = @(
    "Dictionary", "List", "ObservableCollection", "HashSet", "ConcurrentDictionary", "ConcurrentBag",
    "Queue", "Stack", "Timer", "DispatcherTimer", "EventHandler", "Action", "Func", "Task",
    "WeakReference", "ConditionalWeakTable", "Lazy"
)

function Test-AppOwned {
    param([string]$Assembly, [string]$TypeName)
    # Framework assemblies = not app-owned. Everything else (incl. unknown) = app-owned candidate.
    if ($Assembly -match '^(System\.|Microsoft\.|mscorlib|netstandard|PresentationFramework|PresentationCore|WindowsBase|WindowsFormsIntegration|System$|Anonymously Hosted)') { return $false }
    if ($TypeName -match '^(System\.|Microsoft\.)') { return $false }
    return $true
}

function Get-HeapStat {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "HeapStat report not found: $Path" }
    $table = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        # <bytes>  <count>  <Type>[ (Bytes > X)]  [assembly]
        $m = [regex]::Match($line, '^\s*([\d,]+)\s+([\d,]+)\s+(.+?)\s+\[([^\]]+)\]\s*$')
        if (-not $m.Success) { continue }
        $bytes = [long]($m.Groups[1].Value -replace ',', '')
        $count = [long]($m.Groups[2].Value -replace ',', '')
        $type = ($m.Groups[3].Value -replace '\s*\(Bytes > [^)]+\)\s*$', '').Trim()
        $asm = $m.Groups[4].Value.Trim()
        if (-not $type) { continue }
        # collapse duplicate annotated buckets of the same type
        if ($table.ContainsKey($type)) {
            $table[$type].Count += $count
            $table[$type].Size += $bytes
        }
        else {
            $table[$type] = [pscustomobject]@{
                Type = $type; Count = $count; Size = $bytes; Assembly = $asm
                AppOwned = (Test-AppOwned -Assembly $asm -TypeName $type)
            }
        }
    }
    return $table
}

$before = Get-HeapStat -Path $BeforeReport
$after = Get-HeapStat -Path $AfterReport

# Delta over the union of types (before defaults to 0).
$deltas = foreach ($type in ($after.Keys + $before.Keys | Sort-Object -Unique)) {
    $a = $after[$type]; $b = $before[$type]
    $ac = if ($a) { $a.Count } else { 0 }; $asz = if ($a) { $a.Size } else { 0 }
    $bc = if ($b) { $b.Count } else { 0 }; $bsz = if ($b) { $b.Size } else { 0 }
    $asm = if ($a) { $a.Assembly } elseif ($b) { $b.Assembly } else { "" }
    [pscustomobject]@{
        Type = $type
        DeltaCount = $ac - $bc
        DeltaSize = $asz - $bsz
        AfterCount = $ac
        AppOwned = (Test-AppOwned -Assembly $asm -TypeName $type)
        IsContainer = [bool]($script:RetentionHints | Where-Object { $type -match [regex]::Escape($_) })
    }
}

$grew = $deltas | Where-Object { $_.DeltaSize -gt 0 -or $_.DeltaCount -gt 0 }
$topSize = $grew | Sort-Object DeltaSize -Descending | Select-Object -First $TopN
$topCount = $grew | Sort-Object DeltaCount -Descending | Select-Object -First $TopN
$bothApp = $grew | Where-Object { $_.DeltaSize -gt 0 -and $_.DeltaCount -gt 0 -and $_.AppOwned } | Sort-Object DeltaSize -Descending | Select-Object -First $TopN
$containers = $grew | Where-Object { $_.IsContainer } | Sort-Object DeltaSize -Descending | Select-Object -First $TopN

# Candidate type list for the ClrMD stage: both-app-owned first, then top size, then top count (deduped, bounded to 20).
$candidates = @()
foreach ($set in @($bothApp, $topSize, $topCount)) {
    foreach ($d in $set) { if ($candidates -notcontains $d.Type) { $candidates += $d.Type } }
}
$candidates = $candidates | Select-Object -First 20

function Format-Row { param($d) "- {0}: {1:+#,0;-#,0} objects, {2:+#,0;-#,0} bytes" -f $d.Type, $d.DeltaCount, $d.DeltaSize }

$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine("## Heap growth summary (before -> after)")
[void]$md.AppendLine("")
[void]$md.AppendLine("### Top DeltaSize (memory impact)")
foreach ($d in $topSize) { [void]$md.AppendLine((Format-Row $d)) }
[void]$md.AppendLine("")
[void]$md.AppendLine("### Top DeltaCount (leak pattern)")
foreach ($d in $topCount) { [void]$md.AppendLine((Format-Row $d)) }
[void]$md.AppendLine("")
[void]$md.AppendLine("### Both-increased app-owned candidates (highest priority)")
if ($bothApp) { foreach ($d in $bothApp) { [void]$md.AppendLine((Format-Row $d)) } } else { [void]$md.AppendLine("- (none -- growth is in framework/BCL types; see memory-pressure list above)") }
[void]$md.AppendLine("")
[void]$md.AppendLine("### Retention containers / clues (who may be holding it)")
if ($containers) { foreach ($d in $containers) { [void]$md.AppendLine((Format-Row $d)) } } else { [void]$md.AppendLine("- (no growing container types detected)") }
[void]$md.AppendLine("")
[void]$md.AppendLine("### Selected candidates for root-chain analysis")
foreach ($c in $candidates) { [void]$md.AppendLine("- $c") }

$markdown = $md.ToString()
if ($OutMarkdown) { [System.IO.File]::WriteAllText($OutMarkdown, $markdown, (New-Object System.Text.UTF8Encoding($false))) }
if ($OutTypeList) { [System.IO.File]::WriteAllText($OutTypeList, ($candidates -join ','), (New-Object System.Text.UTF8Encoding($false))) }

Write-Output $markdown
