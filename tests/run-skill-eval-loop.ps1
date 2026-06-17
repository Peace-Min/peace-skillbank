param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath,

    [string]$RepositoryRoot,
    [string]$ToolPath,
    [string]$OllamaModel = "qwen2.5-coder:7b",
    [int]$OllamaTimeoutSeconds = 300,
    [string]$OutputDirectory,
    [string]$RepeatedAction = "unknown",
    [string]$RepeatCount = "unknown",
    [string]$StartPoint = "unknown",
    [string]$RelatedCode = "unknown",
    [string]$SnapshotOrder = "Snapshot 1 = before repeated action; Snapshot 2 = after repeated action",
    [switch]$SkipModel
)

# A self-contained eval loop for the diagsession-memory-analysis skill.
# It uses file redirection for child process streams so background runs cannot block on pipes.

$ErrorActionPreference = "Stop"
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $RepositoryRoot) { $RepositoryRoot = (Resolve-Path (Join-Path $scriptDir "..")).Path }

function Test-IsChildPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ParentPath
    )

    $trimChars = [char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd($trimChars)
    $fullParent = [System.IO.Path]::GetFullPath($ParentPath).TrimEnd($trimChars)
    return $fullPath.StartsWith($fullParent + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
}

. (Join-Path $scriptDir "diagsession-report-contract.ps1")

$skillRoot = Join-Path $RepositoryRoot "skills\diagsession-memory-analysis"
$extractScript = Join-Path $skillRoot "scripts\extract-gcdump-reports.ps1"
$modelPrompt = Get-Content -Raw -LiteralPath (Join-Path $skillRoot "references\model-agnostic-prompt.md")
$template = Get-Content -Raw -LiteralPath (Join-Path $skillRoot "references\standard-report-template.md")

if (-not $OutputDirectory) {
    $runId = [DateTimeOffset]::Now.ToString("yyyyMMdd-HHmmss")
    $OutputDirectory = Join-Path (Join-Path $RepositoryRoot "out\skill-eval-loop") $runId
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$safeOutputRoot = Join-Path $RepositoryRoot "out"
if (Test-Path -LiteralPath $OutputDirectory) {
    if (-not (Test-IsChildPath -Path $OutputDirectory -ParentPath $safeOutputRoot)) {
        throw "Refusing to remove OutputDirectory outside the repository out directory: $OutputDirectory"
    }
    Remove-Item -Recurse -Force -LiteralPath $OutputDirectory
}
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$extractDir = Join-Path $OutputDirectory "extract"

# 1. Extraction in a separate process with FILE-redirected streams.
# Note: calling the extract script with inherited streams (`& powershell ...`) deadlocks when this
# runner's own stdout is redirected to a pipe (e.g. under a background task) because the grandchild
# dotnet-gcdump inherits that pipe. File redirection decouples the streams and avoids the hang.
$extractLog = Join-Path $OutputDirectory "extract.log"
$extractErr = Join-Path $OutputDirectory "extract.err"
$extractArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $extractScript,
    "-InputPath", $InputPath, "-OutputDirectory", $extractDir)
if ($ToolPath) {
    $extractArgs += @("-ToolPath", $ToolPath)
}
$extractProc = Start-Process -FilePath "powershell" -ArgumentList $extractArgs -NoNewWindow -PassThru `
    -RedirectStandardOutput $extractLog -RedirectStandardError $extractErr
$null = $extractProc.Handle  # cache handle so ExitCode is populated after exit (Start-Process -PassThru quirk)
if (-not $extractProc.WaitForExit(180000)) {
    try { $extractProc.Kill() } catch {}
    throw "extract-gcdump-reports.ps1 timed out after 180s"
}
if ($extractProc.ExitCode -ne 0) {
    throw "extract-gcdump-reports.ps1 failed (exit $($extractProc.ExitCode)): $(Get-Content -Raw -LiteralPath $extractErr -ErrorAction SilentlyContinue)"
}

$llmInputPath = Join-Path $extractDir "LLM_MEMORY_INPUT.txt"
$manifestPath = Join-Path $extractDir "MANIFEST.txt"
if (-not (Test-Path -LiteralPath $llmInputPath)) { throw "LLM_MEMORY_INPUT.txt not produced" }
$llmInput = Get-Content -Raw -LiteralPath $llmInputPath
$snapshotCount = ([regex]::Matches((Get-Content -Raw -LiteralPath $manifestPath), '(?m)^\[(\d+)\]\s*$')).Count

# 2. Compose the model request.
$headings = (Get-DiagSessionAnalysisReportHeadings) -join [Environment]::NewLine
$request = @"
$modelPrompt

## Required Output Contract

Return a single Markdown report using EXACTLY these headings (verbatim, including the leading # / ##):

$headings

## User Context

- Snapshot order: $SnapshotOrder
- Repeated action: $RepeatedAction
- Repeat count: $RepeatCount
- Code start point: $StartPoint
- Related code/classes: $RelatedCode

## Standard Report Template

$template

## Evidence: LLM_MEMORY_INPUT.txt

$llmInput
"@
$requestPath = Join-Path $OutputDirectory "LLM_REQUEST.md"
$request | Set-Content -LiteralPath $requestPath -Encoding utf8

$responsePath = Join-Path $extractDir "ANALYSIS.md"
$legacyResponsePath = Join-Path $OutputDirectory "MODEL_RESPONSE.md"
$contractStatus = "skipped"
$elapsed = 0

if (-not $SkipModel) {
    # 3. Drive Ollama via file redirection (no pipe-buffer deadlock).
    $errPath = Join-Path $OutputDirectory "ollama.stderr.txt"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = Start-Process -FilePath "ollama" -ArgumentList @("run", $OllamaModel) -NoNewWindow -PassThru `
        -RedirectStandardInput $requestPath -RedirectStandardOutput $responsePath -RedirectStandardError $errPath
    if (-not $proc.WaitForExit($OllamaTimeoutSeconds * 1000)) {
        try { $proc.Kill() } catch {}
        throw "Ollama '$OllamaModel' timed out after $OllamaTimeoutSeconds s"
    }
    $sw.Stop()
    $elapsed = [int]$sw.Elapsed.TotalSeconds

    # 4. Validate the report contract.
    $validationPath = Join-Path $OutputDirectory "RESPONSE_VALIDATION.md"
    try {
        Test-DiagSessionAnalysisReport -ResponsePath $responsePath -ValidationReportPath $validationPath | Out-Null
        Copy-Item -LiteralPath $responsePath -Destination $legacyResponsePath -Force
        $contractStatus = "passed"
    }
    catch {
        $contractStatus = "failed"
    }
}

# 5. Run summary.
@(
    "# Skill Eval Loop Summary"
    ""
    "- Input: $InputPath"
    "- SnapshotCount: $snapshotCount"
    "- Model: $OllamaModel"
    "- ModelElapsedSeconds: $elapsed"
    "- ContractStatus: $contractStatus"
    ""
    "## Artifacts"
    "- Manifest: $manifestPath"
    "- LLM memory input: $llmInputPath"
    "- LLM request: $requestPath"
    "- Analysis (model output): $responsePath"
    "- Legacy model response alias: $legacyResponsePath"
) | Set-Content -LiteralPath (Join-Path $OutputDirectory "RUN_SUMMARY.md") -Encoding utf8

Write-Host "Eval loop done. SnapshotCount=$snapshotCount ContractStatus=$contractStatus ModelElapsed=${elapsed}s"
Write-Host "Analysis: $responsePath"
