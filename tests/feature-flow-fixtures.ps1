<#
.SYNOPSIS
    Behavioural fixtures for skills/feature-flow/scripts/ff.ps1 (positive + negative paths).
    Builds a throwaway project in %TEMP%, drives init/event/check-todo/status, asserts exit codes
    and output. ASCII-only (Windows PowerShell 5.1).
#>
param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"
$ff = Join-Path $RepositoryRoot "skills\feature-flow\scripts\ff.ps1"
$failures = 0

function Invoke-Ff {
    param([string]$ProjectRoot, [string[]]$Arguments)
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $ff @Arguments -Root $ProjectRoot 2>&1 | Out-String
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

function Check {
    param([string]$Name, [bool]$Condition, [string]$Detail = "")
    if ($Condition) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name  $Detail"; $script:failures++ }
}

$project = Join-Path ([System.IO.Path]::GetTempPath()) ("ff-fixture-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Path (Join-Path $project "src") -Force | Out-Null
$code = @("namespace Demo", "{", "    public class Lockout", "    {", "        public int Max = 5;", "    }", "}")
Set-Content -LiteralPath (Join-Path $project "src\Lockout.cs") -Value $code -Encoding ASCII

try {
    Write-Host "feature-flow fixtures ($project)"

    # 1. init: creates the layout and prints the folder.
    $r = Invoke-Ff $project @("init", "-Title", "Account lockout after 5 failures")
    $work = $r.Out.Trim()
    Check "init exit 0" ($r.Code -eq 0) $r.Out
    Check "init layout" ((Test-Path (Join-Path $work "01-spec.md")) -and (Test-Path (Join-Path $work "evidence\dev")) -and (Test-Path (Join-Path $work "reviews"))) $work
    Check "init slug" ($work -match 'account-lockout-after-5-failures$') $work

    # 2. init negative: missing title is a usage error.
    $r = Invoke-Ff $project @("init")
    Check "init without title -> exit 2" ($r.Code -eq 2) $r.Out

    # 3. check-todo positive: every checked item has resolvable refs.
    Set-Content -LiteralPath (Join-Path $work "evidence\dev\verify-r1.log") -Value "Build succeeded." -Encoding ASCII
    $todoOk = @(
        "# TODO", "", "## Dev",
        "- [x] D1: Add Lockout class",
        "  - evidence: src/Lockout.cs:3-6 | evidence/dev/verify-r1.log",
        "- [x] D2: Max attempts constant",
        "  - evidence: src/Lockout.cs:5 built fine",
        "", "## QA",
        "- [ ] Q1: Sixth attempt is rejected",
        "  - evidence:"
    )
    Set-Content -LiteralPath (Join-Path $work "02-todo.md") -Value $todoOk -Encoding UTF8
    $r = Invoke-Ff $project @("check-todo", "-WorkDir", $work, "-Prefix", "D")
    Check "check-todo D all valid -> exit 0" ($r.Code -eq 0) $r.Out
    Check "check-todo reports OK lines" (([regex]::Matches($r.Out, '(?m)^OK\s')).Count -eq 2) $r.Out

    # 4. check-todo negative: open item, missing evidence, bad line, missing file, no ref.
    $todoBad = @(
        "## Dev",
        "- [ ] D1: Not done yet",
        "  - evidence:",
        "- [x] D2: Checked but no evidence",
        "  - evidence:",
        "- [x] D3: Line beyond file end",
        "  - evidence: src/Lockout.cs:999",
        "- [x] D4: File does not exist",
        "  - evidence: src/Ghost.cs:1",
        "- [x] D5: Prose only",
        "  - evidence: trust me it works"
    )
    Set-Content -LiteralPath (Join-Path $work "02-todo.md") -Value $todoBad -Encoding UTF8
    $r = Invoke-Ff $project @("check-todo", "-WorkDir", $work, "-Prefix", "D")
    Check "check-todo bad -> exit 1" ($r.Code -eq 1) $r.Out
    Check "detects OPEN" ($r.Out -match '(?m)^OPEN\s+D1') $r.Out
    Check "detects NO-EVID" ($r.Out -match '(?m)^NO-EVID\s+D2') $r.Out
    Check "detects line beyond end" ($r.Out -match '(?m)^BAD-REF\s+D3.*beyond end') $r.Out
    Check "detects missing file" ($r.Out -match '(?m)^BAD-REF\s+D4.*missing file') $r.Out
    Check "detects prose-only evidence" ($r.Out -match '(?m)^NO-REF\s+D5') $r.Out
    Check "summary counts 5 problems" ($r.Out -match 'SUMMARY\s+5 item\(s\), 5 problem\(s\)') $r.Out

    # 5. check-todo negative: prefix with no items is a usage error.
    $r = Invoke-Ff $project @("check-todo", "-WorkDir", $work, "-Prefix", "Q")
    Check "no Q items -> exit 2" ($r.Code -eq 2) $r.Out

    # 6. event + loop limit: third FAIL after START trips exit 3; PASS/START reset the counter.
    $r = Invoke-Ff $project @("event", "-WorkDir", $work, "-Stage", "dev", "-Status", "START")
    Check "event START exit 0" ($r.Code -eq 0) $r.Out
    $r = Invoke-Ff $project @("event", "-WorkDir", $work, "-Stage", "dev", "-Status", "FAIL", "-Round", "1", "-Note", "gate | D3`nbad")
    Check "FAIL 1 exit 0" ($r.Code -eq 0) $r.Out
    Check "note sanitized (no pipe/newline)" ($r.Out -match 'r1 \| gate D3 bad') $r.Out
    $r = Invoke-Ff $project @("event", "-WorkDir", $work, "-Stage", "dev", "-Status", "FAIL", "-Round", "2")
    Check "FAIL 2 exit 0" ($r.Code -eq 0) $r.Out
    $r = Invoke-Ff $project @("event", "-WorkDir", $work, "-Stage", "dev", "-Status", "FAIL", "-Round", "3")
    Check "FAIL 3 -> LOOP_LIMIT exit 3" (($r.Code -eq 3) -and ($r.Out -match 'LOOP_LIMIT')) $r.Out
    $r = Invoke-Ff $project @("event", "-WorkDir", $work, "-Stage", "dev", "-Status", "RESUME")
    $r = Invoke-Ff $project @("event", "-WorkDir", $work, "-Stage", "dev", "-Status", "FAIL", "-Round", "4", "-MaxRounds", "2")
    Check "RESUME resets counter" ($r.Code -eq 0) $r.Out

    # 7. event negative: unknown stage/status.
    $r = Invoke-Ff $project @("event", "-WorkDir", $work, "-Stage", "deploy", "-Status", "PASS")
    Check "bad stage -> exit 2" ($r.Code -eq 2) $r.Out
    $r = Invoke-Ff $project @("event", "-WorkDir", $work, "-Stage", "dev", "-Status", "OK")
    Check "bad status -> exit 2" ($r.Code -eq 2) $r.Out

    # 8. status: reports stage, fail count and TODO progress for resume.
    $r = Invoke-Ff $project @("status", "-WorkDir", $work)
    Check "status exit 0" ($r.Code -eq 0) $r.Out
    Check "status stage line" ($r.Out -match 'STAGE\s+dev\s+last=FAIL r4') $r.Out
    Check "status todo progress" ($r.Out -match 'TODO-D\s+4/5 checked') $r.Out

    # 9. status negative: missing work folder.
    $r = Invoke-Ff $project @("status", "-WorkDir", "work\nope")
    Check "missing work dir -> exit 2" ($r.Code -eq 2) $r.Out
}
finally {
    Remove-Item -LiteralPath $project -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures -gt 0) { throw "feature-flow fixtures: $failures failure(s)" }
Write-Host "feature-flow fixtures passed."
