param(
    [Parameter(Mandatory = $true)]
    [string[]]$InputPath,

    [string]$OutputDirectory,
    [string]$ToolPath,
    [switch]$IncludeFullPathsInLlmInput,
    [switch]$KeepExtractedGcdump
)

$ErrorActionPreference = "Stop"
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

Add-Type -AssemblyName System.IO.Compression.FileSystem

function Resolve-GcdumpTool {
    param([string]$ToolPath)

    if ($ToolPath) {
        if ((Test-Path -LiteralPath $ToolPath -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $ToolPath).Path
        }

        if ((Test-Path -LiteralPath $ToolPath -PathType Container)) {
            $candidate = Join-Path $ToolPath "dotnet-gcdump.exe"
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return (Resolve-Path -LiteralPath $candidate).Path
            }
        }

        $candidate = Join-Path $ToolPath "dotnet-gcdump.exe"
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }

        throw "dotnet-gcdump.exe not found from ToolPath: $ToolPath"
    }

    foreach ($commandName in @("dotnet-gcdump.exe", "dotnet-gcdump")) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue
        if ($command) {
            return $command.Source
        }
    }

    $defaultTool = "C:\tools\dotnet-gcdump\dotnet-gcdump.exe"
    if (Test-Path -LiteralPath $defaultTool -PathType Leaf) {
        return (Resolve-Path -LiteralPath $defaultTool).Path
    }

    throw "dotnet-gcdump.exe not found. Install dotnet-gcdump or pass -ToolPath with a directory or full executable path."
}

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
    # dotnet-gcdump writes UTF-8; decode it as UTF-8 so non-ASCII text and paths (e.g. Korean) are not
    # mangled by the console OEM/CP949 code page under Windows PowerShell 5.1. This also keeps the
    # echoed paths byte-accurate so ConvertTo-LlmSafeText can redact them.
    $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        # Read both streams concurrently to avoid a pipe-buffer deadlock when the child fills one
        # stream (e.g. a large stderr) while the parent blocks reading the other to completion.
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(180000)) {
            try { $process.Kill() } catch {}
            throw "dotnet-gcdump report timed out (180s) for '$GcdumpPath'."
        }
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result

        if ($process.ExitCode -ne 0) {
            throw "dotnet-gcdump report failed for '$GcdumpPath': $stderr"
        }

        if ($stderr) {
            return ($stdout.TrimEnd() + [Environment]::NewLine + $stderr.TrimEnd())
        }
        return $stdout
    }
    finally {
        $process.Dispose()
    }
}

function Format-LlmPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$IncludeFullPath
    )

    if ($IncludeFullPath) {
        return $Path
    }

    return [System.IO.Path]::GetFileName($Path)
}

function ConvertTo-LlmSafeText {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][object[]]$PathMap,
        [switch]$IncludeFullPath
    )

    if ($IncludeFullPath) {
        return $Text
    }

    $safeText = $Text
    foreach ($item in $PathMap) {
        if ($item.FullPath) {
            $safeText = [regex]::Replace(
                $safeText,
                [regex]::Escape($item.FullPath),
                [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $item.SafeName },
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
            )
        }
    }

    return $safeText
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

function Format-DiagSessionEntrySummary {
    param([Parameter(Mandatory = $true)][object[]]$Entries)

    $interestingExtensions = @(".gcdump", ".heapstate", ".dmp", ".etl", ".nettrace", ".vsp", ".vspx")
    $extensionCounts = foreach ($extension in $interestingExtensions) {
        $count = @($Entries | Where-Object {
            [System.IO.Path]::GetExtension($_.FullName) -ieq $extension
        }).Count

        if ($count -gt 0) {
            "$extension=$count"
        }
    }

    $sampleEntries = @($Entries |
        Where-Object { $_.Length -gt 0 } |
        Select-Object -First 10 |
        ForEach-Object { "$($_.FullName) ($($_.Length) bytes)" })

    $summary = @()
    if ($extensionCounts) {
        $summary += "Detected diagnostic entries: $($extensionCounts -join ', ')"
    }
    else {
        $summary += "Detected diagnostic entries: none with known dump/trace extensions"
    }

    if ($sampleEntries.Count -gt 0) {
        $summary += "Sample entries: $($sampleEntries -join '; ')"
    }

    return $summary -join " "
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
            $allEntries = @($archive.Entries)
            $entrySummary = Format-DiagSessionEntrySummary -Entries $allEntries
            throw "No .gcdump files were found in: $DiagSessionPath. $entrySummary This gcdump-only parser cannot parse Visual Studio .heapstate/.dmp snapshots."
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
            [pscustomobject]@{
                Gcdump = $targetPath
                ArchiveIndex = $index
                ArchiveEntry = $entry.FullName
                ArchiveEntryLastWriteTime = $entry.LastWriteTime.ToString("o")
                ArchiveEntryLengthBytes = $entry.Length
            }
        }

        return @($extracted)
    }
    finally {
        $archive.Dispose()
    }
}

# Allow dot-sourcing for tests: when sourced (InvocationName '.'), expose the functions above
# without running the extraction pipeline below. Normal invocation (-File / & ) is unaffected.
if ($MyInvocation.InvocationName -eq '.') { return }

$resolvedInputs = foreach ($path in $InputPath) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Input file not found: $path"
    }
    (Resolve-Path -LiteralPath $path).Path
}

if (-not $OutputDirectory) {
    $OutputDirectory = Get-DefaultOutputDirectory -ResolvedInputPath $resolvedInputs
}

$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$runId = [DateTimeOffset]::Now.ToString("yyyyMMdd-HHmmss")
$extractDirectory = Join-Path (Join-Path $OutputDirectory "extracted-gcdumps") $runId
$reportDirectory = Join-Path $OutputDirectory "reports"
$combinedReportPath = Join-Path $OutputDirectory "LLM_MEMORY_INPUT.txt"
$manifestPath = Join-Path $OutputDirectory "MANIFEST.txt"

New-Item -ItemType Directory -Force -Path $extractDirectory, $reportDirectory | Out-Null

$snapshots = New-Object System.Collections.Generic.List[object]

foreach ($resolvedInput in $resolvedInputs) {
    $extension = [System.IO.Path]::GetExtension($resolvedInput)

    if ($extension -ieq ".gcdump") {
        $snapshots.Add([pscustomobject]@{
            Source = $resolvedInput
            Gcdump = $resolvedInput
            ArchiveIndex = $null
            ArchiveEntry = $null
            ArchiveEntryLastWriteTime = $null
            ArchiveEntryLengthBytes = $null
        })
        continue
    }

    if ($extension -ieq ".diagsession") {
        $sessionName = Get-SafeFileName -Name ([System.IO.Path]::GetFileNameWithoutExtension($resolvedInput))
        $sessionExtractDirectory = Join-Path $extractDirectory $sessionName
        New-Item -ItemType Directory -Force -Path $sessionExtractDirectory | Out-Null

        foreach ($extracted in (Extract-GcdumpsFromDiagSession -DiagSessionPath $resolvedInput -ExtractDirectory $sessionExtractDirectory)) {
            $snapshots.Add([pscustomobject]@{
                Source = $resolvedInput
                Gcdump = $extracted.Gcdump
                ArchiveIndex = $extracted.ArchiveIndex
                ArchiveEntry = $extracted.ArchiveEntry
                ArchiveEntryLastWriteTime = $extracted.ArchiveEntryLastWriteTime
                ArchiveEntryLengthBytes = $extracted.ArchiveEntryLengthBytes
            })
        }
        continue
    }

    throw "Unsupported input extension '$extension'. Use .diagsession or .gcdump."
}

if ($snapshots.Count -eq 0) {
    throw "No gcdump snapshots were found."
}

# Resolve the tool only AFTER confirming there is at least one .gcdump to report on, so an
# unsupported .diagsession (only .heapstate/.dmp) is diagnosed before a missing-dotnet-gcdump error.
$tool = Resolve-GcdumpTool -ToolPath $ToolPath

@(
    "dotnet-gcdump LLM memory input"
    "Generated: $([DateTimeOffset]::Now.ToString("o"))"
    "Tool: dotnet-gcdump"
    "Output: redacted"
    "PathPolicy: file names only; see MANIFEST.txt for local paths"
    ""
) | Out-File -FilePath $combinedReportPath -Encoding utf8

@(
    "dotnet-gcdump LLM memory input manifest"
    "Generated: $([DateTimeOffset]::Now.ToString("o"))"
    "Output: $OutputDirectory"
    ""
) | Out-File -FilePath $manifestPath -Encoding utf8

# Generate reports; always clean up extracted dumps afterward (even on a mid-run failure).
try {
$index = 0
foreach ($snapshot in $snapshots) {
    $index++
    $sourceName = [System.IO.Path]::GetFileNameWithoutExtension($snapshot.Source)
    $gcdumpName = [System.IO.Path]::GetFileNameWithoutExtension($snapshot.Gcdump)
    $reportName = Get-SafeFileName -Name ("{0:D2}-{1}-{2}.heapstat.txt" -f $index, $sourceName, $gcdumpName)
    $reportPath = Join-Path $reportDirectory $reportName
    $llmSource = Format-LlmPath -Path $snapshot.Source -IncludeFullPath:$IncludeFullPathsInLlmInput
    $llmGcdump = Format-LlmPath -Path $snapshot.Gcdump -IncludeFullPath:$IncludeFullPathsInLlmInput
    $llmReport = Format-LlmPath -Path $reportPath -IncludeFullPath:$IncludeFullPathsInLlmInput
    $gcdumpLengthBytes = (Get-Item -LiteralPath $snapshot.Gcdump).Length
    $gcdumpRetention = if (-not $snapshot.ArchiveEntry) {
        "input-file"
    }
    elseif ($KeepExtractedGcdump) {
        "kept"
    }
    else {
        "removed-after-report"
    }
    $pathMap = @(
        [pscustomobject]@{ FullPath = $snapshot.Source; SafeName = $llmSource }
        [pscustomobject]@{ FullPath = $snapshot.Gcdump; SafeName = $llmGcdump }
        [pscustomobject]@{ FullPath = $reportPath; SafeName = $llmReport }
        [pscustomobject]@{ FullPath = $OutputDirectory; SafeName = "<output-directory>" }
        [pscustomobject]@{ FullPath = $extractDirectory; SafeName = "<extract-directory>" }
        [pscustomobject]@{ FullPath = $tool; SafeName = "dotnet-gcdump" }
    )

    $reportOutput = Invoke-GcdumpReport -Tool $tool -GcdumpPath $snapshot.Gcdump
    $llmReportOutput = ConvertTo-LlmSafeText -Text $reportOutput -PathMap $pathMap -IncludeFullPath:$IncludeFullPathsInLlmInput
    $reportOutput | Out-File -FilePath $reportPath -Encoding utf8

    @(
        "[$index]"
        "Source: $($snapshot.Source)"
        "ArchiveIndex: $($snapshot.ArchiveIndex)"
        "ArchiveEntry: $($snapshot.ArchiveEntry)"
        "ArchiveEntryLastWriteTime: $($snapshot.ArchiveEntryLastWriteTime)"
        "ArchiveEntryLengthBytes: $($snapshot.ArchiveEntryLengthBytes)"
        "Gcdump: $($snapshot.Gcdump)"
        "GcdumpLengthBytes: $gcdumpLengthBytes"
        "GcdumpRetention: $gcdumpRetention"
        "Report: $reportPath"
        ""
    ) | Out-File -FilePath $manifestPath -Encoding utf8 -Append

    @(
        ""
        "================================================================================"
        "Snapshot $index"
        "Source: $llmSource"
        "ArchiveIndex: $($snapshot.ArchiveIndex)"
        "ArchiveEntry: $($snapshot.ArchiveEntry)"
        "ArchiveEntryLastWriteTime: $($snapshot.ArchiveEntryLastWriteTime)"
        "ArchiveEntryLengthBytes: $($snapshot.ArchiveEntryLengthBytes)"
        "Gcdump: $llmGcdump"
        "GcdumpLengthBytes: $gcdumpLengthBytes"
        "GcdumpRetention: $gcdumpRetention"
        "Report: $llmReport"
        "================================================================================"
        ""
    ) | Out-File -FilePath $combinedReportPath -Encoding utf8 -Append

    $llmReportOutput | Out-File -FilePath $combinedReportPath -Encoding utf8 -Append
}

}
finally {
    # Honor the 'removed-after-report' retention promise even if a report threw mid-run.
    # Guarded so cleanup never masks the original error.
    if (-not $KeepExtractedGcdump -and (Test-Path -LiteralPath $extractDirectory)) {
        Remove-Item -LiteralPath $extractDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Processed $($snapshots.Count) gcdump snapshot(s)."
Write-Host "Combined LLM input: $combinedReportPath"
Write-Host "Manifest: $manifestPath"
Write-Host "Reports: $reportDirectory"
