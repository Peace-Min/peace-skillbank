param(
    [Parameter(Mandatory = $true)]
    [string]$ResponsePath,

    [string]$ValidationReportPath
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "diagsession-report-contract.ps1")

if (-not $ValidationReportPath) {
    $responseDirectory = Split-Path -Parent (Resolve-Path -LiteralPath $ResponsePath).Path
    $ValidationReportPath = Join-Path $responseDirectory "RESPONSE_VALIDATION.md"
}

Test-DiagSessionAnalysisReport -ResponsePath $ResponsePath -ValidationReportPath $ValidationReportPath | Out-Null
Write-Host "Response contract validation passed."
Write-Host "Validation report: $ValidationReportPath"

