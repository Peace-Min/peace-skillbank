param(
    # Built C# program: an .exe, or a .dll launched through `dotnet`.
    [Parameter(Mandatory = $true)]
    [string]$CsExe,

    [Parameter(Mandatory = $true)]
    [string]$CppExe,

    # Directory of test cases: <name>.args (one line of arguments; may be empty) + optional <name>.stdin
    [Parameter(Mandatory = $true)]
    [string]$CasesDir,

    # Either -CppRoot (work dir = <CppRoot>\port-work) or -WorkDir; default .\port-work.
    [string]$CppRoot,
    [string]$WorkDir,
    [int]$TimeoutSeconds = 60,
    # Code page both children write to the redirected stdout. Default: force UTF-8 on both sides by
    # setting the console output encoding they inherit (.NET honours it; the port emits UTF-8 anyway).
    [int]$CsCodePage = 65001
)

# Runs the original C# program and the C++ port on the same inputs and diffs stdout + exit code.
# Exit codes: 0 = all cases identical, 1 = at least one difference, 2 = environment problem.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Write-Fail { param([string]$Message) [Console]::Error.WriteLine("parity-check: $Message"); exit 2 }
if (-not $WorkDir) { $WorkDir = if ($CppRoot) { Join-Path $CppRoot "port-work" } else { Join-Path (Get-Location).Path "port-work" } }

if (-not (Test-Path -LiteralPath $CsExe -PathType Leaf)) { Write-Fail "C# program not found: $CsExe (build the original first, e.g. msbuild /p:Configuration=Release or dotnet build)" }
if (-not (Test-Path -LiteralPath $CppExe -PathType Leaf)) { Write-Fail "C++ program not found: $CppExe (run build-check.ps1 -All -Link -OutputExe <path> first)" }
if (-not (Test-Path -LiteralPath $CasesDir -PathType Container)) { Write-Fail "cases directory not found: $CasesDir" }
$cases = @(Get-ChildItem -LiteralPath $CasesDir -File -Filter *.args | Sort-Object Name)
if ($cases.Count -eq 0) { Write-Fail "no *.args case files in $CasesDir (create e.g. default.args, empty file = no arguments)" }
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$runDir = Join-Path $WorkDir "parity"
New-Item -ItemType Directory -Force -Path $runDir | Out-Null

$csIsDll = $CsExe -match '\.dll$'
if ($csIsDll -and -not (Get-Command dotnet -ErrorAction SilentlyContinue)) { Write-Fail "dotnet not on PATH but CsExe is a .dll" }
# Both children inherit the console output code page. Without this a .NET Framework app on a Korean
# console writes CP949 while the C++ port writes UTF-8, and every non-ASCII line would differ.
$childEncoding = $null
try { $childEncoding = [System.Text.Encoding]::GetEncoding($CsCodePage) } catch { Write-Fail "invalid -CsCodePage $CsCodePage" }
$savedOutputEncoding = [Console]::OutputEncoding
try { [Console]::OutputEncoding = $childEncoding } catch { }

function Invoke-Program {
    param([string]$Exe, [string]$ArgLine, [string]$StdinFile, [string]$LogBase)
    $outFile = "$LogBase.out.txt"; $errFile = "$LogBase.err.txt"
    $file = $Exe; $argList = @()
    if ($Exe -match '\.dll$') { $file = "dotnet"; $argList += ('"' + $Exe + '"') }
    if ($ArgLine.Trim()) { $argList += $ArgLine.Trim() }
    $sp = @{ FilePath = $file; NoNewWindow = $true; PassThru = $true; RedirectStandardOutput = $outFile; RedirectStandardError = $errFile; WorkingDirectory = (Split-Path -Parent $Exe) }
    if ($argList.Count -gt 0) { $sp.ArgumentList = $argList }
    if ($StdinFile) { $sp.RedirectStandardInput = $StdinFile }
    $p = Start-Process @sp
    $null = $p.Handle
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) { try { $p.Kill() } catch { }; return @{ code = 124; out = "TIMEOUT" } }
    $o = if (Test-Path -LiteralPath $outFile) { [System.IO.File]::ReadAllText($outFile, $childEncoding) } else { "" }
    return @{ code = $p.ExitCode; out = $o }
}

function ConvertTo-Normalized {
    param([string]$Text)
    $t = $Text -replace "`r`n", "`n"
    if ($t.Length -gt 0 -and [int][char]$t[0] -eq 0xFEFF) { $t = $t.Substring(1) }
    $lines = $t -split "`n" | ForEach-Object { $_.TrimEnd() }
    return (($lines -join "`n").TrimEnd("`n"))
}

$results = @(); $failures = 0
foreach ($c in $cases) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($c.Name)
    $argLine = ([System.IO.File]::ReadAllText($c.FullName) -split "`r?`n")[0]
    $stdin = Join-Path $CasesDir "$name.stdin"
    if (-not (Test-Path -LiteralPath $stdin)) { $stdin = $null }
    $cs = Invoke-Program -Exe $CsExe -ArgLine $argLine -StdinFile $stdin -LogBase (Join-Path $runDir "$name.cs")
    $cpp = Invoke-Program -Exe $CppExe -ArgLine $argLine -StdinFile $stdin -LogBase (Join-Path $runDir "$name.cpp")
    $a = ConvertTo-Normalized $cs.out; $b = ConvertTo-Normalized $cpp.out
    $same = ($a -eq $b) -and ($cs.code -eq $cpp.code)
    $detail = ""
    if (-not $same) {
        $failures++
        if ($cs.code -ne $cpp.code) { $detail = "exit code C#=$($cs.code) C++=$($cpp.code)" }
        $la = $a -split "`n"; $lb = $b -split "`n"
        $n = [Math]::Max($la.Count, $lb.Count)
        for ($i = 0; $i -lt $n; $i++) {
            $x = if ($i -lt $la.Count) { $la[$i] } else { "<missing>" }
            $y = if ($i -lt $lb.Count) { $lb[$i] } else { "<missing>" }
            if ($x -ne $y) { if ($detail) { $detail += "; " }; $detail += "first diff at line $($i + 1): C#=`"$x`" C++=`"$y`""; break }
        }
    }
    $results += [pscustomobject]@{ case = $name; args = $argLine; ok = $same; csExit = $cs.code; cppExit = $cpp.code; detail = $detail }
}

$status = if ($failures -eq 0) { "PASS" } else { "FAIL" }
$out = @("# PARITY_RESULT", "Status: $status", "Cases: $($cases.Count)", "Failures: $failures", "CsExe: $CsExe", "CppExe: $CppExe", "", "## Cases", "")
foreach ($r in $results) { $out += ("- {0} [{1}] args=`"{2}`" exit C#={3} C++={4}{5}" -f $r.case, $(if ($r.ok) { "PASS" } else { "FAIL" }), $r.args, $r.csExit, $r.cppExit, $(if ($r.detail) { " :: " + $r.detail } else { "" })) }
$out += @("", "Raw outputs: $runDir\<case>.cs.out.txt vs <case>.cpp.out.txt", "Normalization: CRLF->LF, BOM stripped, trailing whitespace per line and trailing newlines ignored.")
try { [Console]::OutputEncoding = $savedOutputEncoding } catch { }
$resultPath = Join-Path $WorkDir "PARITY_RESULT.txt"
[System.IO.File]::WriteAllText($resultPath, (($out -join "`n") + "`n"), $utf8)
Write-Host "parity-check: $status cases=$($cases.Count) failures=$failures"
Write-Host "  $resultPath"
if ($failures -eq 0) { exit 0 } else { exit 1 }
