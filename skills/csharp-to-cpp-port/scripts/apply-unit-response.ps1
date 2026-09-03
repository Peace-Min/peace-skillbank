param(
    [Parameter(Mandatory = $true)]
    [string]$ResponsePath,

    [Parameter(Mandatory = $true)]
    [string]$CppRoot,

    # Only accept files whose relative path starts with one of these prefixes (e.g. Services/Logger).
    [string[]]$Allow,
    # Relative paths that MUST be present; missing ones fail the run (truncated or malformed reply).
    [string[]]$Expect,
    [switch]$Overwrite
)

# Extracts C++ files from a model reply and writes them under CppRoot. Accepted shapes:
#   // FILE: path            (line before the fence)
#   ```cpp / // FILE: path   (first line inside the fence)
#   ### path  |  **path**  |  **// FILE: path**   (heading before the fence)
# Rejects absolute paths, "..", and anything not ending in .h/.hpp/.cpp.
# Exit codes: 0 = all written, 1 = some rejected or expected files missing, 2 = nothing usable found.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0
$utf8 = New-Object System.Text.UTF8Encoding($false)

# Callers using "powershell -File" cannot repeat a named parameter; a comma-separated value is accepted too.
function Split-List { param([string[]]$Values) $out = @(); foreach ($v in @($Values | Where-Object { $null -ne $_ })) { $out += @($v -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }; return $out }
$Allow = Split-List $Allow
$Expect = Split-List $Expect

if (-not (Test-Path -LiteralPath $ResponsePath -PathType Leaf)) { [Console]::Error.WriteLine("apply-unit-response: response file not found: $ResponsePath"); exit 2 }
New-Item -ItemType Directory -Force -Path $CppRoot | Out-Null
$CppRoot = (Resolve-Path -LiteralPath $CppRoot).Path.TrimEnd('\')

$text = [System.IO.File]::ReadAllText($ResponsePath) -replace "`r`n", "`n"
$lines = $text -split "`n"
# Any non-space token ending in a C++ extension; unsafe shapes (absolute, "..") are caught and REPORTED below.
$pathRx = '(?<path>[^\s`*]+?\.(?:h|hpp|hh|cpp|cc|cxx))'
$markerRx = [regex]("^\s*(?:\*\*)?\s*//\s*FILE:\s*" + $pathRx + "\s*(?:\*\*)?\s*$")
$headingRx = [regex]("^\s*(?:#{1,6}\s*|\*\*)\s*`?" + $pathRx + "`?\s*(?:\*\*)?\s*:?\s*$")

$blocks = @()
$i = 0
while ($i -lt $lines.Count) {
    if ($lines[$i] -match '^\s*```') {
        $start = $i; $i++
        $body = New-Object System.Collections.ArrayList
        while ($i -lt $lines.Count -and $lines[$i] -notmatch '^\s*```') { [void]$body.Add($lines[$i]); $i++ }
        $closed = ($i -lt $lines.Count)
        $i++
        $path = $null
        if ($body.Count -gt 0 -and $markerRx.IsMatch($body[0])) { $path = $markerRx.Match($body[0]).Groups["path"].Value; $body.RemoveAt(0) }
        if (-not $path) {
            $j = $start - 1
            while ($j -ge 0 -and -not $lines[$j].Trim()) { $j-- }
            if ($j -ge 0) {
                if ($markerRx.IsMatch($lines[$j])) { $path = $markerRx.Match($lines[$j]).Groups["path"].Value }
                elseif ($headingRx.IsMatch($lines[$j])) { $path = $headingRx.Match($lines[$j]).Groups["path"].Value }
            }
        }
        if ($path) { $blocks += @{ path = $path; body = ($body -join "`n"); closed = $closed } }
        continue
    }
    $i++
}
if ($blocks.Count -eq 0) {
    [Console]::Error.WriteLine("apply-unit-response: no file blocks found in $ResponsePath (expected '// FILE: <path>' + a fenced block per file)")
    exit 2
}

$written = @(); $rejected = @()
foreach ($b in $blocks) {
    $rel = $b.path.Trim().Replace('/', '\')
    if ([System.IO.Path]::IsPathRooted($rel) -or $rel -match '(^|\\)\.\.(\\|$)') { $rejected += "$rel (unsafe path)"; continue }
    if ($Allow -and (@($Allow | Where-Object { $rel.Replace('\', '/').StartsWith($_.Replace('\', '/'), [System.StringComparison]::OrdinalIgnoreCase) }).Count -eq 0)) { $rejected += "$rel (not in -Allow list)"; continue }
    if (-not $b.closed) { $rejected += "$rel (fence never closed: reply truncated?)"; continue }
    $full = Join-Path $CppRoot $rel
    if ((Test-Path -LiteralPath $full) -and -not $Overwrite) { $rejected += "$rel (exists; pass -Overwrite)"; continue }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full) | Out-Null
    [System.IO.File]::WriteAllText($full, ($b.body.TrimEnd() + "`n"), $utf8)
    $written += $rel
}
$missing = @()
foreach ($e in @($Expect | Where-Object { $_ })) {
    $er = $e.Replace('/', '\')
    if (@($written | Where-Object { $_ -ieq $er }).Count -eq 0) { $missing += $er }
}

foreach ($w in $written) { Write-Host "apply-unit-response: wrote $w" }
foreach ($r in $rejected) { [Console]::Error.WriteLine("apply-unit-response: rejected $r") }
foreach ($m in $missing) { [Console]::Error.WriteLine("apply-unit-response: missing expected file $m (reply truncated or wrong format?)") }
if ($written.Count -eq 0) { exit 2 }
if ($rejected.Count -gt 0 -or $missing.Count -gt 0) { exit 1 }
exit 0
