param(
    [Parameter(Mandatory = $true)]
    [string]$CppRoot,
    [string]$WorkDir
)

# Rolls everything that still needs a human eye into one file: port-work\REVIEW.md.
#   1. Decisions (from decisions.json) that are not yet accepted
#   2. Every TODO(port) marker in the produced C++, grouped by file
#   3. Units in state blocked / todo, and files that were skipped on purpose
#   4. The last build and parity status
# Deterministic: it only reads existing artifacts, never a model.
# Exit codes: 0 = nothing pending, 1 = items need review, 2 = input problem.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0
$utf8 = New-Object System.Text.UTF8Encoding($false)

if (-not (Test-Path -LiteralPath $CppRoot -PathType Container)) { [Console]::Error.WriteLine("review-report: CppRoot is not an existing directory: $CppRoot"); exit 2 }
$CppRoot = (Resolve-Path -LiteralPath $CppRoot).Path.TrimEnd('\')
if (-not $WorkDir) { $WorkDir = Join-Path $CppRoot "port-work" }
if (-not (Test-Path -LiteralPath $WorkDir -PathType Container)) { [Console]::Error.WriteLine("review-report: work dir not found: $WorkDir. Run inventory-csharp.ps1 -CppRoot `"$CppRoot`" first."); exit 2 }

$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine("# REVIEW")
[void]$md.AppendLine("")
[void]$md.AppendLine("Generated: $([DateTimeOffset]::Now.ToString('s'))  |  C++ root: ``$CppRoot``")
[void]$md.AppendLine("")
[void]$md.AppendLine("Everything a compiler cannot check. Work top to bottom; nothing here blocks the build.")
[void]$md.AppendLine("")

# ---- 1. decisions -----------------------------------------------------------------------------
$pendingDecisions = 0
$decisionsPath = Join-Path $WorkDir "decisions.json"
[void]$md.AppendLine("## 1. Decisions to confirm")
[void]$md.AppendLine("")
if (Test-Path -LiteralPath $decisionsPath) {
    $doc = Get-Content -Raw -LiteralPath $decisionsPath | ConvertFrom-Json
    $open = @($doc.decisions | Where-Object { $_.status -ne "accepted" })
    $pendingDecisions = $open.Count
    if ($open.Count -eq 0) { [void]$md.AppendLine("(all decisions accepted)") }
    else {
        [void]$md.AppendLine("| Id | Topic | Decision | Source | Why it may need review |")
        [void]$md.AppendLine("|----|-------|----------|--------|------------------------|")
        foreach ($d in ($open | Sort-Object id)) { [void]$md.AppendLine("| ``$($d.id)`` | $($d.topic) | $($d.decision) | $($d.source) | $($d.review) |") }
        [void]$md.AppendLine("")
        [void]$md.AppendLine("Accept one with ``record-decision.ps1 -CppRoot `"$CppRoot`" -Id <id> -Status accepted``.")
    }
}
else { [void]$md.AppendLine("(no decisions.json; run inventory-csharp.ps1 to seed it)") }
[void]$md.AppendLine("")

# ---- 2. TODO(port) markers ---------------------------------------------------------------------
$skipDirs = @("port-work", "build", "out", ".vs", ".git", "CMakeFiles", "x64", "Debug", "Release")
$cppFiles = @(Get-ChildItem -LiteralPath $CppRoot -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -match '^\.(h|hpp|hh|cpp|cc|cxx)$' -and $_.Name -ne "PortSupport.h" } |
    Where-Object { $rel = $_.FullName.Substring($CppRoot.Length).TrimStart('\'); @($rel.Split('\') | Where-Object { $skipDirs -contains $_ }).Count -eq 0 } |
    Sort-Object FullName)
$todos = New-Object System.Collections.ArrayList
foreach ($f in $cppFiles) {
    $rel = $f.FullName.Substring($CppRoot.Length).TrimStart('\')
    $lines = [System.IO.File]::ReadAllLines($f.FullName)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'TODO\(port\)\s*:?\s*(?<what>.*)$') {
            [void]$todos.Add([pscustomobject]@{ file = $rel; line = ($i + 1); text = $Matches["what"].Trim() })
        }
    }
}
[void]$md.AppendLine("## 2. TODO(port) markers in the produced C++ ($($todos.Count))")
[void]$md.AppendLine("")
if ($todos.Count -eq 0) { [void]$md.AppendLine("(none)") }
else {
    # group identical notes so a repeated pattern is one review item, not fifty
    $groups = $todos | Group-Object { ($_.text -replace '\s+', ' ').ToLowerInvariant() } | Sort-Object Count -Descending
    [void]$md.AppendLine("| Count | Note | Where |")
    [void]$md.AppendLine("|-------|------|-------|")
    foreach ($g in $groups) {
        $where = (@($g.Group | Select-Object -First 4 | ForEach-Object { "``$($_.file):$($_.line)``" }) -join ', ')
        if ($g.Count -gt 4) { $where += ", +$($g.Count - 4) more" }
        [void]$md.AppendLine("| $($g.Count) | $($g.Group[0].text) | $where |")
    }
}
[void]$md.AppendLine("")

# ---- 3. units and skipped files -----------------------------------------------------------------
$blocked = @(); $todoUnits = @(); $skipped = @(); $verified = 0; $builds = 0
$statusPath = Join-Path $WorkDir "status.json"
if (Test-Path -LiteralPath $statusPath) {
    $st = Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json
    $blocked = @($st.units | Where-Object { $_.state -eq "blocked" })
    $todoUnits = @($st.units | Where-Object { $_.state -eq "todo" })
    $skipped = @($st.units | Where-Object { $_.state -eq "skipped" })
    $verified = @($st.units | Where-Object { $_.state -eq "verified" }).Count
    $builds = @($st.units | Where-Object { $_.state -eq "builds" }).Count
}
[void]$md.AppendLine("## 3. Units")
[void]$md.AppendLine("")
[void]$md.AppendLine("verified=$verified, builds (compiled, behaviour unchecked)=$builds, todo=$($todoUnits.Count), blocked=$($blocked.Count), skipped=$($skipped.Count)")
[void]$md.AppendLine("")
if ($blocked.Count -gt 0) {
    [void]$md.AppendLine("Blocked (a human must port or unblock these):")
    [void]$md.AppendLine("")
    foreach ($u in $blocked) { [void]$md.AppendLine("- ``$($u.unit)``: $($u.note)") }
    [void]$md.AppendLine("")
}
if ($skipped.Count -gt 0) {
    [void]$md.AppendLine("Skipped on purpose (map by hand if the port needs them):")
    [void]$md.AppendLine("")
    foreach ($u in $skipped) { [void]$md.AppendLine("- ``$($u.unit)``: $($u.note)") }
    [void]$md.AppendLine("")
}

# ---- 4. build and parity ------------------------------------------------------------------------
[void]$md.AppendLine("## 4. Last build and parity")
[void]$md.AppendLine("")
$buildPath = Join-Path $WorkDir "BUILD_RESULT.txt"
if (Test-Path -LiteralPath $buildPath) {
    foreach ($l in (Get-Content -LiteralPath $buildPath | Select-Object -First 6)) { if ($l -match '^(Status|Compiler|Standard|Units|Link):') { [void]$md.AppendLine("- $l") } }
}
else { [void]$md.AppendLine("- build-check has not run yet") }
$parityPath = Join-Path $WorkDir "PARITY_RESULT.txt"
if (Test-Path -LiteralPath $parityPath) {
    foreach ($l in (Get-Content -LiteralPath $parityPath | Select-Object -First 4)) { if ($l -match '^(Status|Cases|Failures):') { [void]$md.AppendLine("- parity $l") } }
}
else { [void]$md.AppendLine("- parity-check has not run yet (behaviour is unverified)") }
[void]$md.AppendLine("")
[void]$md.AppendLine("A unit in state ``builds`` only means it compiles. Only parity or a human review makes it ``verified``.")

$reviewPath = Join-Path $WorkDir "REVIEW.md"
[System.IO.File]::WriteAllText($reviewPath, $md.ToString(), $utf8)

$total = $pendingDecisions + $todos.Count + $blocked.Count
Write-Host "review-report: $pendingDecisions decision(s) to confirm, $($todos.Count) TODO(port) marker(s), $($blocked.Count) blocked unit(s)"
Write-Host "  $reviewPath"
if ($total -gt 0) { exit 1 } else { exit 0 }
