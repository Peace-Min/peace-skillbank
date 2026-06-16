param(
    [Parameter(Mandatory = $true)]
    [string[]]$InputPath,

    [string]$RepositoryRoot,
    [string]$OutputDirectory,
    [string]$ToolPath,
    [int]$MinSnapshotCount = 2,
    [string]$SnapshotOrder = "Snapshot 1 = before repeated action; Snapshot 2 = after repeated action",
    [string]$RepeatedAction = "unknown",
    [string]$RepeatCount = "unknown",
    [string]$StartPoint = "unknown",
    [string]$RelatedCode = "unknown",
    [string]$LlmExecutable,
    [string]$LlmArgumentLine,
    [string[]]$LlmArguments = @(),
    [string]$ResponsePath,
    [switch]$RequireModelResponse
)

$ErrorActionPreference = "Stop"
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

if (-not $RepositoryRoot) {
    $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}

. (Join-Path $PSScriptRoot "diagsession-report-contract.ps1")

function Assert-Condition {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Join-CommandLineArgument {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-TextModel {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [string]$ArgumentLine,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][string]$InputText,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][string]$ErrorPath
    )

    $command = Get-Command $Executable -ErrorAction SilentlyContinue
    if (-not $command) {
        throw "LLM executable not found: $Executable"
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $command.Source
    if ($ArgumentLine) {
        $startInfo.Arguments = $ArgumentLine
    }
    else {
        $startInfo.Arguments = (($Arguments | ForEach-Object { Join-CommandLineArgument -Value $_ }) -join " ")
    }
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::Start($startInfo)
    $process.StandardInput.Write($InputText)
    $process.StandardInput.Close()

    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    $stdout | Out-File -FilePath $OutputPath -Encoding utf8
    $stderr | Out-File -FilePath $ErrorPath -Encoding utf8

    if ($process.ExitCode -ne 0) {
        throw "LLM command failed with exit code $($process.ExitCode). See $ErrorPath"
    }
}

$skillRoot = Join-Path $RepositoryRoot "skills\diagsession-memory-analysis"
$extractScript = Join-Path $skillRoot "scripts\extract-gcdump-reports.ps1"
$modelPromptPath = Join-Path $skillRoot "references\model-agnostic-prompt.md"
$templatePath = Join-Path $skillRoot "references\standard-report-template.md"

Assert-Condition (Test-Path -LiteralPath $extractScript -PathType Leaf) "Missing extract script: $extractScript"
Assert-Condition (Test-Path -LiteralPath $modelPromptPath -PathType Leaf) "Missing model prompt: $modelPromptPath"
Assert-Condition (Test-Path -LiteralPath $templatePath -PathType Leaf) "Missing report template: $templatePath"

$resolvedInputs = foreach ($path in $InputPath) {
    Assert-Condition (Test-Path -LiteralPath $path -PathType Leaf) "Input file not found: $path"
    $resolved = (Resolve-Path -LiteralPath $path).Path
    $extension = [System.IO.Path]::GetExtension($resolved)
    Assert-Condition (($extension -ieq ".diagsession") -or ($extension -ieq ".gcdump")) "Unsupported input extension '$extension': $resolved"
    $resolved
}

if (-not $OutputDirectory) {
    $runId = [DateTimeOffset]::Now.ToString("yyyyMMdd-HHmmss")
    $OutputDirectory = Join-Path (Join-Path $RepositoryRoot "out\diagsession-analysis-loop") $runId
}

$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$extractOutputDirectory = Join-Path $OutputDirectory "extract"
$requestPath = Join-Path $OutputDirectory "LLM_REQUEST.md"
$runSummaryPath = Join-Path $OutputDirectory "RUN_SUMMARY.md"
$extractLogPath = Join-Path $OutputDirectory "EXTRACT_LOG.txt"
$modelResponsePath = Join-Path $OutputDirectory "MODEL_RESPONSE.md"
$modelErrorPath = Join-Path $OutputDirectory "MODEL_RESPONSE.stderr.txt"
$responseValidationPath = Join-Path $OutputDirectory "RESPONSE_VALIDATION.md"

New-Item -ItemType Directory -Force -Path $OutputDirectory, $extractOutputDirectory | Out-Null

$extractArgs = @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    $extractScript,
    "-InputPath"
)
$extractArgs += $resolvedInputs
$extractArgs += @("-OutputDirectory", $extractOutputDirectory, "-KeepExtractedGcdump")
if ($ToolPath) {
    $extractArgs += @("-ToolPath", $ToolPath)
}

$extractConsole = & powershell @extractArgs 2>&1
$extractExitCode = $LASTEXITCODE
$extractConsole | Out-File -FilePath $extractLogPath -Encoding utf8
if ($extractExitCode -ne 0) {
    throw "Extraction command failed with exit code $extractExitCode. See $extractLogPath"
}

$manifestPath = Join-Path $extractOutputDirectory "MANIFEST.txt"
$llmMemoryInputPath = Join-Path $extractOutputDirectory "LLM_MEMORY_INPUT.txt"
$reportsDirectory = Join-Path $extractOutputDirectory "reports"

Assert-Condition (Test-Path -LiteralPath $manifestPath -PathType Leaf) "Missing MANIFEST.txt"
Assert-Condition (Test-Path -LiteralPath $llmMemoryInputPath -PathType Leaf) "Missing LLM_MEMORY_INPUT.txt"
Assert-Condition (Test-Path -LiteralPath $reportsDirectory -PathType Container) "Missing reports directory"

$manifestText = Get-Content -Raw -LiteralPath $manifestPath
$llmMemoryInputText = Get-Content -Raw -LiteralPath $llmMemoryInputPath
$snapshotCount = ([regex]::Matches($manifestText, '(?m)^\[(\d+)\]\s*$')).Count
$reportFiles = @(Get-ChildItem -LiteralPath $reportsDirectory -Filter "*.heapstat.txt" -File)
$gcdumpPaths = @([regex]::Matches($manifestText, '(?m)^Gcdump:\s*(.+)$') | ForEach-Object { $_.Groups[1].Value.Trim() })
$archiveEntries = @([regex]::Matches($manifestText, '(?m)^ArchiveEntry:\s*(.+)$') | ForEach-Object { $_.Groups[1].Value.Trim() } | Where-Object { $_ })

Assert-Condition ($snapshotCount -ge $MinSnapshotCount) "Expected at least $MinSnapshotCount snapshot(s), found $snapshotCount"
Assert-Condition ($reportFiles.Count -eq $snapshotCount) "Expected $snapshotCount heapstat report(s), found $($reportFiles.Count)"
Assert-Condition ($gcdumpPaths.Count -eq $snapshotCount) "Expected $snapshotCount gcdump path(s) in manifest, found $($gcdumpPaths.Count)"
Assert-Condition ((Get-Item -LiteralPath $llmMemoryInputPath).Length -gt 100) "LLM_MEMORY_INPUT.txt is too small to be useful"

foreach ($gcdumpPath in $gcdumpPaths) {
    Assert-Condition (Test-Path -LiteralPath $gcdumpPath -PathType Leaf) "Manifest gcdump path does not exist. The loop test keeps extracted dumps for audit: $gcdumpPath"
}

foreach ($index in 1..$snapshotCount) {
    Assert-Condition ($llmMemoryInputText.Contains("Snapshot $index")) "LLM_MEMORY_INPUT.txt missing Snapshot $index marker"
}

$modelPrompt = Get-Content -Raw -LiteralPath $modelPromptPath
$reportTemplate = Get-Content -Raw -LiteralPath $templatePath

$inputListText = ($resolvedInputs | ForEach-Object { "- $_" }) -join [Environment]::NewLine
$headingListText = (Get-DiagSessionAnalysisReportHeadings | ForEach-Object { "- $_" }) -join [Environment]::NewLine

$requestText = @(
    "# DiagSession Memory Analysis LLM Request"
    ""
    "Use the evidence below to produce a managed-memory leak analysis report."
    ""
    "## User Context"
    ""
    "- Input files:"
    $inputListText
    "- Snapshot order: $SnapshotOrder"
    "- Repeated action: $RepeatedAction"
    "- Repeat count: $RepeatCount"
    "- Code start point: $StartPoint"
    "- Related code/classes: $RelatedCode"
    ""
    "## Required Output Contract"
    ""
    "Return the answer as a Markdown document using these exact headings:"
    ""
    $headingListText
    ""
    "Do not edit source code. This is an analysis-only response."
    ""
    "## Base Analysis Instructions"
    ""
    $modelPrompt
    ""
    "## Standard Report Template"
    ""
    $reportTemplate
    ""
    "## Evidence: LLM_MEMORY_INPUT.txt"
    ""
    '```text'
    $llmMemoryInputText
    '```'
) -join [Environment]::NewLine

$requestText | Out-File -FilePath $requestPath -Encoding utf8

$validatedResponsePath = $null
if ($LlmExecutable) {
    Invoke-TextModel -Executable $LlmExecutable -ArgumentLine $LlmArgumentLine -Arguments $LlmArguments -InputText $requestText -OutputPath $modelResponsePath -ErrorPath $modelErrorPath
    $validatedResponsePath = $modelResponsePath
}
elseif ($ResponsePath) {
    Assert-Condition (Test-Path -LiteralPath $ResponsePath -PathType Leaf) "ResponsePath not found: $ResponsePath"
    $validatedResponsePath = (Resolve-Path -LiteralPath $ResponsePath).Path
}
elseif ($RequireModelResponse) {
    throw "Model response is required, but neither -LlmExecutable nor -ResponsePath was provided."
}

$responseStatus = "not-run"
if ($validatedResponsePath) {
    Test-DiagSessionAnalysisReport -ResponsePath $validatedResponsePath -ValidationReportPath $responseValidationPath | Out-Null
    $responseStatus = "validated"
}

$archiveEntrySummary = if ($archiveEntries.Count -gt 0) { $archiveEntries -join [Environment]::NewLine } else { "none" }
$summary = @(
    "# DiagSession Analysis Loop Summary"
    ""
    "- Status: passed"
    "- OutputDirectory: $OutputDirectory"
    "- SnapshotCount: $snapshotCount"
    "- MinSnapshotCount: $MinSnapshotCount"
    "- ReportCount: $($reportFiles.Count)"
    "- GcdumpCount: $($gcdumpPaths.Count)"
    "- ResponseStatus: $responseStatus"
    ""
    "## Generated Files"
    ""
    "- Manifest: $manifestPath"
    "- LLM memory input: $llmMemoryInputPath"
    "- LLM request: $requestPath"
    "- Extract log: $extractLogPath"
    "- Response validation: $responseValidationPath"
    ""
    "## Archive Entries"
    ""
    $archiveEntrySummary
    ""
    "## Next Step"
    ""
    "If ResponseStatus is not-run, paste LLM_REQUEST.md into Claude, Codex, or a local LLM, save the answer as MODEL_RESPONSE.md, then run tests\validate-diagsession-response.ps1 against that file."
)
$summary | Out-File -FilePath $runSummaryPath -Encoding utf8

Write-Host "DiagSession analysis loop validation passed."
Write-Host "Snapshots: $snapshotCount"
Write-Host "LLM request: $requestPath"
Write-Host "Run summary: $runSummaryPath"
if ($validatedResponsePath) {
    Write-Host "Validated response: $validatedResponsePath"
}
