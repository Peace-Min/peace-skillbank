param(
    # Files or directories (recursively *.h/*.hpp/*.cpp) to scan.
    [Parameter(Mandatory = $true)]
    [string[]]$Path,

    [string]$Patterns,
    [string]$OutputPath
)

# Scans produced C++ for constructs a weak model tends to emit that violate the porting rules
# (C++/CLI syntax, .NET types, raw new/delete, printf, narrow strings, elided bodies).
# Exit codes: 0 = clean (warnings allowed), 1 = at least one error-severity hit, 2 = bad input.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0
$utf8 = New-Object System.Text.UTF8Encoding($false)

# Callers using "powershell -File" cannot repeat a named parameter; a comma-separated value is accepted too.
function Split-List { param([string[]]$Values) $out = @(); foreach ($v in @($Values | Where-Object { $null -ne $_ })) { $out += @($v -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }; return $out }
$Path = Split-List $Path
if (-not $Patterns) { $Patterns = Join-Path (Split-Path -Parent $PSScriptRoot) "references\forbidden-patterns.txt" }
if (-not (Test-Path -LiteralPath $Patterns)) { [Console]::Error.WriteLine("scan-forbidden: pattern file not found: $Patterns"); exit 2 }

$rules = @()
foreach ($line in (Get-Content -LiteralPath $Patterns)) {
    if (-not $line.Trim() -or $line.TrimStart().StartsWith('#')) { continue }
    $parts = $line -split '\|', 3
    if ($parts.Count -ne 3) { continue }
    $rules += @{ name = $parts[0].Trim(); severity = $parts[1].Trim(); regex = [regex]$parts[2] }
}

$files = @()
foreach ($p in $Path) {
    if (Test-Path -LiteralPath $p -PathType Container) {
        $files += @(Get-ChildItem -LiteralPath $p -Recurse -File | Where-Object { $_.Extension -match '^\.(h|hpp|hh|cpp|cc|cxx)$' -and $_.Name -ne 'PortSupport.h' } | ForEach-Object { $_.FullName })
    }
    elseif (Test-Path -LiteralPath $p -PathType Leaf) { $files += (Resolve-Path -LiteralPath $p).Path }
    else { [Console]::Error.WriteLine("scan-forbidden: path not found: $p"); exit 2 }
}
if ($files.Count -eq 0) { [Console]::Error.WriteLine("scan-forbidden: no C++ files under: $($Path -join ', ')"); exit 2 }

$hits = New-Object System.Collections.ArrayList
$errorCount = 0; $warnCount = 0
foreach ($f in ($files | Sort-Object)) {
    $lines = [System.IO.File]::ReadAllLines($f)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        # Code rules see the line with its trailing // comment removed (comments quoting C# are not violations);
        # the elision and todo rules look at the whole line because they target comments.
        $code = $l -replace '//.*$', ''
        foreach ($r in $rules) {
            $subject = if ($r.name -eq 'elision' -or $r.name -eq 'todo-port') { $l } else { $code }
            if ($r.regex.IsMatch($subject)) {
                if ($r.severity -eq 'error') { $errorCount++ } else { $warnCount++ }
                [void]$hits.Add(("{0}|{1}|{2}|{3}|{4}" -f $f, ($i + 1), $r.severity, $r.name, $l.Trim()))
            }
        }
    }
}

$out = @("# FORBIDDEN_SCAN", "Files: $($files.Count)", "Errors: $errorCount", "Warnings: $warnCount", "", "## Hits (file|line|severity|rule|text)", "")
if ($hits.Count -eq 0) { $out += "(none)" } else { $out += @($hits) }
if ($OutputPath) { [System.IO.File]::WriteAllText($OutputPath, (($out -join "`n") + "`n"), $utf8) }
Write-Host "scan-forbidden: files=$($files.Count) errors=$errorCount warnings=$warnCount"
foreach ($h in $hits) { Write-Host "  $h" }
if ($errorCount -gt 0) { exit 1 } else { exit 0 }
