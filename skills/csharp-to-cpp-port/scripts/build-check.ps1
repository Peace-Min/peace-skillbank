param(
    [Parameter(Mandatory = $true)]
    [string]$CppRoot,

    # Relative paths under CppRoot (.cpp compiles; .h is syntax-checked). Omit with -All.
    [string[]]$Unit,
    [switch]$All,

    [string]$Standard = "c++17",
    [string[]]$IncludeDir,
    # Default: <CppRoot>\port-work
    [string]$WorkDir,

    [ValidateSet("auto", "msvc", "gcc")]
    [string]$Compiler = "auto",
    [string]$ClPath,      # explicit cl.exe (MSVC)
    [string]$GxxPath,     # explicit g++.exe (MinGW-w64)
    [string]$WindowsKitsRoot = "${env:ProgramFiles(x86)}\Windows Kits\10",

    # Link every compiled object into one executable (needed for parity-check.ps1).
    [switch]$Link,
    [string]$OutputExe,
    [string[]]$ExtraArgs,
    # Extra linker inputs, e.g. Ws2_32.lib (MSVC) or -lws2_32 (MinGW).
    [string[]]$LinkArgs,
    [int]$TimeoutSeconds = 180
)

# Compiles ported C++ units one at a time and writes a compact BUILD_RESULT.txt the model can read.
# Exit codes: 0 = all units compiled, 1 = compile/link errors, 2 = environment problem (no compiler, bad args).
# Compiler discovery never assumes vcvars*.bat works: MSVC is driven with an explicitly constructed
# INCLUDE/LIB/PATH (partial VS installs without vcvarsall.bat are common), MinGW g++ is the fallback.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Write-Fail {
    param([string]$Message)
    [Console]::Error.WriteLine("build-check: $Message")
    exit 2
}

# Callers using "powershell -File" cannot repeat a named parameter; a comma-separated value is accepted too.
function Split-List { param([string[]]$Values) $out = @(); foreach ($v in @($Values | Where-Object { $null -ne $_ })) { $out += @($v -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }; return $out }
$Unit = Split-List $Unit
$IncludeDir = Split-List $IncludeDir
$ExtraArgs = Split-List $ExtraArgs
$LinkArgs = Split-List $LinkArgs

if (-not (Test-Path -LiteralPath $CppRoot -PathType Container)) { Write-Fail "CppRoot is not an existing directory: $CppRoot" }
$CppRoot = (Resolve-Path -LiteralPath $CppRoot).Path.TrimEnd('\')
if (-not $WorkDir) { $WorkDir = Join-Path $CppRoot "port-work" }
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$WorkDir = (Resolve-Path -LiteralPath $WorkDir).Path
$objDir = Join-Path $WorkDir "obj"
New-Item -ItemType Directory -Force -Path $objDir | Out-Null
$resultPath = Join-Path $WorkDir "BUILD_RESULT.txt"

# ---- units ---------------------------------------------------------------------------------
$units = @()
if ($All) {
    $skipDirs = @("port-work", "build", "out", ".vs", ".git", "CMakeFiles", "x64", "Debug", "Release")
    $units = @(Get-ChildItem -LiteralPath $CppRoot -Recurse -File -Filter *.cpp | ForEach-Object { $_.FullName.Substring($CppRoot.Length).TrimStart('\') } | Where-Object { $rel = $_; @($rel.Split('\') | Where-Object { $skipDirs -contains $_ }).Count -eq 0 } | Sort-Object)
}
elseif ($Unit) {
    foreach ($u in $Unit) {
        $rel = $u.Replace('/', '\')
        $full = Join-Path $CppRoot $rel
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { Write-Fail "unit not found under CppRoot: $rel (looked at $full)" }
        $units += $rel
    }
}
else { Write-Fail "pass -Unit <relative .cpp/.h> (repeatable) or -All" }
if ($units.Count -eq 0) { Write-Fail "no .cpp files found under $CppRoot" }

# ---- compiler discovery ---------------------------------------------------------------------
$checked = New-Object System.Collections.ArrayList
$toolchain = $null   # hashtable: kind, exe, env (hashtable of env overrides), linker

function Get-LatestKitVersion {
    param([string]$KitsRoot)
    $inc = Join-Path $KitsRoot "Include"
    if (-not (Test-Path -LiteralPath $inc)) { return $null }
    $versions = @(Get-ChildItem -LiteralPath $inc -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "um\windows.h") } | ForEach-Object { $_.Name } | Sort-Object { [version]$_ } -Descending)
    if ($versions.Count -eq 0) { return $null }
    return $versions[0]
}

function New-MsvcToolchain {
    param([string]$Cl)
    # cl.exe lives at <MSVC>\bin\Host<h>\<arch>\cl.exe ; MSVC root is 3 levels up.
    $binDir = Split-Path -Parent $Cl
    $msvcRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $binDir))
    $arch = Split-Path -Leaf $binDir
    $incDir = Join-Path $msvcRoot "include"
    $libDir = Join-Path $msvcRoot "lib\$arch"
    if (-not (Test-Path -LiteralPath (Join-Path $incDir "string"))) {
        [void]$checked.Add("MSVC at $msvcRoot has no STL headers (missing $incDir\string) - partial install")
        return $null
    }
    $kitVer = Get-LatestKitVersion -KitsRoot $WindowsKitsRoot
    if (-not $kitVer) {
        [void]$checked.Add("Windows 10/11 SDK not found under $WindowsKitsRoot\Include (needs um\windows.h)")
        return $null
    }
    $kitInc = Join-Path $WindowsKitsRoot "Include\$kitVer"
    $kitLib = Join-Path $WindowsKitsRoot "Lib\$kitVer"
    $env = @{
        PATH    = "$binDir;" + (Join-Path $WindowsKitsRoot "bin\$kitVer\$arch") + ";" + $env:PATH
        INCLUDE = "$incDir;$kitInc\ucrt;$kitInc\um;$kitInc\shared;$kitInc\winrt"
        LIB     = "$libDir;$kitLib\ucrt\$arch;$kitLib\um\$arch"
    }
    return @{ kind = "msvc"; exe = $Cl; env = $env; linker = (Join-Path $binDir "link.exe"); note = "MSVC $(Split-Path -Leaf $msvcRoot) + SDK $kitVer (manual environment)" }
}

function Find-MsvcToolchain {
    if ($ClPath) {
        if (-not (Test-Path -LiteralPath $ClPath -PathType Leaf)) { [void]$checked.Add("-ClPath not found: $ClPath"); return $null }
        return (New-MsvcToolchain -Cl $ClPath)
    }
    $onPath = Get-Command cl.exe -ErrorAction SilentlyContinue
    if ($onPath -and $env:INCLUDE) {
        [void]$checked.Add("cl.exe on PATH with INCLUDE set: $($onPath.Source)")
        return @{ kind = "msvc"; exe = $onPath.Source; env = @{}; linker = "link.exe"; note = "cl.exe from PATH (existing environment)" }
    }
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $roots = @()
    if (Test-Path -LiteralPath $vswhere) {
        try { $roots = @(& $vswhere -all -prerelease -products * -property installationPath 2>$null | Where-Object { $_ }) } catch { }
        [void]$checked.Add("vswhere: $($roots.Count) Visual Studio instance(s)")
    }
    else { [void]$checked.Add("vswhere.exe not found at $vswhere") }
    foreach ($r in @("${env:ProgramFiles}\Microsoft Visual Studio\2022\BuildTools", "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools", "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\BuildTools")) {
        if ((Test-Path -LiteralPath $r) -and ($roots -notcontains $r)) { $roots += $r }
    }
    foreach ($r in $roots) {
        $tools = Join-Path $r "VC\Tools\MSVC"
        if (-not (Test-Path -LiteralPath $tools)) { [void]$checked.Add("$r has no VC\Tools\MSVC (C++ workload not installed)"); continue }
        $vers = @(Get-ChildItem -LiteralPath $tools -Directory | Sort-Object { [version]$_.Name } -Descending)
        foreach ($v in $vers) {
            $cl = Join-Path $v.FullName "bin\Hostx64\x64\cl.exe"
            if (Test-Path -LiteralPath $cl) {
                $tc = New-MsvcToolchain -Cl $cl
                if ($tc) { return $tc }
            }
            else { [void]$checked.Add("no cl.exe at $cl") }
        }
    }
    return $null
}

function Find-GccToolchain {
    $candidates = @()
    if ($GxxPath) {
        if (-not (Test-Path -LiteralPath $GxxPath -PathType Leaf)) { [void]$checked.Add("-GxxPath not found: $GxxPath"); return $null }
        $candidates += $GxxPath
    }
    else {
        $onPath = Get-Command g++.exe -ErrorAction SilentlyContinue
        if ($onPath) { $candidates += $onPath.Source }
        foreach ($pattern in @(
                "${env:ProgramFiles}\JetBrains\CLion*\bin\mingw\bin\g++.exe",
                "C:\msys64\ucrt64\bin\g++.exe", "C:\msys64\mingw64\bin\g++.exe",
                "C:\mingw64\bin\g++.exe", "C:\MinGW\bin\g++.exe",
                "C:\Qt\Tools\mingw*\bin\g++.exe", "C:\TDM-GCC-64\bin\g++.exe")) {
            $candidates += @(Get-Item -Path $pattern -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        }
        if ($candidates.Count -eq 0) { [void]$checked.Add("g++.exe not on PATH and not in known MinGW locations (CLion, msys64, mingw64, Qt, TDM-GCC)") }
    }
    foreach ($g in ($candidates | Select-Object -Unique)) {
        $binDir = Split-Path -Parent $g
        return @{ kind = "gcc"; exe = $g; env = @{ PATH = "$binDir;" + $env:PATH }; linker = $g; note = "MinGW g++ at $g" }
    }
    return $null
}

if ($Compiler -eq "msvc" -or $Compiler -eq "auto") { $toolchain = Find-MsvcToolchain }
if (-not $toolchain -and ($Compiler -eq "gcc" -or $Compiler -eq "auto")) { $toolchain = Find-GccToolchain }

if (-not $toolchain) {
    $lines = @("# BUILD_RESULT", "Status: NO_COMPILER", "Standard: $Standard", "Units: $($units.Count)", "", "## Checked", "")
    $lines += ($checked | ForEach-Object { "- $_" })
    $lines += @("", "## Remedy", "", "- Install the 'Desktop development with C++' workload (MSVC + Windows SDK), or pass -ClPath <...\bin\Hostx64\x64\cl.exe>.", "- Or use MinGW-w64: pass -GxxPath <...\g++.exe> (CLion, MSYS2 and Qt bundle one).")
    [System.IO.File]::WriteAllText($resultPath, (($lines -join "`n") + "`n"), $utf8)
    [Console]::Error.WriteLine("build-check: no usable C++ compiler found. See $resultPath")
    foreach ($c in $checked) { [Console]::Error.WriteLine("  - $c") }
    exit 2
}

foreach ($k in $toolchain.env.Keys) { Set-Item -Path "Env:$k" -Value $toolchain.env[$k] }

# ---- run compiler per unit ------------------------------------------------------------------
function Invoke-Tool {
    param([string]$Exe, [string[]]$Arguments, [string]$LogBase)
    $outFile = "$LogBase.out.txt"; $errFile = "$LogBase.err.txt"
    $quoted = $Arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }
    $p = Start-Process -FilePath $Exe -ArgumentList $quoted -NoNewWindow -PassThru -WorkingDirectory $objDir -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $null = $p.Handle
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        try { $p.Kill() } catch { }
        return @{ code = 124; text = "TIMEOUT after $TimeoutSeconds s" }
    }
    $text = ""
    if (Test-Path -LiteralPath $outFile) { $text += [System.IO.File]::ReadAllText($outFile) }
    if (Test-Path -LiteralPath $errFile) { $text += [System.IO.File]::ReadAllText($errFile) }
    return @{ code = $p.ExitCode; text = $text }
}

$msvcDiag = [regex]'(?m)^(?<file>.+?)\((?<line>\d+)(?:,\d+)?\)\s*:\s*(?<kind>fatal error|error|warning)\s+(?<code>[A-Z]+\d+)\s*:\s*(?<msg>.*)$'
$gccDiag = [regex]'(?m)^(?<file>[^\r\n]+?):(?<line>\d+):(?:\d+:)?\s*(?<kind>fatal error|error|warning):\s*(?<msg>.*)$'

function ConvertTo-Relative {
    param([string]$Path)
    $p = $Path.Trim().Replace('/', '\')
    if ($p.StartsWith($CppRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $p.Substring($CppRoot.Length + 1) }
    return $p
}

$errors = New-Object System.Collections.ArrayList
$warnings = New-Object System.Collections.ArrayList
$rawSections = New-Object System.Collections.ArrayList
$objects = @()
$unitResults = @()
$includeArgs = @()
$allIncludes = @($CppRoot) + @($IncludeDir | Where-Object { $_ })
foreach ($d in $allIncludes) { if ($toolchain.kind -eq "msvc") { $includeArgs += @("/I", $d) } else { $includeArgs += @("-I", $d) } }

foreach ($rel in $units) {
    $full = Join-Path $CppRoot $rel
    $isHeader = $rel -match '\.(h|hpp|hh)$'
    $objName = ($rel -replace '[\\/]', '__') -replace '\.(cpp|cc|cxx|h|hpp|hh)$', '.obj'
    $obj = Join-Path $objDir $objName
    if ($toolchain.kind -eq "msvc") {
        $args = @("/nologo", "/c", "/EHsc", "/std:$Standard", "/W4", "/utf-8", "/permissive-", "/Zc:__cplusplus") + $includeArgs
        if ($isHeader) { $args += @("/Zs", "/TP") } else { $args += @("/Fo$obj") }
        $args += @($ExtraArgs | Where-Object { $_ })
        $args += $full
    }
    else {
        $args = @("-std=$Standard", "-Wall", "-Wextra", "-finput-charset=UTF-8") + $includeArgs
        if ($isHeader) { $args += @("-fsyntax-only", "-x", "c++") } else { $args += @("-c", "-o", $obj) }
        $args += @($ExtraArgs | Where-Object { $_ })
        $args += $full
    }
    $r = Invoke-Tool -Exe $toolchain.exe -Arguments $args -LogBase (Join-Path $objDir ($objName + ".log"))
    $rx = if ($toolchain.kind -eq "msvc") { $msvcDiag } else { $gccDiag }
    $unitErr = 0; $unitWarn = 0
    foreach ($m in $rx.Matches($r.text)) {
        $code = if ($m.Groups["code"].Success) { $m.Groups["code"].Value } else { "" }
        $msg = $m.Groups["msg"].Value.Trim()
        if ($toolchain.kind -eq "gcc" -and $msg -match '\[(-W[\w=-]+)\]\s*$') { $code = $Matches[1] }
        $line = "{0}|{1}|{2}|{3}" -f (ConvertTo-Relative $m.Groups["file"].Value), $m.Groups["line"].Value, $code, $msg
        if ($m.Groups["kind"].Value -eq "warning") { $unitWarn++; if (-not $warnings.Contains($line)) { [void]$warnings.Add($line) } }
        else { $unitErr++; if (-not $errors.Contains($line)) { [void]$errors.Add($line) } }
    }
    if ($r.code -ne 0 -and $unitErr -eq 0) {
        $unitErr++
        [void]$errors.Add(("{0}|0||compiler exited with code {1} (see raw output)" -f $rel, $r.code))
    }
    $ok = ($r.code -eq 0 -and $unitErr -eq 0)
    if ($ok -and -not $isHeader) { $objects += $obj }
    $unitResults += [pscustomobject]@{ unit = $rel; ok = $ok; errors = $unitErr; warnings = $unitWarn }
    $trim = $r.text.Trim()
    if ($trim.Length -gt 4000) { $trim = $trim.Substring(0, 4000) + "`n...(truncated)" }
    [void]$rawSections.Add("### $rel (exit $($r.code))`n$trim")
}

# ---- optional link ---------------------------------------------------------------------------
$linkStatus = ""
if ($Link) {
    if (-not $OutputExe) { $OutputExe = Join-Path $WorkDir "out\app.exe" }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputExe) | Out-Null
    if (@($unitResults | Where-Object { -not $_.ok }).Count -gt 0) {
        $linkStatus = "SKIPPED (compile errors)"
    }
    elseif ($objects.Count -eq 0) {
        $linkStatus = "SKIPPED (no objects)"
    }
    else {
        if ($toolchain.kind -eq "msvc") { $largs = @("/nologo", "/OUT:$OutputExe") + $objects + @($LinkArgs | Where-Object { $_ }) }
        else { $largs = @("-municode", "-o", $OutputExe) + $objects + @($LinkArgs | Where-Object { $_ }) }
        $lr = Invoke-Tool -Exe $toolchain.linker -Arguments $largs -LogBase (Join-Path $objDir "link.log")
        if ($lr.code -eq 0 -and (Test-Path -LiteralPath $OutputExe)) { $linkStatus = "PASS -> $OutputExe" }
        else {
            $linkStatus = "FAIL (exit $($lr.code))"
            [void]$errors.Add(("link|0||" + ($lr.text.Trim() -replace '\s+', ' ')))
        }
        $linkRaw = $lr.text.Trim()
        if ($linkRaw.Length -gt 4000) { $linkRaw = $linkRaw.Substring(0, 4000) + "`n...(truncated)" }
        [void]$rawSections.Add("### link (exit $($lr.code)): " + ($largs -join ' ') + "`n$linkRaw")
    }
}

# ---- BUILD_RESULT.txt ------------------------------------------------------------------------
$status = if ($errors.Count -eq 0) { "PASS" } else { "FAIL" }
$out = New-Object System.Collections.ArrayList
[void]$out.Add("# BUILD_RESULT")
[void]$out.Add("Status: $status")
[void]$out.Add("Compiler: $($toolchain.kind) - $($toolchain.note)")
[void]$out.Add("Standard: $Standard")
[void]$out.Add("CppRoot: $CppRoot")
[void]$out.Add("Units: $($units.Count)")
foreach ($u in $unitResults) { [void]$out.Add(("Unit: {0} {1} errors={2} warnings={3}" -f $u.unit, $(if ($u.ok) { "OK" } else { "FAIL" }), $u.errors, $u.warnings)) }
if ($Link) { [void]$out.Add("Link: $linkStatus") }
[void]$out.Add("Errors: $($errors.Count)")
[void]$out.Add("Warnings: $($warnings.Count)")
[void]$out.Add("")
[void]$out.Add("## Errors (file|line|code|message)")
[void]$out.Add("")
if ($errors.Count -eq 0) { [void]$out.Add("(none)") } else { foreach ($e in $errors) { [void]$out.Add($e) } }
[void]$out.Add("")
[void]$out.Add("## Warnings (first 30, file|line|code|message)")
[void]$out.Add("")
if ($warnings.Count -eq 0) { [void]$out.Add("(none)") } else { foreach ($w in ($warnings | Select-Object -First 30)) { [void]$out.Add($w) } }
[void]$out.Add("")
[void]$out.Add("## Raw compiler output")
[void]$out.Add("")
foreach ($s in $rawSections) { [void]$out.Add($s); [void]$out.Add("") }
[System.IO.File]::WriteAllText($resultPath, (($out -join "`n") + "`n"), $utf8)

Write-Host "build-check: $status ($($toolchain.kind)) units=$($units.Count) errors=$($errors.Count) warnings=$($warnings.Count)$(if ($Link) { " link=$linkStatus" })"
Write-Host "  $resultPath"
if ($status -eq "PASS") { exit 0 } else { exit 1 }
