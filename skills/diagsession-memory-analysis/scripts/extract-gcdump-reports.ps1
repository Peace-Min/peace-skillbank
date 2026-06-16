param(
    [Parameter(Mandatory = $true)]
    [string[]]$InputPath,

    [string]$OutputDirectory,
    [string]$ToolPath = "C:\tools\dotnet-gcdump",
    [switch]$KeepExtractedGcdump
)

$ErrorActionPreference = "Stop"
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$tool = Join-Path $ToolPath "dotnet-gcdump.exe"

if (-not (Test-Path $tool)) {
    throw "dotnet-gcdump.exe not found: $tool"
}

Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-SafeFileName {
    param([Parameter(Mandatory = $true)][string]$Name)

    $safe = $Name
    foreach ($char in [System.IO.Path]::GetInvalidFileNameChars()) {
        $safe = $safe.Replace($char, "_")
    }
    return $safe
}

function Join-CommandLineArgument {
    param([Parameter(Mandatory = $true)][string]$Value)

    return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-GcdumpReport {
    param(
        [Parameter(Mandatory = $true)][string]$Tool,
        [Parameter(Mandatory = $true)][string]$GcdumpPath
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Tool
    $startInfo.Arguments = "report $(Join-CommandLineArgument -Value $GcdumpPath)"
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::Start($startInfo)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    if ($process.ExitCode -ne 0) {
        throw "dotnet-gcdump report failed for '$GcdumpPath': $stderr"
    }

    if ($stderr) {
        return ($stdout.TrimEnd() + [Environment]::NewLine + $stderr.TrimEnd())
    }

    return $stdout
}

function Get-DefaultOutputDirectory {
    param([Parameter(Mandatory = $true)][string[]]$ResolvedInputPath)

    if ($ResolvedInputPath.Count -eq 1) {
        $parent = Split-Path -Parent $ResolvedInputPath[0]
        if (-not $parent) {
            $parent = (Get-Location).Path
        }
        $name = [System.IO.Path]::GetFileNameWithoutExtension($ResolvedInputPath[0])
        return Join-Path $parent "$name.llm"
    }

    return Join-Path (Get-Location).Path "diagsession-gcdump-reports"
}

function Extract-GcdumpsFromDiagSession {
    param(
        [Parameter(Mandatory = $true)][string]$DiagSessionPath,
        [Parameter(Mandatory = $true)][string]$ExtractDirectory
    )

    $archive = [System.IO.Compression.ZipFile]::OpenRead($DiagSessionPath)
    try {
        $entries = @($archive.Entries | Where-Object {
            $_.FullName -match '\.gcdump$' -and $_.Length -gt 0
        })

        if ($entries.Count -eq 0) {
            throw "No .gcdump files were found in: $DiagSessionPath"
        }

        $index = 0
        $extracted = foreach ($entry in $entries) {
            $index++
            $baseName = [System.IO.Path]::GetFileName($entry.FullName)
            if (-not $baseName) {
                $baseName = "snapshot-$index.gcdump"
            }

            $safeName = Get-SafeFileName -Name ("{0:D2}-{1}" -f $index, $baseName)
            $targetPath = Join-Path $ExtractDirectory $safeName
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $targetPath, $true)
            $targetPath
        }

        return @($extracted)
    }
    finally {
        $archive.Dispose()
    }
}

$resolvedInputs = foreach ($path in $InputPath) {
    if (-not (Test-Path $path)) {
        throw "Input file not found: $path"
    }
    (Resolve-Path $path).Path
}

if (-not $OutputDirectory) {
    $OutputDirectory = Get-DefaultOutputDirectory -ResolvedInputPath $resolvedInputs
}

$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$extractDirectory = Join-Path $OutputDirectory "extracted-gcdumps"
$reportDirectory = Join-Path $OutputDirectory "reports"
$combinedReportPath = Join-Path $OutputDirectory "LLM_MEMORY_INPUT.txt"
$manifestPath = Join-Path $OutputDirectory "MANIFEST.txt"

New-Item -ItemType Directory -Force -Path $extractDirectory, $reportDirectory | Out-Null

$snapshots = New-Object System.Collections.Generic.List[object]

foreach ($input in $resolvedInputs) {
    $extension = [System.IO.Path]::GetExtension($input)

    if ($extension -ieq ".gcdump") {
        $snapshots.Add([pscustomobject]@{
            Source = $input
            Gcdump = $input
        })
        continue
    }

    if ($extension -ieq ".diagsession") {
        $sessionName = Get-SafeFileName -Name ([System.IO.Path]::GetFileNameWithoutExtension($input))
        $sessionExtractDirectory = Join-Path $extractDirectory $sessionName
        New-Item -ItemType Directory -Force -Path $sessionExtractDirectory | Out-Null

        foreach ($gcdump in (Extract-GcdumpsFromDiagSession -DiagSessionPath $input -ExtractDirectory $sessionExtractDirectory)) {
            $snapshots.Add([pscustomobject]@{
                Source = $input
                Gcdump = $gcdump
            })
        }
        continue
    }

    throw "Unsupported input extension '$extension'. Use .diagsession or .gcdump."
}

if ($snapshots.Count -eq 0) {
    throw "No gcdump snapshots were found."
}

@(
    "dotnet-gcdump LLM memory input"
    "Generated: $([DateTimeOffset]::Now.ToString("o"))"
    "Tool: $tool"
    "Output: $OutputDirectory"
    ""
) | Out-File -FilePath $combinedReportPath -Encoding utf8

@(
    "dotnet-gcdump LLM memory input manifest"
    "Generated: $([DateTimeOffset]::Now.ToString("o"))"
    "Output: $OutputDirectory"
    ""
) | Out-File -FilePath $manifestPath -Encoding utf8

$index = 0
foreach ($snapshot in $snapshots) {
    $index++
    $sourceName = [System.IO.Path]::GetFileNameWithoutExtension($snapshot.Source)
    $gcdumpName = [System.IO.Path]::GetFileNameWithoutExtension($snapshot.Gcdump)
    $reportName = Get-SafeFileName -Name ("{0:D2}-{1}-{2}.heapstat.txt" -f $index, $sourceName, $gcdumpName)
    $reportPath = Join-Path $reportDirectory $reportName

    $reportOutput = Invoke-GcdumpReport -Tool $tool -GcdumpPath $snapshot.Gcdump
    $reportOutput | Out-File -FilePath $reportPath -Encoding utf8

    @(
        "[$index]"
        "Source: $($snapshot.Source)"
        "Gcdump: $($snapshot.Gcdump)"
        "Report: $reportPath"
        ""
    ) | Out-File -FilePath $manifestPath -Encoding utf8 -Append

    @(
        ""
        "================================================================================"
        "Snapshot $index"
        "Source: $($snapshot.Source)"
        "Gcdump: $($snapshot.Gcdump)"
        "Report: $reportPath"
        "================================================================================"
        ""
    ) | Out-File -FilePath $combinedReportPath -Encoding utf8 -Append

    Get-Content $reportPath | Out-File -FilePath $combinedReportPath -Encoding utf8 -Append
}

if (-not $KeepExtractedGcdump) {
    Remove-Item -LiteralPath $extractDirectory -Recurse -Force
}

Write-Host "Processed $($snapshots.Count) gcdump snapshot(s)."
Write-Host "Combined LLM input: $combinedReportPath"
Write-Host "Manifest: $manifestPath"
Write-Host "Reports: $reportDirectory"
