param(
    # Unit from PORT_ORDER.txt: its primary path, any member file of a partial unit, or its 1-based index.
    [Parameter(Mandatory = $true)]
    [string]$Unit,

    # Root of the C++ output tree (ported headers are looked up here as <unit path>.h).
    [Parameter(Mandatory = $true)]
    [string]$CppRoot,

    [string]$WorkDir,

    # agent: the model writes files with its own file tool and replies with the paths.
    # paste: the model replies with "// FILE:" + fenced blocks for apply-unit-response.ps1.
    [ValidateSet("agent", "paste")]
    [string]$Mode = "agent",

    [string]$MappingTable,
    [string]$Rules,
    [string]$Template,
    [string]$Example,
    [switch]$NoExample,
    [string]$ExtraNote,
    [string]$OutputPath
)

# Assembles the translation prompt for ONE unit deterministically:
# mapping table + rules + the C# source(s) + declarations of dependencies + the last build errors.
# Dependencies already ported are embedded as their real headers (authoritative). Dependencies not
# ported yet are shown as C# declarations (bodies removed) with an explicit "port that unit first"
# instruction: nothing is compiled against guessed stubs.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0
$utf8 = New-Object System.Text.UTF8Encoding($false)
$skillRoot = Split-Path -Parent $PSScriptRoot
$scriptsDir = $PSScriptRoot
$refDir = Join-Path $skillRoot "references"
if (-not $MappingTable) { $MappingTable = Join-Path $refDir "mapping-table.md" }
if (-not $Rules) { $Rules = Join-Path $refDir "porting-rules.md" }
if (-not $Template) { $Template = Join-Path $refDir "unit-prompt-template.md" }
if (-not $Example) { $Example = Join-Path $refDir "example-port.md" }
$supportHeader = Join-Path $refDir "PortSupport.h"

function Write-Fail { param([string]$Message) [Console]::Error.WriteLine("make-unit-prompt: $Message"); exit 2 }

if (-not (Test-Path -LiteralPath $CppRoot)) { New-Item -ItemType Directory -Force -Path $CppRoot | Out-Null }
$CppRoot = (Resolve-Path -LiteralPath $CppRoot).Path.TrimEnd('\')
if (-not $WorkDir) { $WorkDir = Join-Path $CppRoot "port-work" }
$inventoryPath = Join-Path $WorkDir "inventory.json"
if (-not (Test-Path -LiteralPath $inventoryPath)) { Write-Fail "inventory.json not found in $WorkDir. Run inventory-csharp.ps1 -CppRoot `"$CppRoot`" first." }
foreach ($f in @($MappingTable, $Rules, $Template, $supportHeader)) { if (-not (Test-Path -LiteralPath $f)) { Write-Fail "reference file missing: $f" } }

# PortSupport.h is part of every port; put it in place once (never overwrite a customised copy silently).
$supportTarget = Join-Path $CppRoot "PortSupport.h"
$supportNote = ""
if (-not (Test-Path -LiteralPath $supportTarget)) { Copy-Item -LiteralPath $supportHeader -Destination $supportTarget; $supportNote = "PortSupport.h copied to $CppRoot" }
elseif ((Get-FileHash -LiteralPath $supportTarget).Hash -ne (Get-FileHash -LiteralPath $supportHeader).Hash) { $supportNote = "NOTE: $supportTarget differs from the skill's reference copy (kept as is)" }

$inventory = Get-Content -Raw -LiteralPath $inventoryPath | ConvertFrom-Json
$units = @($inventory.units)
$sourceRoot = $inventory.sourceRoot
$known = (($units | ForEach-Object { $_.path }) -join ', ')
$entry = $null
if ($Unit -match '^\d+$') {
    $orderPath = Join-Path $WorkDir "PORT_ORDER.txt"
    if (-not (Test-Path -LiteralPath $orderPath)) { Write-Fail "PORT_ORDER.txt not found in $WorkDir" }
    $line = @(Get-Content -LiteralPath $orderPath | Where-Object { $_ -match "^$Unit`t" })
    if ($line.Count -eq 0) { Write-Fail "no unit with index $Unit in PORT_ORDER.txt" }
    $Unit = ($line[0] -split "`t")[1]
}
$norm = $Unit.Replace('/', '\')
if ($norm.Contains('+')) { $norm = ($norm -split '\+')[0] }
$hit = @($units | Where-Object { $_.path -ieq $norm -or (@($_.files) -contains $norm) })
if ($hit.Count -eq 0) { Write-Fail ("unit not in inventory: {0}`n  known units: {1}" -f $Unit, $known) }
$entry = $hit[0]
$files = @($entry.files)
foreach ($f in $files) { if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot $f))) { Write-Fail "C# source no longer exists: $(Join-Path $sourceRoot $f)" } }

$base = $entry.path -replace '\.cs$', ''
$targetH = ($base + ".h").Replace('\', '/')
$targetCpp = ($base + ".cpp").Replace('\', '/')
$sources = @()
$isEntryPoint = $false
foreach ($f in $files) {
    $raw = [System.IO.File]::ReadAllText((Join-Path $sourceRoot $f))
    if ([regex]::IsMatch($raw, '\bstatic\s+(?:async\s+)?(?:int|void|Task(?:<int>)?)\s+Main\s*\(')) { $isEntryPoint = $true }
    $sources += @{ path = $f; text = $raw.TrimEnd() }
}

# ---- C# declarations with bodies removed (for dependencies that are not ported yet) ------------
function Remove-CommentsAndStrings {
    param([string]$Text)
    $t = [regex]::Replace($Text, '@"(?:[^"]|"")*"', '""')
    # Interpolated strings contain code: keep the {expressions}, drop the text.
    $t = [regex]::Replace($t, '\$"(?:[^"\\\r\n]|\\.)*"', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $inner = @([regex]::Matches($m.Value, '\{([^{}]*)\}') | ForEach-Object { $_.Groups[1].Value }); '(' + ($inner -join ' , ') + ')' })
    $t = [regex]::Replace($t, '"(?:[^"\\\r\n]|\\.)*"', '""')
    $t = [regex]::Replace($t, '/\*.*?\*/', ' ', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $t = [regex]::Replace($t, '//[^\r\n]*', '')
    # #if DEBUG ... #else: keep the release branch only; then drop every preprocessor line.
    $t = [regex]::Replace($t, '(?ms)^\s*#if\s+DEBUG\b.*?^\s*#else\b[^\r\n]*', '')
    $t = [regex]::Replace($t, '(?ms)^\s*#if\s+DEBUG\b.*?^\s*#endif\b[^\r\n]*', '')
    $t = [regex]::Replace($t, '(?m)^\s*#[^\r\n]*', '')
    return $t
}
function Get-DeclarationSummary {
    param([string]$Text)
    # Keep lines at brace depth <= 2 (namespace = 1, type members = 2); drop method/property bodies.
    $clean = Remove-CommentsAndStrings $Text
    $out = New-Object System.Collections.ArrayList
    $depth = 0
    $enumDepth = -1
    foreach ($line in ($clean -split "`r?`n")) {
        $trim = $line.Trim()
        if (-not $trim) { continue }
        $startDepth = $depth
        foreach ($ch in $trim.ToCharArray()) { if ($ch -eq '{') { $depth++ } elseif ($ch -eq '}') { $depth-- } }
        if ($enumDepth -ge 0 -and $depth -lt $enumDepth) { $enumDepth = -1 }
        $isEnumMember = ($enumDepth -ge 0 -and $startDepth -eq $enumDepth)
        if ($startDepth -le 2 -or $isEnumMember) {
            if ($trim -eq '{' -or $trim -eq '}') { continue }
            if ($trim -match '^using\s') { continue }
            $t2 = $trim -replace '\s*\{\s*$', ''
            $t2 = $t2 -replace '(\))\s*\{.*\}\s*;?\s*$', '$1'   # one-line method body: `int F() { return 1; }` -> `int F()`
            if ($isEnumMember) { [void]$out.Add("    " + ($t2 -replace '^\[[^\]]*\]\s*', '')); continue }
            if ($t2 -match '\benum\s+\w+') { $enumDepth = $startDepth + 1 }
            if ($t2 -match '\{\s*get\b') {
                # keep whether a public setter exists; never invent one
                $hasPublicSet = ($t2 -match '\bset\b' -and $t2 -notmatch '\b(private|protected|internal)\s+set\b')
                $t2 = ($t2 -replace '\s*\{\s*get\b.*$', '') + $(if ($hasPublicSet) { ' { get; set; }' } else { ' { get; }' })
            }
            elseif ($startDepth -eq 2 -and $t2 -match '^(?:public|internal|protected|private)\b' -and $t2 -notmatch '[\(\);=]' -and $t2 -notmatch '\b(class|struct|interface|enum|delegate|event)\b' -and $line -notmatch ';') {
                $t2 += ' { get; }'   # multi-line property: `public int Count` followed by `{ get { ... } }`
            }
            elseif ($startDepth -eq 2 -and $t2 -match '^(?:public|internal|protected|private)\b' -and $t2 -notmatch ';\s*$' -and $t2 -notmatch '\b(class|struct|interface|enum|delegate)\b') { $t2 += ";" }
            elseif ($startDepth -eq 2 -and $t2 -match '^\w[\w<>\[\],\.]*\s+\w+\s*\([^)]*\)\s*$') { $t2 += ";" }   # interface members carry no modifier
            [void]$out.Add($t2)
        }
    }
    return ($out -join "`n")
}

# ---- dependencies --------------------------------------------------------------------------------
$depSections = New-Object System.Collections.ArrayList
$portedCount = 0; $unportedCount = 0; $unported = @()
foreach ($d in @($entry.deps)) {
    $de = @($units | Where-Object { $_.path -ieq $d })
    if ($de.Count -eq 0) { continue }
    $de = $de[0]
    $depBase = $de.path -replace '\.cs$', ''
    $hRel = ($depBase + ".h").Replace('\', '/')
    $hFull = Join-Path $CppRoot ($depBase + ".h")
    $usedTypes = @($entry.depTypes | Where-Object { $tn = $_; @($de.types | Where-Object { $_.name -eq $tn }).Count -gt 0 })
    $extNames = @()
    if ($de.PSObject.Properties.Name -contains "extensionMethods") { $extNames = @($de.extensionMethods) }
    $usedTypes += @($entry.depTypes | Where-Object { $_ -match '\(\)$' -and $extNames -contains ($_ -replace '\(\)$', '') })
    $inSameCycle = ($entry.inCycle -and $de.inCycle -and $entry.cycleGroup -eq $de.cycleGroup)
    if (Test-Path -LiteralPath $hFull) {
        $portedCount++
        $content = [System.IO.File]::ReadAllText($hFull).TrimEnd()
        [void]$depSections.Add("### PORTED (authoritative): ``$hRel`` - uses: $($usedTypes -join ', ')`n`n``````cpp`n$content`n``````")
    }
    else {
        $unportedCount++; $unported += $de.path
        $decl = ""
        foreach ($df in @($de.files)) { $decl += "// $df`n" + (Get-DeclarationSummary ([System.IO.File]::ReadAllText((Join-Path $sourceRoot $df)))) + "`n" }
        $how = if ($inSameCycle) {
            "This unit and ``$($de.path)`` depend on each other (cycle). Port them together: forward-declare the class in your header (``class $($usedTypes -join '; class ');``), include ``$hRel`` only from your .cpp, and add ``// TODO(port): cycle with $($de.path)``."
        } else {
            "``$($de.path)`` has NOT been ported yet (no ``$hRel``). Normal procedure: STOP and port that unit first (it is earlier in PORT_ORDER.txt). Only if the human explicitly told you to proceed: write ``#include `"$hRel`"`` as if it existed, use only the members listed below, and add ``// TODO(port): depends on $($de.path) (not ported)``. Do not create ``$hRel`` yourself."
        }
        [void]$depSections.Add("### NOT PORTED: ``$hRel`` - uses: $($usedTypes -join ', ')`n$how`n`nC# declarations (bodies removed, for reference only):`n`n``````csharp`n$($decl.TrimEnd())`n``````")
    }
}
$depText = if ($depSections.Count -eq 0) { "(none: this unit depends on no other project unit)" } else { $depSections -join "`n`n" }

# Ownership hints computed by the inventory for the types this unit declares or uses.
$ownLines = @()
if ($inventory.PSObject.Properties.Name -contains "ownership") {
    $names = @($entry.types | ForEach-Object { $_.name }) + @($entry.depTypes | Where-Object { $_ -notmatch '\(\)$' })
    foreach ($n in ($names | Select-Object -Unique)) {
        $o = $inventory.ownership.PSObject.Properties[$n]
        if ($null -eq $o) { continue }
        $v = $o.Value
        if ($v.mode -eq "shared") { $ownLines += "- ``$n``: SHARED ($(@($v.reasons) -join ', ')) -> ``std::shared_ptr<$n>`` everywhere, created with ``std::make_shared``" }
        elseif ($v.polymorphic) { $ownLines += "- ``$n``: SINGLE owner, polymorphic -> ``std::unique_ptr<$n>`` member/local, created with ``std::make_unique``" }
        else { $ownLines += "- ``$n``: SINGLE owner -> plain value (member or local ``$n x(...);``), no smart pointer" }
    }
}
$ownText = if ($ownLines.Count -eq 0) { "(no class types involved)" } else { $ownLines -join "`n" }
$depText = "### Ownership (computed by the inventory; follow it, do not re-decide)`n`n$ownText`n`n" + $depText
# Dependencies a human marked blocked: this unit cannot be built either; do not burn rounds on it.
$blockedDeps = @()
$statusPath = Join-Path $WorkDir "status.json"
if (Test-Path -LiteralPath $statusPath) {
    $st = Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json
    foreach ($d in @($entry.deps)) { $sd = @($st.units | Where-Object { $_.unit -ieq $d -and $_.state -eq "blocked" }); if ($sd.Count -gt 0) { $blockedDeps += $d } }
}
if ($blockedDeps.Count -gt 0) {
    $blockedList = $blockedDeps -join ', '
    $depText = "BLOCKED DEPENDENCIES: $blockedList are marked blocked. Do not port this unit now: run port-status.ps1 -CppRoot <root> -Unit <this unit> -State blocked -Note `"waiting on $blockedList`" and continue with the next unit.`n`n" + $depText
}

# ---- build errors for this unit -------------------------------------------------------------------
$buildText = "(none: first attempt)"
$buildResult = Join-Path $WorkDir "BUILD_RESULT.txt"
$errorsIncluded = $false
if (Test-Path -LiteralPath $buildResult) {
    $br = @(Get-Content -LiteralPath $buildResult)
    $unitLines = @($br | Where-Object { $_ -match '^Unit: ' })
    $mine = @($unitLines | Where-Object { $_ -match [regex]::Escape(($base + ".cpp").Replace('/', '\')) -or $_ -match [regex]::Escape($targetCpp) })
    if ($mine.Count -gt 0) {
        $errLines = New-Object System.Collections.ArrayList; $inErr = $false
        foreach ($l in $br) {
            if ($l -match '^## Errors') { $inErr = $true; continue }
            if ($l -match '^## ') { $inErr = $false }
            if ($inErr -and $l -match '^[^|#]+\|\d+\|') { [void]$errLines.Add($l) }
        }
        if ($errLines.Count -gt 0) {
            $errorsIncluded = $true
            $buildText = "The last build of this unit FAILED. Fix these and change nothing else (file|line|code|message). Errors located in a file you were not asked to write (a PORTED header, PortSupport.h) mean your call does not match its declaration: fix the call, never that file.`n`n``````text`n" + ($errLines -join "`n") + "`n``````"
        }
        elseif ($mine[0] -match ' OK ') { $buildText = "(last build of this unit passed)" }
    }
}

# ---- output format -----------------------------------------------------------------------------------
$filesNote = if ($isEntryPoint) { "Write exactly ONE file: ``$targetCpp`` (this unit holds ``Main``; it becomes ``int wmain(int argc, wchar_t* argv[])``; no header)" }
             else { "Write exactly two files: ``$targetH`` and ``$targetCpp``" }
if ($files.Count -gt 1) { $filesNote += " - the unit is a ``partial`` type spread over $($files.Count) C# files below; merge them into that single header/source pair" }
$absH = Join-Path $CppRoot ($base + ".h"); $absCpp = Join-Path $CppRoot ($base + ".cpp")
if ($Mode -eq "agent") {
    $list = if ($isEntryPoint) { "- ``$absCpp``" } else { "- ``$absH```n- ``$absCpp``" }
    $unitSlash = $entry.path.Replace('\', '/')
    $finish = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$scriptsDir\finish-unit.ps1`" -CppRoot `"$CppRoot`" -Unit `"$unitSlash`""
    $outputFormat = "1. Create the file(s) below with your file-writing tool, complete. Do not paste the code into the chat. Do not create, edit or delete any other file (not PortSupport.h, not a PORTED header).`n`n$list`n`n2. Then run this command and follow its RESULT / NEXT lines:`n`n``````text`n$finish`n```````n`nRESULT: PASS -> continue with the unit named on the NEXT line (run make-unit-prompt.ps1 for it). RESULT: FAIL -> re-run make-unit-prompt.ps1 for THIS unit (the errors are now embedded), fix only those errors, run the command again. RESULT: FORBIDDEN -> fix the listed constructs, run the command again. RESULT: BLOCKED -> continue with the NEXT unit and report the blocked unit at the end."
}
else {
    $nl = "`n"; $fence = '```'
    if ($isEntryPoint) {
        $outputFormat = "Reply with the file only, in exactly this shape (a ``// FILE:`` line, then a fenced block with the complete file). No text before or after.$nl$nl// FILE: $targetCpp$nl$fence" + "cpp$nl#include `"PortSupport.h`"$nl$nl" + "int wmain(int argc, wchar_t* argv[])$nl{$nl    PortSupport::InitConsole();$nl    return 0;$nl}$nl$fence"
    }
    else {
        $outputFormat = "Reply with the two files only, in exactly this shape (a ``// FILE:`` line, then a fenced block with the complete file, twice). No text before, between, or after. The skeleton below only shows the SHAPE: use the real namespace and the complete content.$nl$nl// FILE: $targetH$nl$fence" + "cpp$nl#pragma once$nl$nl" + "namespace Example {$nl}$nl$fence$nl$nl// FILE: $targetCpp$nl$fence" + "cpp$nl#include `"$targetH`"$nl$nl" + "namespace Example {$nl}$nl$fence"
    }
}

# ---- assemble ---------------------------------------------------------------------------------------
$flags = @($entry.flags.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" })
$flagText = if ($flags.Count -eq 0) { "(none detected)" } else { $flags -join ', ' }
$exampleText = if ($NoExample -or -not (Test-Path -LiteralPath $Example)) { "(omitted)" } else { [System.IO.File]::ReadAllText($Example).Trim() }
$sourceText = ""
foreach ($s in $sources) { $sourceText += "### ``$($s.path)```n`n``````csharp`n$($s.text)`n```````n`n" }
$sourceText = $sourceText.TrimEnd()
$extra = if ($ExtraNote) { "## Note from the previous round`n`n$ExtraNote" } else { "" }

$prompt = [System.IO.File]::ReadAllText($Template)
$prompt = $prompt.Replace('{{UNIT}}', ($files -join ' + ').Replace('\', '/'))
$prompt = $prompt.Replace('{{FILES_NOTE}}', $filesNote).Replace('{{OUTPUT_FORMAT}}', $outputFormat)
$prompt = $prompt.Replace('{{TARGET_H}}', $targetH).Replace('{{TARGET_CPP}}', $targetCpp)
$prompt = $prompt.Replace('{{FLAGS}}', $flagText)
$prompt = $prompt.Replace('{{RULES}}', ([System.IO.File]::ReadAllText($Rules).Trim()))
# Project-specific rows (e.g. the UI framework chosen by the human) live in port-work\mapping-extra.md
# and are appended to the fixed table; a `ui` unit without them is not portable yet.
$mappingText = [System.IO.File]::ReadAllText($MappingTable).Trim()
$extraPath = Join-Path $WorkDir "mapping-extra.md"
$hasExtra = Test-Path -LiteralPath $extraPath
if ($hasExtra) { $mappingText += "`n`n" + [System.IO.File]::ReadAllText($extraPath).Trim() }
$isUiUnit = (@($entry.marks) -contains "ui")
if ($isUiUnit -and -not $hasExtra) {
    $mappingText = "UI UNIT WITHOUT A UI MAPPING: this unit uses WinForms/WPF and port-work\mapping-extra.md does not exist. Do not port it: ask the user which UI framework to target (Win32 or MFC), copy references\ui-win32.md or references\ui-mfc.md to port-work\mapping-extra.md, and re-run make-unit-prompt.`n`n" + $mappingText
}
$prompt = $prompt.Replace('{{MAPPING}}', $mappingText)
$prompt = $prompt.Replace('{{DEPENDENCIES}}', $depText)
$prompt = $prompt.Replace('{{EXAMPLE}}', $exampleText)
$prompt = $prompt.Replace('{{SOURCE}}', $sourceText)
$prompt = $prompt.Replace('{{BUILD_ERRORS}}', $buildText)
$prompt = $prompt.Replace('{{EXTRA_NOTE}}', $extra)
$tokens = [int][Math]::Ceiling($prompt.Length / 3.5)
$prompt = $prompt.Replace('{{TOKENS}}', "$tokens")

if (-not $OutputPath) { $OutputPath = Join-Path $WorkDir "UNIT_PROMPT.md" }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null
[System.IO.File]::WriteAllText($OutputPath, $prompt, $utf8)

if ($isEntryPoint) { Write-Host "make-unit-prompt: $($entry.path) -> $targetCpp (entry point, no header)" }
else { Write-Host "make-unit-prompt: $($entry.path) -> $targetH + $targetCpp" }
if ($files.Count -gt 1) { Write-Host "  partial unit: $($files -join ' + ')" }
Write-Host "  dependencies: $portedCount ported, $unportedCount not ported"
if ($unportedCount -gt 0) { Write-Host "  UNPORTED DEPENDENCIES: $($unported -join ', ') -> port these first unless they form a cycle with this unit" }
Write-Host "  build errors included: $(if ($errorsIncluded) { 'yes' } else { 'no' })"
Write-Host "  mode: $Mode; prompt ~$tokens tokens$(if ($tokens -gt 12000) { ' (LARGE: make sure the model context is >= 16k, or split the unit)' })"
if ($supportNote) { Write-Host "  $supportNote" }
Write-Host "  $OutputPath"
Write-Host "UiMappingMissing: $(if ($isUiUnit -and -not $hasExtra) { 1 } else { 0 })$(if ($isUiUnit -and -not $hasExtra) { ' -> ask the user (Win32 or MFC), copy references\ui-<choice>.md to port-work\mapping-extra.md' })"
Write-Host "UnportedDeps: $unportedCount"
$blockedNote = if ($blockedDeps.Count -gt 0) { ' (' + ($blockedDeps -join ', ') + ') -> mark this unit blocked and continue' } else { '' }
Write-Host "BlockedDeps: $($blockedDeps.Count)$blockedNote"
exit 0
