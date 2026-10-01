param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$Gpp = $env:CS2CPP_GPP   # optional explicit g++ path
)

# Behavioural fixtures for the cs2cpp-port skill:
#   1. static checks (no tools needed): every pattern header in references/*.md is found, none uses C++20 library
#      or language features, and Win32 headers are included only through Win32.h (checker tested on a bad sample).
#   2. when a compiler exists (MSVC via vswhere with a complete C++ workload, else MinGW g++): the headers are extracted,
#      tests/fixtures/cs2cpp-port/PatternTests.cpp is compiled as C++17 with the warning set from references/env.md
#      treated as errors, and the behaviour tests are run (NetCompat parsing/rounding/indexers/exception hierarchy,
#      ActionQueueThread incl. 16 queues on RunOnCurrentThread, ThreadTimer modes and Dispose, ByteStream both orders,
#      FieldVisit, TextEncoding, UdpSocket loopback/Receive/multicast).

$ErrorActionPreference = "Stop"

function Assert-Fixture {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "cs2cpp-port fixture failed: $Message" }
}

$skill = Join-Path $RepositoryRoot "skills\cs2cpp-port"
$fixture = Join-Path $RepositoryRoot "tests\fixtures\cs2cpp-port\PatternTests.cpp"
$out = Join-Path $RepositoryRoot "out\cs2cpp-port-fixtures"

# --- 1. extract pattern headers ---
$headers = @{}
foreach ($md in Get-ChildItem -LiteralPath (Join-Path $skill "references") -Filter *.md) {
    $text = [System.IO.File]::ReadAllText($md.FullName, [System.Text.Encoding]::UTF8)
    foreach ($m in [regex]::Matches($text, '(?s)```cpp\r?\n(.*?)```')) {
        $code = $m.Groups[1].Value
        $first = ($code -split "`n")[0].Trim()
        $hm = [regex]::Match($first, '^//\s*(\w+\.h)\b')
        if ($hm.Success) { $headers[$hm.Groups[1].Value] = $code }
    }
}
foreach ($required in @("ActionQueueThread.h", "ThreadTimer.h", "WaitHandle.h", "Stopwatch.h", "Event.h", "StrFormat.h", "Logger.h", "Win32.h", "UdpSocket.h", "NetCompat.h", "ByteStream.h", "MsgFactory.h", "TextEncoding.h", "FieldVisit.h")) {
    Assert-Fixture ($headers.ContainsKey($required)) "pattern header not found in references: $required"
}

# --- 2. C++17 guard (negative path first) ---
$forbidden = @(
    '\.contains\s*\(', '\.starts_with\s*\(', '\.ends_with\s*\(', 'std::format\b', '<format>', 'std::span\b',
    'std::bit_cast\b', 'std::jthread\b', 'std::stop_token\b', '<=>', '\bconsteval\b', '\bconstinit\b',
    'std::ranges::', 'std::source_location\b', 'std::erase_if\b', '\bconcept\s+\w+', '\brequires\s*\('
)
$badSample = "if (m.contains(k)) { auto s = std::format(""{}"", 1); std::span<int> v; }"
Assert-Fixture (@($forbidden | Where-Object { $badSample -match $_ }).Count -ge 3) "C++17 guard did not flag the bad sample"
foreach ($name in $headers.Keys) {
    $code = $headers[$name]
    foreach ($f in $forbidden) { Assert-Fixture (-not ($code -match $f)) "header $name uses a C++20 feature: $f" }
    Assert-Fixture (-not ($code -match 'using\s+namespace\s+std\s*;')) "header $name uses 'using namespace std;'"
    if ($name -ne "Win32.h") {
        Assert-Fixture (-not ($code -match '#include\s*<(windows|winsock2|ws2tcpip)\.h>')) "header $name includes Win32 headers directly (use Win32.h)"
    }
}
Write-Host "cs2cpp-port fixtures: static checks passed ($($headers.Count) pattern headers)."

# --- 3. find a compiler ---
$msvc = $null
$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path -LiteralPath $vswhere) {
    $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
    if ($vsPath) {
        $vcvarsall = Join-Path $vsPath "VC\Auxiliary\Build\vcvarsall.bat"
        $msvcInclude = @(Get-ChildItem -Path (Join-Path $vsPath "VC\Tools\MSVC\*\include") -Directory -ErrorAction SilentlyContinue)
        if ((Test-Path -LiteralPath $vcvarsall) -and $msvcInclude.Count -gt 0) { $msvc = $vcvarsall }
    }
}
if (-not $msvc -and -not $Gpp) {
    $cmd = Get-Command g++ -ErrorAction SilentlyContinue
    if ($cmd) { $Gpp = $cmd.Source }
}
if (-not $msvc -and -not $Gpp) {
    $candidates = @()
    $candidates += @(Get-ChildItem -Path (Join-Path $env:ProgramFiles "JetBrains\*\bin\mingw\bin\g++.exe") -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    $candidates += @("C:\msys64\mingw64\bin\g++.exe", "C:\mingw64\bin\g++.exe", "C:\TDM-GCC-64\bin\g++.exe")
    $Gpp = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}
if (-not $msvc -and -not $Gpp) {
    Write-Host "cs2cpp-port fixtures: no C++ compiler found (MSVC C++ workload or MinGW g++); compile/run skipped (static checks passed)."
    return
}

# --- 4. build ---
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Recurse -Force }
New-Item -ItemType Directory -Force -Path $out | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
foreach ($name in $headers.Keys) { [System.IO.File]::WriteAllText((Join-Path $out $name), $headers[$name], $utf8) }
Copy-Item -LiteralPath $fixture -Destination (Join-Path $out "PatternTests.cpp")
$exe = Join-Path $out "PatternTests.exe"
$defines = "/DWIN32_LEAN_AND_MEAN /DNOMINMAX /D_WIN32_WINNT=0x0A00 /DUNICODE /D_UNICODE"
if ($msvc) {
    $warn = "/W4 /we4244 /we4267 /we4018 /we4389 /we4706 /we4715 /we4700"
    $cl = "cl /nologo /std:c++17 /permissive- /utf-8 /Zc:__cplusplus /EHsc /MD $warn $defines PatternTests.cpp /Fe:PatternTests.exe Ws2_32.lib Winmm.lib"
    $buildLog = & cmd.exe /d /c "call `"$msvc`" x64 >nul && cd /d `"$out`" && $cl" 2>&1 | Out-String
    $compiler = "MSVC"
}
else {
    Push-Location $out
    try {
        $env:PATH = (Split-Path -Parent $Gpp) + ";" + $env:PATH
        $buildLog = & $Gpp -std=c++17 -pedantic -Wall -Wextra -Wshadow -Wconversion -Wsign-conversion -Wno-unknown-pragmas -Werror -O1 -DUNICODE -D_UNICODE -D_WIN32_WINNT=0x0A00 PatternTests.cpp -o PatternTests.exe -lws2_32 -lwinmm 2>&1 | Out-String
    }
    finally { Pop-Location }
    $compiler = "g++"
}
Assert-Fixture (Test-Path -LiteralPath $exe) "build failed with ${compiler}:`n$buildLog"

# --- 5. run (timer checks depend on OS scheduling; one retry separates a blip from a real failure) ---
$passed = $false
$lastFails = ""
for ($attempt = 1; $attempt -le 2 -and -not $passed; $attempt++) {
    $result = @(& $exe)
    $code = $LASTEXITCODE
    $lastFails = (@($result | Where-Object { $_ -like 'FAIL*' }) -join '; ')
    if ($code -eq 0 -and ($result -contains 'ALL OK')) {
        $passed = $true
        $count = @($result | Where-Object { $_ -like 'PASS*' }).Count
        Write-Host "cs2cpp-port fixtures passed with $compiler ($count behaviour checks, attempt $attempt)."
    }
}
Assert-Fixture $passed "pattern behaviour tests failed twice: $lastFails"
