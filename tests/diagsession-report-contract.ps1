$ErrorActionPreference = "Stop"

function Get-DiagSessionAnalysisReportHeadings {
    return @(
        "# DiagSession Memory Analysis Report",
        "## 1. Assumptions and Snapshot Order",
        "## 2. Snapshot Mapping",
        "## 3. Leak Candidates by Confidence",
        "## 4. Evidence Table",
        "## 5. Code Areas to Inspect First",
        "## 6. Confirmation and Falsification Steps",
        "## 7. Evidence Limitations",
        "## 8. Follow-up Fix Session Handoff"
    )
}

function Test-DiagSessionAnalysisReport {
    param(
        [Parameter(Mandatory = $true)][string]$ResponsePath,
        [string]$ValidationReportPath
    )

    if (-not (Test-Path -LiteralPath $ResponsePath -PathType Leaf)) {
        throw "Response file not found: $ResponsePath"
    }

    $responsePathResolved = (Resolve-Path -LiteralPath $ResponsePath).Path
    $content = Get-Content -Raw -LiteralPath $responsePathResolved
    if ([string]::IsNullOrWhiteSpace($content)) {
        throw "Response file is empty: $responsePathResolved"
    }

    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($heading in (Get-DiagSessionAnalysisReportHeadings)) {
        if (-not $content.Contains($heading)) {
            $missing.Add($heading)
        }
    }

    $status = if ($missing.Count -eq 0) { "passed" } else { "failed" }
    $lines = @(
        "# DiagSession Analysis Response Validation"
        ""
        "- Response: $responsePathResolved"
        "- Status: $status"
        "- RequiredHeadingCount: $((Get-DiagSessionAnalysisReportHeadings).Count)"
        "- MissingHeadingCount: $($missing.Count)"
        ""
        "## Missing Headings"
        ""
    )

    if ($missing.Count -eq 0) {
        $lines += "- none"
    }
    else {
        foreach ($item in $missing) {
            $lines += "- $item"
        }
    }

    if ($ValidationReportPath) {
        $validationDirectory = Split-Path -Parent $ValidationReportPath
        if ($validationDirectory) {
            New-Item -ItemType Directory -Force -Path $validationDirectory | Out-Null
        }
        $lines | Out-File -FilePath $ValidationReportPath -Encoding utf8
    }

    if ($missing.Count -gt 0) {
        throw "Response does not match the required DiagSession report contract. Missing: $($missing -join ', ')"
    }

    return $true
}

