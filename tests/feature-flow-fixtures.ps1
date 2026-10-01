<#
.SYNOPSIS
    Behavioural fixtures for skills/feature-flow/scripts/ff.ps1 (positive + negative paths).
    Builds throwaway projects in %TEMP%, drives every command, asserts exit codes and output.
    ASCII-only (Windows PowerShell 5.1).
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

function Get-WorkDirLine([string]$Text) {
    $m = [regex]::Match($Text, '(?m)^WORKDIR\s+(.+?)\s*$')
    if ($m.Success) { return $m.Groups[1].Value }
    return ""
}

# Korean sample text built from code points so this file stays ASCII.
$ko = -join ([char[]]@(0xD55C, 0xAE00, 0x20, 0xB0B4, 0xC6A9))

$project = Join-Path ([System.IO.Path]::GetTempPath()) ("ff-fixture-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Path (Join-Path $project "src") -Force | Out-Null
# 10 physical lines, 3 of them blank: line counting must include blank lines.
$code = @("namespace Demo", "", "{", "    public class Lockout", "    {", "", "        public int Max = 5;", "", "    }", "}")
Set-Content -LiteralPath (Join-Path $project "src\Lockout.cs") -Value $code -Encoding ASCII

try {
    Write-Host "feature-flow fixtures ($project)"

    # 1. init on a non-git folder: creates the layout, warns, prints the folder last.
    $r = Invoke-Ff $project @("init", "-Title", "Account lockout after 5 failures")
    $work = Get-WorkDirLine $r.Out
    Check "init exit 0" ($r.Code -eq 0) $r.Out
    Check "init layout" ((Test-Path (Join-Path $work "01-spec.md")) -and (Test-Path (Join-Path $work "evidence\qa")) -and (Test-Path (Join-Path $work "reviews"))) $work
    Check "init slug" ($work -match 'account-lockout-after-5-failures$') $work
    Check "init warns: not a git repository" ($r.Out -match 'WARN: not a git repository') $r.Out
    Check "init records base none" (([System.IO.File]::ReadAllText((Join-Path $work "base.txt"))) -eq "none") ""

    # 2. init negative: missing title is a usage error.
    $r = Invoke-Ff $project @("init")
    Check "init without title -> exit 2" ($r.Code -eq 2) $r.Out

    # 3. check-todo positive: refs resolve, blank lines counted, prose with dots ignored.
    Set-Content -LiteralPath (Join-Path $work "evidence\dev\verify-r1.log") -Value "Build succeeded." -Encoding ASCII
    $todoOk = @(
        "# TODO", "", "## Dev",
        "- [x] D1: Add Lockout class",
        "  - evidence: src/Lockout.cs:4-10 | evidence/dev/verify-r1.log",
        "- [x] D2: Max attempts constant",
        "  - evidence: src/Lockout.cs:7 built fine with v1.2 of Notes.md tooling",
        "", "## QA",
        "- [ ] Q1: Sixth attempt is rejected",
        "  - evidence:"
    )
    Set-Content -LiteralPath (Join-Path $work "02-todo.md") -Value $todoOk -Encoding UTF8
    $r = Invoke-Ff $project @("check-todo", "-WorkDir", $work, "-Prefix", "D")
    Check "check-todo D all valid -> exit 0" ($r.Code -eq 0) $r.Out
    Check "check-todo reports OK lines" (([regex]::Matches($r.Out, '(?m)^OK\s')).Count -eq 2) $r.Out
    Check "blank lines counted (line 10 of 10 accepted)" ($r.Out -notmatch 'beyond end') $r.Out
    Set-Content -LiteralPath (Join-Path $work "02-todo.md") -Value @("## Dev", "- [x] D1: punctuation around refs", "  - evidence: see (src/Lockout.cs:7). also [src/Lockout.cs:1-3],") -Encoding UTF8
    $r = Invoke-Ff $project @("check-todo", "-WorkDir", $work, "-Prefix", "D")
    Check "refs wrapped in ( ) [ ] or followed by . , are accepted" (($r.Code -eq 0) -and ($r.Out -match '(?m)^OK\s+D1')) $r.Out
    Set-Content -LiteralPath (Join-Path $work "02-todo.md") -Value $todoOk -Encoding UTF8

    # 4. -FormatOnly (plan gate).
    $r = Invoke-Ff $project @("check-todo", "-WorkDir", $work, "-FormatOnly")
    Check "format: valid plan -> exit 0" ($r.Code -eq 0) $r.Out
    Set-Content -LiteralPath (Join-Path $work "02-todo.md") -Value @("## Dev", "- [ ] D1: a", "  - evidence:", "- [ ] D1: dup", "  - evidence:", "## QA", "- [ ] Q1: b") -Encoding UTF8
    $r = Invoke-Ff $project @("check-todo", "-WorkDir", $work, "-FormatOnly")
    Check "format: duplicate id + missing evidence line -> exit 1" (($r.Code -eq 1) -and ($r.Out -match 'duplicate id D1') -and ($r.Out -match 'Q1 has no')) $r.Out
    Set-Content -LiteralPath (Join-Path $work "02-todo.md") -Value @("## Dev", "- [ ] D1: a", "  - evidence:") -Encoding UTF8
    $r = Invoke-Ff $project @("check-todo", "-WorkDir", $work, "-FormatOnly")
    Check "format: no Q items -> exit 1" (($r.Code -eq 1) -and ($r.Out -match 'no Q items')) $r.Out

    # 5. -AllowOpen (qa gate): open Q without proof fails; with a proof file it passes as OPEN-OK.
    Set-Content -LiteralPath (Join-Path $work "02-todo.md") -Value $todoOk -Encoding UTF8
    $r = Invoke-Ff $project @("check-todo", "-WorkDir", $work, "-Prefix", "Q", "-AllowOpen")
    Check "qa gate: open without proof -> exit 1" (($r.Code -eq 1) -and ($r.Out -match '(?m)^OPEN\s+Q1')) $r.Out
    Set-Content -LiteralPath (Join-Path $work "evidence\qa\Q1-sixth-attempt.log") -Value "expected reject, got accept" -Encoding ASCII
    $r = Invoke-Ff $project @("check-todo", "-WorkDir", $work, "-Prefix", "Q", "-AllowOpen")
    Check "qa gate: open with proof -> exit 0 OPEN-OK" (($r.Code -eq 0) -and ($r.Out -match '(?m)^OPEN-OK\s+Q1')) $r.Out
    $r = Invoke-Ff $project @("check-todo", "-WorkDir", $work, "-Prefix", "Q")
    Check "dev-style gate still rejects open item" ($r.Code -eq 1) $r.Out

    # 6. check-todo negative paths.
    $todoBad = @(
        "## Dev",
        "- [ ] D1: Not done yet",
        "  - evidence:",
        "- [x] D2: Checked, evidence line empty",
        "  - evidence:",
        "- [x] D3: Line beyond file end",
        "  - evidence: src/Lockout.cs:999",
        "- [x] D4: File does not exist",
        "  - evidence: src/Ghost.cs:1",
        "- [x] D5: Prose only",
        "  - evidence: trust me it works, see Notes.md v2.0",
        "- [x] D6: Line just past the end",
        "  - evidence: src/Lockout.cs:11",
        "- [x] D7: No evidence line at all"
    )
    Set-Content -LiteralPath (Join-Path $work "02-todo.md") -Value $todoBad -Encoding UTF8
    $r = Invoke-Ff $project @("check-todo", "-WorkDir", $work, "-Prefix", "D")
    Check "check-todo bad -> exit 1" ($r.Code -eq 1) $r.Out
    Check "detects OPEN" ($r.Out -match '(?m)^OPEN\s+D1') $r.Out
    Check "detects empty evidence line" ($r.Out -match '(?m)^NO-EVID\s+D2.*line is empty') $r.Out
    Check "detects line beyond end" ($r.Out -match '(?m)^BAD-REF\s+D3.*beyond end') $r.Out
    Check "detects missing file" ($r.Out -match '(?m)^BAD-REF\s+D4.*missing file') $r.Out
    Check "detects prose-only evidence" ($r.Out -match '(?m)^NO-REF\s+D5') $r.Out
    Check "detects line 11 of 10" ($r.Out -match '(?m)^BAD-REF\s+D6.*\(10 lines\)') $r.Out
    Check "detects missing evidence line" ($r.Out -match '(?m)^NO-EVID\s+D7.*without') $r.Out
    Check "summary counts 7 problems" ($r.Out -match 'SUMMARY\s+7 item\(s\), 7 problem\(s\)') $r.Out
    $r = Invoke-Ff $project @("check-todo", "-WorkDir", $work, "-Prefix", "Q")
    Check "no Q items -> exit 2" ($r.Code -eq 2) $r.Out

    # 7. event + loop limit: third FAIL after START trips exit 3; RESUME resets the counter.
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
    $r = Invoke-Ff $project @("event", "-WorkDir", $work, "-Stage", "dev", "-Status", "FAIL", "-Round", "5", "-MaxRounds", "2")
    Check "-MaxRounds 2 trips on second FAIL" ($r.Code -eq 3) $r.Out

    $r = Invoke-Ff $project @("status", "-WorkDir", $work, "-MaxRounds", "2")
    Check "status NEXT after loop limit is escalated" ($r.Out -match 'NEXT\s+escalated \(loop limit\)') $r.Out

    # 8. QA send-backs: counted across stages and START resets; third trips with -MaxQaCycles 2;
    #    they do not inflate the qa round-fail counter; RESUME (user go-ahead) resets them.
    $r = Invoke-Ff $project @("event", "-WorkDir", $work, "-Stage", "qa", "-Status", "START")
    $r = Invoke-Ff $project @("event", "-WorkDir", $work, "-Stage", "qa", "-Status", "FAIL", "-Round", "1", "-Note", "sendback=IMPL median wrong")
    Check "sendback 1 exit 0" ($r.Code -eq 0) $r.Out
    $r = Invoke-Ff $project @("status", "-WorkDir", $work)
    Check "status NEXT after IMPL send-back is dev START" ($r.Out -match 'NEXT\s+dev START \(QA send-back') $r.Out
    $r = Invoke-Ff $project @("event", "-WorkDir", $work, "-Stage", "qa", "-Status", "START")
    $r = Invoke-Ff $project @("event", "-WorkDir", $work, "-Stage", "qa", "-Status", "FAIL", "-Round", "2", "-Note", "sendback=SPEC")
    Check "sendback 2 exit 0" ($r.Code -eq 0) $r.Out
    $r = Invoke-Ff $project @("status", "-WorkDir", $work)
    Check "status NEXT after SPEC send-back is plan START" ($r.Out -match 'NEXT\s+plan START') $r.Out
    $r = Invoke-Ff $project @("event", "-WorkDir", $work, "-Stage", "qa", "-Status", "START")
    $r = Invoke-Ff $project @("event", "-WorkDir", $work, "-Stage", "qa", "-Status", "FAIL", "-Round", "3", "-Note", "gate: Q2 no proof", "-MaxRounds", "2")
    Check "send-backs do not count as qa round FAILs" ($r.Code -eq 0) $r.Out
    $r = Invoke-Ff $project @("event", "-WorkDir", $work, "-Stage", "qa", "-Status", "FAIL", "-Round", "4", "-Note", "sendback=IMPL")
    Check "sendback 3 -> LOOP_LIMIT exit 3" (($r.Code -eq 3) -and ($r.Out -match 'sent work back 3')) $r.Out
    $r = Invoke-Ff $project @("status", "-WorkDir", $work)
    Check "status NEXT after send-back limit is escalated" ($r.Out -match 'NEXT\s+escalated \(QA send-back limit\)') $r.Out
    $r = Invoke-Ff $project @("event", "-WorkDir", $work, "-Stage", "qa", "-Status", "RESUME")
    $r = Invoke-Ff $project @("event", "-WorkDir", $work, "-Stage", "qa", "-Status", "FAIL", "-Round", "5", "-Note", "sendback=IMPL")
    Check "RESUME resets send-back count" ($r.Code -eq 0) $r.Out

    # 9. event negative: unknown stage/status.
    $r = Invoke-Ff $project @("event", "-WorkDir", $work, "-Stage", "deploy", "-Status", "PASS")
    Check "bad stage -> exit 2" ($r.Code -eq 2) $r.Out
    $r = Invoke-Ff $project @("event", "-WorkDir", $work, "-Stage", "dev", "-Status", "OK")
    Check "bad status -> exit 2" ($r.Code -eq 2) $r.Out

    # 10. status: stage, counts, TODO progress and the next action.
    $r = Invoke-Ff $project @("event", "-WorkDir", $work, "-Stage", "dev", "-Status", "START")
    $r = Invoke-Ff $project @("event", "-WorkDir", $work, "-Stage", "dev", "-Status", "FAIL", "-Round", "1")
    $r = Invoke-Ff $project @("status", "-WorkDir", $work)
    Check "status exit 0" ($r.Code -eq 0) $r.Out
    Check "status stage line" ($r.Out -match 'STAGE\s+dev\s+last=FAIL r1') $r.Out
    Check "status todo progress" ($r.Out -match 'TODO-D\s+6/7 checked') $r.Out
    Check "status sendbacks since RESUME" ($r.Out -match 'SENDBACKS 1') $r.Out
    Check "round numbers continue (dev had r1..r5, then r1 again -> next r6)" ($r.Out -match 'NEXT\s+dev round 6') $r.Out
    $r = Invoke-Ff $project @("event", "-WorkDir", $work, "-Stage", "dev", "-Status", "PASS", "-Round", "2")
    $r = Invoke-Ff $project @("status", "-WorkDir", $work)
    Check "status next after PASS" ($r.Out -match 'NEXT\s+qa START') $r.Out
    $r = Invoke-Ff $project @("status", "-WorkDir", "work\nope")
    Check "missing work dir -> exit 2" ($r.Code -eq 2) $r.Out

    # 11. diff: non-git base fails; git project captures tracked + untracked, excludes work/.
    $r = Invoke-Ff $project @("diff", "-WorkDir", $work, "-Round", "1")
    Check "diff without git base -> exit 2" ($r.Code -eq 2) $r.Out
    $gp = Join-Path $project "gitproj"
    New-Item -ItemType Directory -Path (Join-Path $gp "src") -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $gp "src\a.txt") -Value "one" -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $gp ".gitignore") -Value "work/" -Encoding ASCII
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    & git -C $gp init -q 2>&1 | Out-Null
    & git -C $gp add . 2>&1 | Out-Null
    & git -C $gp -c user.name=t -c user.email=t@t commit -q -m init 2>&1 | Out-Null
    $ErrorActionPreference = $prevEap
    $r = Invoke-Ff $gp @("init", "-Title", "diff test")
    $gw = Get-WorkDirLine $r.Out
    Check "init on clean ignored git repo: no warnings" (($r.Code -eq 0) -and ($r.Out -notmatch 'WARN')) $r.Out
    Check "init records commit base" (([System.IO.File]::ReadAllText((Join-Path $gw "base.txt"))) -match '^[0-9a-f]{40}$') ""
    Add-Content -LiteralPath (Join-Path $gp "src\a.txt") -Value "two" -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $gp "src\b.txt") -Value "new file" -Encoding ASCII
    $r = Invoke-Ff $gp @("diff", "-WorkDir", $gw, "-Round", "1")
    $patchPath = Join-Path $gw "evidence\dev\diff-r1.patch"
    $patch = if (Test-Path -LiteralPath $patchPath) { [System.IO.File]::ReadAllText($patchPath) } else { "" }
    Check "diff exit 0" ($r.Code -eq 0) $r.Out
    Check "diff has tracked change" ($patch -match '(?m)^\+two') $patch
    Check "diff has untracked file" (($patch -match 'b\.txt') -and ($patch -match '(?m)^\+new file')) $patch
    Check "diff excludes work/" ($patch -notmatch 'events\.log|01-spec') $patch

    # 11b. Non-ASCII: Korean content in a tracked file and an untracked file with a Korean name.
    $koFile = Join-Path $gp ("src\" + $ko.Replace(" ", "") + ".txt")
    [System.IO.File]::WriteAllText($koFile, "new $ko`n", (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::AppendAllText((Join-Path $gp "src\a.txt"), "$ko`n", (New-Object System.Text.UTF8Encoding($false)))
    $r = Invoke-Ff $gp @("diff", "-WorkDir", $gw, "-Round", "2")
    $patch2 = [System.IO.File]::ReadAllText((Join-Path $gw "evidence\dev\diff-r2.patch"), [System.Text.Encoding]::UTF8)
    Check "diff reports 2 untracked files" ($r.Out -match '2 untracked') $r.Out
    Check "diff keeps Korean content (tracked)" ($patch2.Contains("+$ko")) ""
    Check "diff includes Korean-named untracked file" ($patch2.Contains($ko.Replace(" ", "") + ".txt") -and $patch2.Contains("+new $ko")) ""
    $r = Invoke-Ff $gp @("diff", "-WorkDir", $gw)
    Check "diff without -Round -> exit 2" ($r.Code -eq 2) $r.Out

    # 12. wiki-check: missing index fails; broken link fails; resolved links (with anchors) pass.
    $r = Invoke-Ff $gp @("wiki-check")
    Check "wiki-check no index -> exit 1" ($r.Code -eq 1) $r.Out
    New-Item -ItemType Directory -Path (Join-Path $gp "docs\wiki\modules") -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $gp "docs\wiki\index.md") -Value @("- [Arch](architecture.md)", "- [Calc](modules/calc.md#median)", "- [Gone](missing.md)", "- [Web](https://example.com/x.md)") -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $gp "docs\wiki\architecture.md") -Value "# Arch" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $gp "docs\wiki\modules\calc.md") -Value "[up](../index.md)" -Encoding UTF8
    $r = Invoke-Ff $gp @("wiki-check")
    Check "wiki-check broken link -> exit 1" (($r.Code -eq 1) -and ($r.Out -match 'BROKEN.*missing\.md') -and ($r.Out -match '1 broken')) $r.Out
    Set-Content -LiteralPath (Join-Path $gp "docs\wiki\index.md") -Value @("- [Arch](architecture.md)", "- [Calc](modules/calc.md#median)") -Encoding UTF8
    $r = Invoke-Ff $gp @("wiki-check")
    Check "wiki-check all links resolve -> exit 0" ($r.Code -eq 0) $r.Out

    # 12b. Link forms: ./x, <x>, "title", %20, leading /, reference definitions; code fences ignored.
    Set-Content -LiteralPath (Join-Path $gp "docs\wiki\my page.md") -Value "# p" -Encoding UTF8
    $forms = @(
        "- [a](./architecture.md)", "- [b](<modules/calc.md>)", "- [c](architecture.md `"Arch title`")",
        "- [d](my%20page.md)", "- [e](/docs/wiki/architecture.md)", "[ref]: modules/calc.md",
        '```', "[fenced](not-real.md)", '```'
    )
    Set-Content -LiteralPath (Join-Path $gp "docs\wiki\index.md") -Value $forms -Encoding UTF8
    $r = Invoke-Ff $gp @("wiki-check")
    Check "wiki-check accepts all valid link forms, ignores fenced code" ($r.Code -eq 0) $r.Out
    Set-Content -LiteralPath (Join-Path $gp "docs\wiki\index.md") -Value @("- [t](gone.md `"title`")", "[r]: also-gone.md") -Encoding UTF8
    $r = Invoke-Ff $gp @("wiki-check")
    Check "wiki-check catches broken titled and reference links" (($r.Code -eq 1) -and ($r.Out -match '2 broken')) $r.Out
}
finally {
    Remove-Item -LiteralPath $project -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures -gt 0) { throw "feature-flow fixtures: $failures failure(s)" }
Write-Host "feature-flow fixtures passed."
