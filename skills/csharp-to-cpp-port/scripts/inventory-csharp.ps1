param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,

    # Where port-work files go. Default: <CppRoot>\port-work when -CppRoot is given, else .\port-work.
    [string]$OutputDirectory,
    [string]$CppRoot,

    # Optional sub-directory (relative to SourceRoot) the human assigned for this pass. The whole tree
    # is always scanned; the work list = in-scope units PLUS their not-yet-ported prerequisites, in
    # dependency order, so nothing is ever ported before what it depends on.
    [string]$Scope,

    [string[]]$ExcludeDirectory = @("bin", "obj", ".vs", "packages", "TestResults", "node_modules", ".git")
)

# Deterministic C# project inventory for the csharp-to-cpp-port skill.
# No model, no Roslyn: a regex-level scan (documented limitation), so flags can over/under-count.
# Units: a partial type split over several files (Form.cs + Form.Designer.cs) is ONE unit.
# Generated/metadata files (AssemblyInfo, *.g.cs, Resources/Settings.Designer.cs) are skipped, not ported.
# Windows PowerShell 5.1 compatible. ASCII-only source file.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Write-Fail {
    param([string]$Message, [int]$Code = 2)
    [Console]::Error.WriteLine("inventory-csharp: $Message")
    exit $Code
}

if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) { Write-Fail "SourceRoot is not an existing directory: $SourceRoot" }
$SourceRoot = (Resolve-Path -LiteralPath $SourceRoot).Path.TrimEnd('\')
if (-not $OutputDirectory) {
    if ($CppRoot) { New-Item -ItemType Directory -Force -Path $CppRoot | Out-Null; $OutputDirectory = Join-Path ((Resolve-Path -LiteralPath $CppRoot).Path) "port-work" }
    else { $OutputDirectory = Join-Path (Get-Location).Path "port-work" }
}
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path

$scopeRel = $null
if ($Scope) {
    $scopeFull = Join-Path $SourceRoot $Scope
    if (-not (Test-Path -LiteralPath $scopeFull -PathType Container)) { Write-Fail "Scope directory not found under SourceRoot: $Scope (resolved: $scopeFull)" }
    $scopeRel = ((Resolve-Path -LiteralPath $scopeFull).Path.Substring($SourceRoot.Length)).TrimStart('\')
}

# ---- collect files -------------------------------------------------------------------------
$excludeSet = @{}
foreach ($d in $ExcludeDirectory) { $excludeSet[$d.ToLowerInvariant()] = $true }
function Test-Excluded {
    param([string]$RelativePath)
    foreach ($seg in $RelativePath.Split('\')) { if ($excludeSet.ContainsKey($seg.ToLowerInvariant())) { return $true } }
    return $false
}
$csFiles = @(Get-ChildItem -LiteralPath $SourceRoot -Recurse -File -Filter *.cs | ForEach-Object {
    $rel = $_.FullName.Substring($SourceRoot.Length).TrimStart('\')
    if (-not (Test-Excluded $rel)) { $_ }
} | Sort-Object FullName)
if ($csFiles.Count -eq 0) { Write-Fail "No .cs files found under $SourceRoot (excluded directories: $($ExcludeDirectory -join ', '))" }

function Get-SkipReason {
    param([string]$Rel)
    $leaf = Split-Path -Leaf $Rel
    if ($leaf -ieq "AssemblyInfo.cs" -or $leaf -ieq "GlobalSuppressions.cs") { return "assembly metadata" }
    if ($leaf -match '\.g\.cs$' -or $leaf -match '\.g\.i\.cs$' -or $leaf -match '\.AssemblyAttributes\.cs$' -or $leaf -match '^TemporaryGeneratedFile_') { return "compiler-generated" }
    if ($leaf -ieq "Resources.Designer.cs" -or $leaf -ieq "Settings.Designer.cs") { return "resource/settings designer (map resources by hand)" }
    return $null
}

# ---- feature flags (regex, best-effort) ----------------------------------------------------
$flagPatterns = [ordered]@{
    "linq"        = '(?m)^\s*using\s+System\.Linq\s*;|\.(Select|Where|OrderBy|OrderByDescending|ToList|ToArray|ToDictionary|First|FirstOrDefault|Any|All|GroupBy|Sum|Count|Distinct|Aggregate|SelectMany)\s*\(|\bfrom\s+\w+\s+in\s+'
    "async"       = '\basync\b|\bawait\b|\bTask(<[^>]+>)?\b|\bValueTask\b'
    "event"       = '\bevent\s+[\w<>,\s]+\s+\w+\s*;|\+=\s*\(?\s*\w*\s*,?\s*\w*\)?\s*=>'
    "disposable"  = '\bIDisposable\b|\bDispose\s*\(|\busing\s*\(|\busing\s+var\b'
    "pinvoke"     = '\bDllImport\b|\bextern\b|\bMarshal\.'
    "reflection"  = '\bSystem\.Reflection\b|\.GetType\s*\(\s*\)|\btypeof\s*\(|\bActivator\.|\bGetMethod\s*\(|\bGetProperty\s*\(|\bAssembly\.'
    "unsafe"      = '\bunsafe\b|\bfixed\s*\(|\bstackalloc\b'
    "dynamic"     = '\bdynamic\b'
    "winforms"    = '\bSystem\.Windows\.Forms\b|\bInitializeComponent\s*\('
    "wpf"         = '\bSystem\.Windows\.(Controls|Media|Data|Input|Markup)\b|\bDependencyProperty\b|\bINotifyPropertyChanged\b'
    "threading"   = '\block\s*\(|\bThread\b|\bMonitor\.|\bMutex\b|\bSemaphore|\bInterlocked\.|\bConcurrentDictionary\b|\bThreadPool\b|\bTimer\b'
    "string-ops"  = '\bstring\.Format\s*\(|\$"|\bStringBuilder\b|\.Split\s*\(|\.Replace\s*\(|\.Substring\s*\(|\.PadLeft\s*\(|\.PadRight\s*\(|\.Trim\w*\s*\('
    "exceptions"  = '\bthrow\b|\btry\s*\{|\bcatch\b|\bfinally\b'
    "generics"    = '\bclass\s+\w+\s*<|\binterface\s+\w+\s*<|\bwhere\s+\w+\s*:'
    "inheritance" = '\b(class|struct)\s+\w+(\s*<[^>]*>)?\s*:\s*[A-Z]|\b(override|virtual|abstract)\b'
    "interface"   = '\binterface\s+\w+'
    "extension"   = '\(\s*this\s+[\w<>\[\]]+\s+\w+'
    "nested-type" = '(?m)^\s{8,}(?:public|internal|private|protected)?\s*(?:static\s+)?(class|struct|enum|interface)\s+\w+'
    "preprocessor" = '(?m)^\s*#(if|else|elif)\b'
    "yield"       = '\byield\s+(return|break)\b'
    "nullable"    = '\b\w+\?\s+\w+\s*(\{|;|=|,|\))|\bNullable<'
    "regex"       = '\bSystem\.Text\.RegularExpressions\b|\bRegex\b'
    "file-io"     = '\bSystem\.IO\b|\bFile\.|\bDirectory\.|\bStreamReader\b|\bStreamWriter\b|\bFileStream\b|\bPath\.'
    "serialization" = '\bSerializable\b|\bXmlSerializer\b|\bDataContract\b|\bJsonConvert\b|\bBinaryFormatter\b'
    "datetime"    = '\bDateTime\b|\bTimeSpan\b|\bStopwatch\b'
    "collections" = '\bList<|\bDictionary<|\bHashSet<|\bQueue<|\bStack<|\bIEnumerable<|\bObservableCollection<|\bSortedDictionary<'
}

function Remove-CommentsAndStrings {
    param([string]$Text)
    $t = [regex]::Replace($Text, '@"(?:[^"]|"")*"', '""')
    # Interpolated strings contain code: keep the {expressions}, drop the text.
    $t = [regex]::Replace($t, '\$"(?:[^"\\\r\n]|\\.)*"', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $inner = @([regex]::Matches($m.Value, '\{([^{}]*)\}') | ForEach-Object { $_.Groups[1].Value }); '(' + ($inner -join ' , ') + ')' })
    $t = [regex]::Replace($t, '"(?:[^"\\\r\n]|\\.)*"', '""')
    $t = [regex]::Replace($t, "'(?:[^'\\\\]|\\\\.)'", "''")
    $t = [regex]::Replace($t, '/\*.*?\*/', ' ', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $t = [regex]::Replace($t, '//[^\r\n]*', '')
    # #if DEBUG ... #else: keep the release branch only. Preprocessor lines (#region Helpers) are not code.
    $t = [regex]::Replace($t, '(?ms)^\s*#if\s+DEBUG\b.*?^\s*#else\b[^\r\n]*', '')
    $t = [regex]::Replace($t, '(?ms)^\s*#if\s+DEBUG\b.*?^\s*#endif\b[^\r\n]*', '')
    $t = [regex]::Replace($t, '(?m)^\s*#[^\r\n]*', '')
    return $t
}

$typeDeclRegex = [regex]'(?m)^\s*(?:\[[^\]]*\]\s*)*(?:(?:public|internal|private|protected|static|abstract|sealed|partial|readonly|unsafe|new)\s+)*(?<kind>class|struct|interface|enum|record)\s+(?<name>[A-Za-z_][A-Za-z0-9_]*)'
$delegateRegex = [regex]'(?m)^\s*(?:(?:public|internal|private|protected)\s+)*delegate\s+[\w<>\[\],\s\.]+?\s+(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*(?:<[^>]*>)?\s*\('
$namespaceRegex = [regex]'(?m)^\s*namespace\s+(?<ns>[A-Za-z_][\w\.]*)'
$usingRegex = [regex]'(?m)^\s*using\s+(?:static\s+)?(?<ns>[A-Za-z_][\w\.]*)\s*;'
$baseListRegex = [regex]'(?<kind>class|struct|interface|record)\s+(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*(?:<[^>]*>)?\s*:\s*(?<bases>[^{]+?)\s*(?:where\b|\{)'

# ---- per-file scan ---------------------------------------------------------------------------
$fileEntries = New-Object System.Collections.ArrayList
$skipped = New-Object System.Collections.ArrayList
foreach ($f in $csFiles) {
    $rel = $f.FullName.Substring($SourceRoot.Length).TrimStart('\')
    $skipReason = Get-SkipReason $rel
    if ($skipReason) { [void]$skipped.Add([ordered]@{ path = $rel; reason = $skipReason }); continue }
    $raw = [System.IO.File]::ReadAllText($f.FullName)
    $clean = Remove-CommentsAndStrings $raw
    $loc = ([regex]::Matches($raw, "\n")).Count + 1
    $types = New-Object System.Collections.ArrayList
    foreach ($m in $typeDeclRegex.Matches($clean)) { [void]$types.Add(@{ name = $m.Groups["name"].Value; kind = $m.Groups["kind"].Value }) }
    foreach ($m in $delegateRegex.Matches($clean)) { [void]$types.Add(@{ name = $m.Groups["name"].Value; kind = "delegate" }) }
    $namespaces = @($namespaceRegex.Matches($clean) | ForEach-Object { $_.Groups["ns"].Value } | Select-Object -Unique)
    $usings = @($usingRegex.Matches($clean) | ForEach-Object { $_.Groups["ns"].Value } | Select-Object -Unique)
    $bases = @($baseListRegex.Matches($clean) | ForEach-Object { ($_.Groups["bases"].Value -split ',') | ForEach-Object { ($_ -replace '<.*', '').Trim() } | Where-Object { $_ } } | Select-Object -Unique)
    $flags = [ordered]@{}
    foreach ($k in $flagPatterns.Keys) { $n = ([regex]::Matches($clean, $flagPatterns[$k])).Count; if ($n -gt 0) { $flags[$k] = $n } }
    $partialTypes = @([regex]::Matches($clean, '\bpartial\s+(?:class|struct|interface|record)\s+(?<name>[A-Za-z_]\w*)') | ForEach-Object { $_.Groups["name"].Value } | Select-Object -Unique)
    $extensionMethods = @([regex]::Matches($clean, '\bstatic\s+[\w<>\[\],\.]+\s+(?<name>[A-Za-z_]\w*)\s*(?:<[^>]*>)?\s*\(\s*this\s+') | ForEach-Object { $_.Groups["name"].Value } | Select-Object -Unique)
    [void]$fileEntries.Add(@{
        path = $rel; loc = $loc; namespaces = $namespaces; usings = $usings; types = @($types); bases = $bases; flags = $flags
        designer = [bool]($rel -match '\.Designer\.cs$'); partialTypes = $partialTypes; clean = $clean; extensionMethods = $extensionMethods
        ns = $(if ($namespaces.Count -gt 0) { $namespaces[0] } else { "" })
    })
}
if ($fileEntries.Count -eq 0) { Write-Fail "Every .cs file under $SourceRoot is generated/metadata (nothing to port)" }

# ---- units: merge files that declare the same partial type in the same namespace ------------
$fileByPath = @{}
foreach ($fe in $fileEntries) { $fileByPath[$fe.path] = $fe }
$groupOf = @{}   # file path -> group id (file path of representative)
function Find-Group { param([string]$P) $g = $P; while ($groupOf.ContainsKey($g) -and $groupOf[$g] -ne $g) { $g = $groupOf[$g] }; return $g }
function Union-Group { param([string]$A, [string]$B) $ra = Find-Group $A; $rb = Find-Group $B; if ($ra -ne $rb) { $groupOf[$rb] = $ra } }
foreach ($fe in $fileEntries) { $groupOf[$fe.path] = $fe.path }
$partialKey = @{}
foreach ($fe in $fileEntries) {
    foreach ($pt in $fe.partialTypes) {
        $key = $fe.ns + "|" + $pt
        if ($partialKey.ContainsKey($key)) { Union-Group $partialKey[$key] $fe.path } else { $partialKey[$key] = $fe.path }
    }
}
$groups = @{}
foreach ($fe in $fileEntries) { $g = Find-Group $fe.path; if (-not $groups.ContainsKey($g)) { $groups[$g] = New-Object System.Collections.ArrayList }; [void]$groups[$g].Add($fe.path) }

$units = New-Object System.Collections.ArrayList
foreach ($g in $groups.Keys) {
    $members = @($groups[$g] | Sort-Object)
    $primary = @($members | Where-Object { -not $fileByPath[$_].designer } | Sort-Object { $_.Length }, { $_ })
    $primary = if ($primary.Count -gt 0) { $primary[0] } else { $members[0] }
    $loc = 0; $typeList = New-Object System.Collections.ArrayList; $flags = [ordered]@{}; $nsList = @(); $usList = @(); $baseList = @(); $cleanAll = ""; $extList = @()
    foreach ($m in $members) {
        $fe = $fileByPath[$m]
        $loc += $fe.loc; $cleanAll += "`n" + $fe.clean
        foreach ($t in $fe.types) { if (@($typeList | Where-Object { $_.name -eq $t.name }).Count -eq 0) { [void]$typeList.Add($t) } }
        foreach ($k in $fe.flags.Keys) { if (-not $flags.Contains($k)) { $flags[$k] = 0 }; $flags[$k] += $fe.flags[$k] }
        $nsList += $fe.namespaces; $usList += $fe.usings; $baseList += $fe.bases; $extList += $fe.extensionMethods
    }
    $marks = @()
    if ($members.Count -gt 1) { $marks += "partial" }
    if (@($members | Where-Object { $fileByPath[$_].designer }).Count -gt 0) { $marks += "designer" }
    if ($flags.Contains("winforms") -or $flags.Contains("wpf")) { $marks += "ui" }
    [void]$units.Add(@{
        path = $primary; files = $members; loc = $loc; types = @($typeList); flags = $flags
        namespaces = @($nsList | Select-Object -Unique); usings = @($usList | Select-Object -Unique); bases = @($baseList | Select-Object -Unique)
        ns = $fileByPath[$primary].ns; clean = $cleanAll; marks = $marks; deps = @(); depTypes = @(); extensionMethods = @($extList | Select-Object -Unique)
        inScope = $(if ($scopeRel) { $primary.StartsWith($scopeRel + '\', [System.StringComparison]::OrdinalIgnoreCase) } else { $true })
    })
}
$units = @($units | Sort-Object { $_.path })
$unitByPath = @{}
foreach ($u in $units) { $unitByPath[$u.path] = $u }

# ---- type index (name -> declaring units) and dependency edges -----------------------------
$typeIndex = @{}
foreach ($u in $units) { foreach ($t in $u.types) { if (-not $typeIndex.ContainsKey($t.name)) { $typeIndex[$t.name] = New-Object System.Collections.ArrayList }; [void]$typeIndex[$t.name].Add($u) } }
$allNamespaces = @($units | ForEach-Object { $_.namespaces } | Select-Object -Unique)
$ambiguous = New-Object System.Collections.ArrayList
$duplicateTypes = @()
foreach ($name in ($typeIndex.Keys | Sort-Object)) { if ($typeIndex[$name].Count -gt 1) { $duplicateTypes += [ordered]@{ type = $name; units = @($typeIndex[$name] | ForEach-Object { $_.path }) } } }

function Resolve-Type {
    param($From, [string]$Name)
    $cands = @($typeIndex[$Name] | Where-Object { $_.path -ne $From.path })
    if ($cands.Count -eq 0) { return $null }
    if ($cands.Count -eq 1) { return $cands[0] }
    # C# lookup order: the unit's own namespace, then each enclosing namespace, then using directives.
    $own = @($From.namespaces | Where-Object { $_ })
    $chain = @()
    foreach ($ns in $own) {
        $parts = $ns.Split('.')
        for ($k = $parts.Count; $k -ge 1; $k--) { $chain += (($parts[0..($k - 1)]) -join '.') }
    }
    foreach ($ns in $chain) { foreach ($c in $cands) { if ($c.ns -eq $ns) { return $c } } }
    foreach ($u in @($From.usings)) { foreach ($c in $cands) { if ($c.ns -eq $u) { return $c } } }
    foreach ($u in @($From.usings)) { foreach ($c in $cands) { if ($u -and $c.ns.StartsWith($u + ".")) { return $c } } }
    [void]$ambiguous.Add(("{0} uses {1}; candidates: {2}; picked {3}" -f $From.path, $Name, (($cands | ForEach-Object { $_.path }) -join ', '), $cands[0].path))
    return $cands[0]
}
foreach ($u in $units) {
    $own = @{}; foreach ($t in $u.types) { $own[$t.name] = $true }
    $depUnits = New-Object System.Collections.ArrayList; $depTypes = New-Object System.Collections.ArrayList
    foreach ($name in $typeIndex.Keys) {
        if ($own.ContainsKey($name)) { continue }
        $esc = [regex]::Escape($name)
        # bare use (not a member access, not a call of a same-named method), `new T(`, or namespace-qualified `Ns.T`.
        # A same-named MEMBER declaration (`public string Kind { get; }`, `int Kind;`, `Kind = x`) is not a type use.
        $bareCount = ([regex]::Matches($u.clean, "(?<![\w\.])$esc\b(?!\s*\()")).Count
        $memberCount = ([regex]::Matches($u.clean, "(?<=[\w>\]]\s+)$esc\b(?=\s*[{;=,)])")).Count
        $bare = ($bareCount -gt $memberCount) -or [regex]::IsMatch($u.clean, "\bnew\s+$esc\s*[\(\[{<]")
        if (-not $bare) {
            foreach ($qm in [regex]::Matches($u.clean, "(?<![\w\.])(?<q>(?:[A-Za-z_]\w*\.)+)$esc\b")) {
                $q = $qm.Groups["q"].Value.TrimEnd('.')
                if (@($allNamespaces | Where-Object { $_ -eq $q -or $_.EndsWith("." + $q) }).Count -gt 0) { $bare = $true; break }
            }
        }
        if (-not $bare) { continue }
        $target = Resolve-Type -From $u -Name $name
        if ($null -eq $target) { continue }
        [void]$depTypes.Add($name)
        if (-not $depUnits.Contains($target.path)) { [void]$depUnits.Add($target.path) }
    }
    # Extension methods are reached without naming their static class: match `.Name(` calls.
    foreach ($other in $units) {
        if ($other.path -eq $u.path -or @($other.extensionMethods).Count -eq 0) { continue }
        foreach ($em in $other.extensionMethods) {
            if ([regex]::IsMatch($u.clean, "\.\s*" + [regex]::Escape($em) + "\s*\(")) {
                [void]$depTypes.Add($em + "()")
                if (-not $depUnits.Contains($other.path)) { [void]$depUnits.Add($other.path) }
            }
        }
    }
    $u.deps = @($depUnits | Sort-Object); $u.depTypes = @($depTypes | Sort-Object)
}

# ---- ownership hints (computed, so the model never decides): SHARED vs SINGLE per class type ----
# SHARED: the instance can be reached from more than one holder (collection element, event argument,
# method/constructor parameter or return, static field). SINGLE: only created and used by one owner.
$allClean = ($units | ForEach-Object { $_.clean }) -join "`n"
$ownership = [ordered]@{}
foreach ($u in $units) {
    foreach ($t in $u.types) {
        if ($t.kind -notin @("class", "record")) { continue }
        $name = $t.name
        if ([regex]::IsMatch($u.clean, "\bstatic\s+(?:partial\s+)?class\s+$([regex]::Escape($name))\b")) { continue }   # namespace of free functions
        $esc = [regex]::Escape($name)
        $shared = $false
        $reasons = @()
        if ([regex]::IsMatch($allClean, "\b(?:List|IList|IReadOnlyList|IEnumerable|ICollection|IReadOnlyCollection|HashSet|Queue|Stack|ObservableCollection|BindingList)\s*<\s*$esc\s*>|\bDictionary\s*<[^>]*,\s*$esc\s*>|\b$esc\s*\[\s*\]")) { $shared = $true; $reasons += "collection element" }
        if ([regex]::IsMatch($allClean, "\bevent\s+\w+\s*<\s*$esc\s*>")) { $shared = $true; $reasons += "event argument" }
        if ([regex]::IsMatch($allClean, "\(\s*(?:[^()]*,\s*)?$esc\s+\w+\s*[,)=]")) { $shared = $true; $reasons += "parameter" }
        if ([regex]::IsMatch($allClean, "(?m)^\s*(?:public|internal|protected|private)\s+(?:static\s+|virtual\s+|override\s+|abstract\s+)*$esc\s+\w+\s*\(")) { $shared = $true; $reasons += "return value" }
        if ([regex]::IsMatch($allClean, "\bstatic\s+(?:readonly\s+)?$esc\s+\w+")) { $shared = $true; $reasons += "static field" }
        $polymorphic = (@($u.bases).Count -gt 0) -or [regex]::IsMatch($u.clean, "\b(?:abstract|virtual)\s+")
        $ownership[$name] = [ordered]@{ mode = $(if ($shared) { "shared" } else { "single" }); polymorphic = [bool]$polymorphic; reasons = @($reasons); unit = $u.path }
    }
}

# ---- strongly connected components (iterative Tarjan) + condensation order -------------------
$index = 0; $stack = New-Object System.Collections.ArrayList; $onStack = @{}; $idx = @{}; $low = @{}; $sccOf = @{}; $sccs = New-Object System.Collections.ArrayList
foreach ($start in $units) {
    if ($idx.ContainsKey($start.path)) { continue }
    $work = New-Object System.Collections.ArrayList
    [void]$work.Add(@{ node = $start.path; i = 0 })
    $idx[$start.path] = $index; $low[$start.path] = $index; $index++; [void]$stack.Add($start.path); $onStack[$start.path] = $true
    while ($work.Count -gt 0) {
        $frame = $work[$work.Count - 1]
        $v = $frame.node; $deps = $unitByPath[$v].deps
        if ($frame.i -lt $deps.Count) {
            $w = $deps[$frame.i]; $frame.i++
            if (-not $idx.ContainsKey($w)) {
                $idx[$w] = $index; $low[$w] = $index; $index++; [void]$stack.Add($w); $onStack[$w] = $true
                [void]$work.Add(@{ node = $w; i = 0 })
            }
            elseif ($onStack.ContainsKey($w)) { $low[$v] = [Math]::Min($low[$v], $idx[$w]) }
        }
        else {
            if ($low[$v] -eq $idx[$v]) {
                $comp = New-Object System.Collections.ArrayList
                do { $w = $stack[$stack.Count - 1]; $stack.RemoveAt($stack.Count - 1); $onStack.Remove($w); [void]$comp.Add($w) } while ($w -ne $v)
                $compSorted = @($comp | Sort-Object)
                foreach ($c in $compSorted) { $sccOf[$c] = $sccs.Count }
                [void]$sccs.Add($compSorted)
            }
            $work.RemoveAt($work.Count - 1)
            if ($work.Count -gt 0) { $parent = $work[$work.Count - 1].node; $low[$parent] = [Math]::Min($low[$parent], $low[$v]) }
        }
    }
}
$cycleGroups = @($sccs | Where-Object { $_.Count -gt 1 })
# Kahn over the condensation, deterministic (smallest representative path first); members of an SCC stay together.
$sccDeps = @{}; $sccIndeg = @{}
for ($s = 0; $s -lt $sccs.Count; $s++) { $sccDeps[$s] = @{}; $sccIndeg[$s] = 0 }
foreach ($u in $units) { foreach ($d in $u.deps) { $a = $sccOf[$u.path]; $b = $sccOf[$d]; if ($a -ne $b -and -not $sccDeps[$a].ContainsKey($b)) { $sccDeps[$a][$b] = $true } } }
foreach ($s in $sccDeps.Keys) { $sccIndeg[$s] = $sccDeps[$s].Count }
$sccDependents = @{}
foreach ($a in $sccDeps.Keys) { foreach ($b in $sccDeps[$a].Keys) { if (-not $sccDependents.ContainsKey($b)) { $sccDependents[$b] = New-Object System.Collections.ArrayList }; [void]$sccDependents[$b].Add($a) } }
$order = New-Object System.Collections.ArrayList
$remaining = @{}; for ($s = 0; $s -lt $sccs.Count; $s++) { $remaining[$s] = $true }
while ($remaining.Count -gt 0) {
    $ready = @($remaining.Keys | Where-Object { $sccIndeg[$_] -eq 0 } | Sort-Object { $sccs[$_][0] })
    if ($ready.Count -eq 0) { $ready = @(@($remaining.Keys | Sort-Object { $sccs[$_][0] })[0]) }   # cannot happen on a DAG; safety
    foreach ($s in $ready) {
        foreach ($member in $sccs[$s]) { [void]$order.Add($member) }
        $remaining.Remove($s)
        if ($sccDependents.ContainsKey($s)) { foreach ($dep in $sccDependents[$s]) { if ($remaining.ContainsKey($dep)) { $sccIndeg[$dep] = [Math]::Max(0, $sccIndeg[$dep] - 1) } } }
    }
}

# ---- work list: in-scope units + their transitive prerequisites ------------------------------
$inWork = @{}
if ($scopeRel) {
    $queue = New-Object System.Collections.ArrayList
    foreach ($u in $units) { if ($u.inScope) { $inWork[$u.path] = "scope"; [void]$queue.Add($u.path) } }
    while ($queue.Count -gt 0) {
        $p = $queue[0]; $queue.RemoveAt(0)
        foreach ($d in $unitByPath[$p].deps) { if (-not $inWork.ContainsKey($d)) { $inWork[$d] = "prereq"; [void]$queue.Add($d) } }
    }
}
else { foreach ($u in $units) { $inWork[$u.path] = "scope" } }

# ---- project kind guess ----------------------------------------------------------------------
$csprojs = @(Get-ChildItem -LiteralPath $SourceRoot -Recurse -File -Filter *.csproj | Where-Object { -not (Test-Excluded $_.FullName.Substring($SourceRoot.Length).TrimStart('\')) })
$outputTypes = @(); $targetFrameworks = @()
$projects = New-Object System.Collections.ArrayList
foreach ($p in $csprojs) {
    $x = [System.IO.File]::ReadAllText($p.FullName)
    $rel = $p.FullName.Substring($SourceRoot.Length).TrimStart('\')
    $out = "Library"; $tfm = ""
    foreach ($m in [regex]::Matches($x, '<OutputType>\s*([^<]+?)\s*</OutputType>')) { $outputTypes += $m.Groups[1].Value; $out = $m.Groups[1].Value }
    foreach ($m in [regex]::Matches($x, '<TargetFramework(?:s|Version)?>\s*([^<]+?)\s*</TargetFramework(?:s|Version)?>')) { $targetFrameworks += $m.Groups[1].Value; $tfm = $m.Groups[1].Value }
    $refs = @([regex]::Matches($x, '<ProjectReference\s+Include\s*=\s*"([^"]+)"') | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Groups[1].Value) })
    $pkgs = @([regex]::Matches($x, '<(?:PackageReference|Reference)\s+Include\s*=\s*"([^",]+)') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -notmatch '^(System|Microsoft\.CSharp|mscorlib|PresentationCore|PresentationFramework|WindowsBase)($|\.)' } | Select-Object -Unique)
    [void]$projects.Add([ordered]@{
        name = [System.IO.Path]::GetFileNameWithoutExtension($p.Name); file = $rel
        dir = $(if ($rel.Contains('\')) { Split-Path -Parent $rel } else { "" })
        outputType = $out; targetFramework = $tfm; projectReferences = @($refs); externalReferences = @($pkgs); unitCount = 0
    })
}
# A unit belongs to the project whose directory is the longest prefix of its path.
function Get-OwningProject {
    param([string]$UnitPath)
    $best = $null; $bestLen = -1
    foreach ($pr in $projects) {
        $d = $pr.dir
        $match = ($d -eq "") -or $UnitPath.StartsWith($d + '\', [System.StringComparison]::OrdinalIgnoreCase)
        if ($match -and $d.Length -gt $bestLen) { $best = $pr; $bestLen = $d.Length }
    }
    if ($null -eq $best) { return "(no csproj)" }
    return $best.name
}
foreach ($u in $units) { $u.project = Get-OwningProject $u.path }
foreach ($pr in $projects) { $pr.unitCount = @($units | Where-Object { $_.project -eq $pr.name }).Count }
$xamlCount = @(Get-ChildItem -LiteralPath $SourceRoot -Recurse -File -Filter *.xaml | Where-Object { -not (Test-Excluded $_.FullName.Substring($SourceRoot.Length).TrimStart('\')) }).Count
$totalFlag = [ordered]@{}
foreach ($k in $flagPatterns.Keys) { $sum = 0; foreach ($u in $units) { if ($u.flags.Contains($k)) { $sum += $u.flags[$k] } }; if ($sum -gt 0) { $totalFlag[$k] = $sum } }
$kindGuess = "console-or-library"
if ($xamlCount -gt 0 -or $totalFlag.Contains("wpf")) { $kindGuess = "wpf" }
elseif ($totalFlag.Contains("winforms")) { $kindGuess = "winforms" }
elseif (@($units | Where-Object { $_.bases -contains "ServiceBase" }).Count -gt 0) { $kindGuess = "windows-service" }
if ($outputTypes -contains "WinExe" -and $kindGuess -eq "console-or-library") { $kindGuess = "winexe" }

# ---- outputs ---------------------------------------------------------------------------------
$totalLoc = 0; foreach ($u in $units) { $totalLoc += [int]$u.loc }
# Project-level port order = first appearance of each project in the dependency-ordered unit list.
$projectOrder = @(); $seenProj = @{}
foreach ($pp in $order) { $pn = $unitByPath[$pp].project; if (-not $seenProj.ContainsKey($pn)) { $seenProj[$pn] = $true; $projectOrder += $pn } }
# Edges that cross a project boundary: these are the shared components every plan must respect.
$crossEdges = New-Object System.Collections.ArrayList
foreach ($u in $units) {
    foreach ($d in $u.deps) {
        $du = $unitByPath[$d]
        if ($du.project -ne $u.project) {
            $usedTypes = @($u.depTypes | Where-Object { $tn = $_; @($du.types | Where-Object { $_.name -eq $tn }).Count -gt 0 })
            [void]$crossEdges.Add([ordered]@{ fromProject = $u.project; fromUnit = $u.path; toProject = $du.project; toUnit = $du.path; types = @($usedTypes) })
        }
    }
}
$jsonUnits = @()
foreach ($p in $order) {
    $u = $unitByPath[$p]
    $sccId = $sccOf[$p]; $inCycle = ($sccs[$sccId].Count -gt 1)
    $marks = @($u.marks); if ($inCycle) { $marks += "cycle" }
    if ($inWork.ContainsKey($p) -and $inWork[$p] -eq "prereq") { $marks += "prereq" }
    $jsonUnits += [ordered]@{
        path = $u.path; files = @($u.files); loc = $u.loc; namespaces = @($u.namespaces); usings = @($u.usings)
        types = @($u.types | ForEach-Object { [ordered]@{ name = $_.name; kind = $_.kind } }); bases = @($u.bases)
        flags = $u.flags; deps = @($u.deps); depTypes = @($u.depTypes); marks = @($marks); extensionMethods = @($u.extensionMethods)
        inScope = [bool]$u.inScope; inWorkList = $inWork.ContainsKey($p); prereq = ($inWork.ContainsKey($p) -and $inWork[$p] -eq "prereq")
        inCycle = $inCycle; cycleGroup = $(if ($inCycle) { $sccId } else { $null }); project = $u.project
    }
}
$inventory = [ordered]@{
    generator = "csharp-to-cpp-port/inventory-csharp.ps1"; generatedAt = [DateTimeOffset]::Now.ToString("o")
    sourceRoot = $SourceRoot; cppRoot = $(if ($CppRoot) { (Resolve-Path -LiteralPath $CppRoot).Path } else { $null }); scope = $scopeRel
    projectKindGuess = $kindGuess
    csproj = @($csprojs | ForEach-Object { $_.FullName.Substring($SourceRoot.Length).TrimStart('\') })
    outputTypes = @($outputTypes | Select-Object -Unique); targetFrameworks = @($targetFrameworks | Select-Object -Unique)
    fileCount = $csFiles.Count; unitCount = $units.Count; skippedCount = $skipped.Count; totalLoc = $totalLoc
    flagTotals = $totalFlag
    cycles = @($cycleGroups | ForEach-Object { , @($_) })
    duplicateTypes = @($duplicateTypes); ambiguousReferences = @($ambiguous)
    projects = @($projects); projectOrder = @($projectOrder); crossProjectEdges = @($crossEdges)
    ownership = $ownership
    skipped = @($skipped)
    units = $jsonUnits
}
[System.IO.File]::WriteAllText((Join-Path $OutputDirectory "inventory.json"), ($inventory | ConvertTo-Json -Depth 8), $utf8)

# PORT_ORDER.txt: index<TAB>unit<TAB>lines<TAB>flags<TAB>marks<TAB>files(+)
$orderLines = New-Object System.Collections.ArrayList; $i = 0
foreach ($ju in $jsonUnits) {
    if (-not $ju.inWorkList) { continue }
    $i++
    $fl = (@($ju.flags.Keys | ForEach-Object { "$_=$($ju.flags[$_])" }) -join ',')
    [void]$orderLines.Add(("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}" -f $i, $ju.path, $ju.loc, $fl, ($ju.marks -join ','), ($ju.files -join '+'), $ju.project))
}
[System.IO.File]::WriteAllText((Join-Path $OutputDirectory "PORT_ORDER.txt"), (($orderLines -join "`n") + "`n"), $utf8)

$extLines = New-Object System.Collections.ArrayList
if ($scopeRel) {
    foreach ($ju in $jsonUnits) {
        if (-not $ju.inScope) { continue }
        foreach ($d in $ju.deps) {
            $du = $unitByPath[$d]
            if ($du.inScope) { continue }
            $usedTypes = @($ju.depTypes | Where-Object { $tn = $_; @($du.types | Where-Object { $_.name -eq $tn }).Count -gt 0 })
            [void]$extLines.Add(("{0}`t->`t{1}`t{2}" -f $ju.path, $d, ($usedTypes -join ',')))
        }
    }
    [System.IO.File]::WriteAllText((Join-Path $OutputDirectory "EXTERNAL_DEPS.txt"), (($extLines -join "`n") + "`n"), $utf8)
}

$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine("# PORT_INVENTORY"); [void]$md.AppendLine("")
[void]$md.AppendLine("- Source root: ``$SourceRoot``")
[void]$md.AppendLine("- Scope (this pass): " + $(if ($scopeRel) { "``$scopeRel``" } else { "(whole project)" }))
[void]$md.AppendLine("- Project kind guess: **$kindGuess** (csproj OutputType: $(if ($outputTypes) { $outputTypes -join ', ' } else { 'n/a' }); TargetFramework: $(if ($targetFrameworks) { $targetFrameworks -join ', ' } else { 'n/a' }))")
[void]$md.AppendLine("- Files: $($csFiles.Count) .cs (excluding $($ExcludeDirectory -join ', ')); units: $($units.Count); skipped: $($skipped.Count); total lines: $totalLoc")
[void]$md.AppendLine("- Work list this pass: $i unit(s)" + $(if ($scopeRel) { " (in-scope + prerequisites)" } else { "" }))
if ($cycleGroups.Count -gt 0) {
    $cycText = (@($cycleGroups | ForEach-Object { "{" + (($_ | ForEach-Object { '`' + $_ + '`' }) -join ', ') + "}" }) -join '; ')
    [void]$md.AppendLine("- Dependency cycles (port each group together; forward-declare inside the group): $cycText")
}
if ($duplicateTypes.Count -gt 0) {
    $dupText = (@($duplicateTypes | ForEach-Object { '`' + $_.type + '` (' + ($_.units -join ', ') + ')' }) -join '; ')
    [void]$md.AppendLine("- Same type name in more than one unit (resolved by namespace where possible): $dupText")
}
if ($ambiguous.Count -gt 0) { [void]$md.AppendLine("- Ambiguous references (check by hand): $($ambiguous.Count), see inventory.json ambiguousReferences") }
if ($projects.Count -gt 1) {
    [void]$md.AppendLine(""); [void]$md.AppendLine("## Projects (port in this order; shared components come first)")
    [void]$md.AppendLine("")
    [void]$md.AppendLine("| # | Project | Output | Units | Depends on (csproj) | External references |")
    [void]$md.AppendLine("|---|---------|--------|-------|---------------------|---------------------|")
    $pi = 0
    foreach ($pn in $projectOrder) {
        $pi++
        $pr = @($projects | Where-Object { $_.name -eq $pn })
        if ($pr.Count -eq 0) { [void]$md.AppendLine("| $pi | $pn | (no csproj) | $(@($units | Where-Object { $_.project -eq $pn }).Count) | | |"); continue }
        $pr = $pr[0]
        [void]$md.AppendLine("| $pi | $($pr.name) | $($pr.outputType) | $($pr.unitCount) | $(@($pr.projectReferences) -join ', ') | $(@($pr.externalReferences) -join ', ') |")
    }
    [void]$md.AppendLine("")
    [void]$md.AppendLine("All projects are ported into ONE C++ root and one dependency-ordered work list: a shared type is")
    [void]$md.AppendLine("ported once, and both consumers include the same header. Splitting the result into per-project")
    [void]$md.AppendLine("libraries/executables is a build-system step at the end (see the targets decision in DECISIONS.md).")
    if ($crossEdges.Count -gt 0) {
        [void]$md.AppendLine("")
        [void]$md.AppendLine("### Cross-project dependencies ($($crossEdges.Count))")
        [void]$md.AppendLine("")
        [void]$md.AppendLine("| From project | Unit | Uses | From project (shared) | Unit |")
        [void]$md.AppendLine("|---|---|---|---|---|")
        foreach ($e in ($crossEdges | Select-Object -First 40)) {
            [void]$md.AppendLine("| $($e.fromProject) | ``$($e.fromUnit)`` | $(@($e.types) -join ', ') | $($e.toProject) | ``$($e.toUnit)`` |")
        }
        if ($crossEdges.Count -gt 40) { [void]$md.AppendLine("") ; [void]$md.AppendLine("(+$($crossEdges.Count - 40) more in inventory.json crossProjectEdges)") }
    }
}
[void]$md.AppendLine(""); [void]$md.AppendLine("## Feature totals (regex counts, best-effort)"); [void]$md.AppendLine("")
if ($totalFlag.Count -eq 0) { [void]$md.AppendLine("(none detected)") }
foreach ($k in $totalFlag.Keys) { [void]$md.AppendLine("- $k`: $($totalFlag[$k])") }
[void]$md.AppendLine(""); [void]$md.AppendLine("Decisions needed from a human before porting: winforms/wpf (UI framework), pinvoke (which DLLs), reflection, unsafe, dynamic, threading.")
[void]$md.AppendLine(""); [void]$md.AppendLine("## Units in dependency order"); [void]$md.AppendLine("")
[void]$md.AppendLine("| # | Unit | Files | Lines | Types | Depends on | Flags | Marks |")
[void]$md.AppendLine("|---|------|-------|-------|-------|------------|-------|-------|")
$n = 0
foreach ($ju in $jsonUnits) {
    $n++
    $typeNames = (@($ju.types | ForEach-Object { "$($_.name) ($($_.kind))" }) -join ', ')
    $fl = (@($ju.flags.Keys | ForEach-Object { "$_=$($ju.flags[$_])" }) -join ' ')
    $depsCell = (@($ju.deps | ForEach-Object { '`' + $_ + '`' }) -join ', ')
    $marksCell = ($ju.marks + $(if (-not $ju.inWorkList) { @("out-of-scope") } else { @() })) -join ', '
    [void]$md.AppendLine("| $n | ``$($ju.path)`` | $($ju.files.Count) | $($ju.loc) | $typeNames | $depsCell | $fl | $marksCell |")
}
if ($skipped.Count -gt 0) {
    [void]$md.AppendLine(""); [void]$md.AppendLine("## Skipped files (not ported)"); [void]$md.AppendLine("")
    foreach ($s in $skipped) { [void]$md.AppendLine("- ``$($s.path)``: $($s.reason)") }
}
[void]$md.AppendLine(""); [void]$md.AppendLine("## Files"); [void]$md.AppendLine("")
[void]$md.AppendLine("- ``inventory.json``: machine-readable form used by make-unit-prompt.ps1 / port-status.ps1")
[void]$md.AppendLine("- ``PORT_ORDER.txt``: work list (dependency order; ``prereq`` marks out-of-scope units that must be ported first)")
if ($scopeRel) { [void]$md.AppendLine("- ``EXTERNAL_DEPS.txt``: in-scope unit -> out-of-scope unit it depends on (types used)") }
[void]$md.AppendLine("- ``PORT_STATUS.md``: per-unit progress (managed by port-status.ps1)")
[void]$md.AppendLine(""); [void]$md.AppendLine("Limitation: this inventory is a regex scan, not a compiler. Counts are approximate; a type reached only through inheritance or an extension method may be missed; check ambiguous references by hand.")
[System.IO.File]::WriteAllText((Join-Path $OutputDirectory "PORT_INVENTORY.md"), $md.ToString(), $utf8)

$statusJson = Join-Path $OutputDirectory "status.json"
if (-not (Test-Path -LiteralPath $statusJson)) {
    $status = [ordered]@{ updatedAt = [DateTimeOffset]::Now.ToString("o"); units = @() }
    foreach ($ju in $jsonUnits) { $status.units += [ordered]@{ unit = $ju.path; state = "todo"; updatedAt = ""; note = "" } }
    foreach ($s in $skipped) { $status.units += [ordered]@{ unit = $s.path; state = "skipped"; updatedAt = ""; note = $s.reason } }
    [System.IO.File]::WriteAllText($statusJson, ($status | ConvertTo-Json -Depth 4), $utf8)
    & (Join-Path $PSScriptRoot "port-status.ps1") -WorkDir $OutputDirectory -Show | Out-Null
}

# ---- decision log: every standing default that a human must eventually confirm ------------------
# -Include is silently ignored next to -LiteralPath, so match on the file name instead.
$appConfigCount = @(Get-ChildItem -LiteralPath $SourceRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object { ($_.Name -ieq "App.config" -or $_.Name -ieq "Web.config") -and -not (Test-Excluded $_.FullName.Substring($SourceRoot.Length).TrimStart('\')) }).Count
$seed = New-Object System.Collections.ArrayList
function Add-Seed {
    param([string]$Id, [string]$Topic, [string]$Decision, [string]$Rationale, [string]$Review, [string]$Affects = "all units")
    [void]$seed.Add([pscustomobject]@{ id = $Id; topic = $Topic; decision = $Decision; source = "default"; rationale = $Rationale; review = $Review; affects = $Affects; status = "pending"; updatedAt = [DateTimeOffset]::Now.ToString("s") })
}
Add-Seed "std" "C++ standard" "C++17" "PortSupport.h uses std::filesystem, std::optional, [[nodiscard]] and nested namespaces." "Needs VS2017 15.7+ / GCC 8+. On an older toolchain the support header must be rewritten."
Add-Seed "string" "String type" "std::wstring (UTF-16)" "Same encoding as .NET string and the Win32 W API, so no conversion at API boundaries." "A UTF-8 std::string codebase would be smaller but converts on every Win32 call."
Add-Seed "ownership" "Object ownership" "computed per type: SHARED -> std::shared_ptr, SINGLE -> value, SINGLE+polymorphic -> std::unique_ptr" "Computed by the inventory from how each type is used, so the model never guesses." "Reference counting where C# had a GC can keep objects alive longer than expected; check cycles and hot paths."
if ($totalFlag.Contains("async")) { Add-Seed "async" "async/await" "ported synchronously, marked TODO(port): was async" "A weak model cannot design a threading model; a synchronous port is always correct in behaviour, not in latency." "Anything that relied on not blocking the caller (UI responsiveness, parallel IO) must be redesigned by hand." }
if ($totalFlag.Contains("threading")) { Add-Seed "threading" "Thread / Timer / ThreadPool" "no threads introduced; synchronous call + TODO(port): threading" "Same reason as async: concurrency is a human design decision." "Every TODO(port): threading site needs a real decision (std::thread, timer queue, or restructure)." }
if ($totalFlag.Contains("collections")) { Add-Seed "dict-order" "Dictionary enumeration order" "std::unordered_map (order not reproduced)" ".NET Dictionary happens to enumerate in insertion order; C++ does not guarantee any order." "Any output or logic that depended on that order needs an explicit insertion-order vector." }
if ($totalFlag.Contains("datetime")) { Add-Seed "datetime" "DateTime / TimeSpan" "std::chrono + std::put_time for the format patterns actually used" "Direct chrono mapping keeps arithmetic exact." "Culture-specific and unusual format strings are marked TODO(port): date format." }
if ($totalFlag.Contains("pinvoke")) { Add-Seed "pinvoke" "P/Invoke" "the Win32 function is called directly behind the same name" "The native side no longer needs marshalling." "Structure layouts, string marshalling and error handling must be re-checked per call." }
if ($totalFlag.Contains("reflection")) { Add-Seed "reflection" "Reflection" "not ported; marked TODO(port)" "C++ has no runtime type discovery equivalent." "Every reflection site needs a hand-written alternative (factory table, visitor, code generation)." }
if ($totalFlag.Contains("serialization")) { Add-Seed "serialization" "Serialization" "not ported; marked TODO(port)" "XmlSerializer / DataContract have no drop-in C++ equivalent." "Pick a library or hand-write the reader/writer; the on-disk format must stay compatible." }
if ($appConfigCount -gt 0) { Add-Seed "config" "App.config / ConfigurationManager" "appSettings read from <exe>.ini via PortSupport::AppSetting (convert-appconfig.ps1 generates it)" "No XML dependency, no runtime configuration framework." "connectionStrings, custom sections and configSections are NOT converted; handle them by hand." }
if ($kindGuess -eq "winforms" -or $kindGuess -eq "wpf") { Add-Seed "ui" "UI framework" "UNDECIDED - ui units stay todo until port-work\mapping-extra.md exists" "WinForms/WPF have no mechanical C++ equivalent; the human picks Win32, MFC or Qt." "WPF XAML, data binding and MVVM cannot be ported mechanically at all: plan a rewrite of the UI layer." (@($units | Where-Object { @($_.marks) -contains 'ui' } | ForEach-Object { $_.path }) -join ', ') }
if ($projects.Count -gt 1) { Add-Seed "targets" "Build targets" "one flat C++ tree; per-project libraries/executables are NOT generated" "The port is ordered by type dependencies, not by assembly boundaries." "If the six components must stay separate binaries, write the CMake targets by hand at the end (project list is in PORT_INVENTORY.md)." (($projectOrder) -join ', ') }
$decisionsJson = Join-Path $OutputDirectory "decisions.json"
$existing = @()
if (Test-Path -LiteralPath $decisionsJson) { $existing = @((Get-Content -Raw -LiteralPath $decisionsJson | ConvertFrom-Json).decisions) }
$known = @{}
foreach ($e in $existing) { $known[$e.id] = $true }
$addedDecisions = 0
foreach ($sd in $seed) { if (-not $known.ContainsKey($sd.id)) { $existing += $sd; $addedDecisions++ } }
if ($addedDecisions -gt 0 -or -not (Test-Path -LiteralPath $decisionsJson)) {
    [System.IO.File]::WriteAllText($decisionsJson, ([pscustomobject]@{ generatedAt = [DateTimeOffset]::Now.ToString("o"); decisions = $existing } | ConvertTo-Json -Depth 5), $utf8)
    & (Join-Path $PSScriptRoot "record-decision.ps1") -WorkDir $OutputDirectory -Render | Out-Null
}
$pendingDecisions = @($existing | Where-Object { $_.status -ne "accepted" }).Count

Write-Host "inventory-csharp: $($csFiles.Count) files -> $($units.Count) units ($($skipped.Count) skipped), work list $i, kind=$kindGuess"
Write-Host "  $OutputDirectory\PORT_INVENTORY.md"
Write-Host "  $OutputDirectory\PORT_ORDER.txt"
if ($scopeRel) { Write-Host "  $OutputDirectory\EXTERNAL_DEPS.txt ($($extLines.Count) external dependencies)" }
if ($cycleGroups.Count -gt 0) { Write-Host "  WARNING: $($cycleGroups.Count) dependency cycle group(s); see PORT_INVENTORY.md" }
if ($ambiguous.Count -gt 0) { Write-Host "  WARNING: $($ambiguous.Count) ambiguous type reference(s); see inventory.json" }
if ($projects.Count -gt 1) { Write-Host "  Projects: $($projects.Count) ($($projectOrder -join ' -> ')); cross-project dependencies: $($crossEdges.Count)" }
Write-Host "  $OutputDirectory\DECISIONS.md ($pendingDecisions decision(s) pending review)"
exit 0
