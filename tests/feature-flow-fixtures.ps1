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

    # 3b. "evidence/..." refs resolve only inside the work folder; a copy in the project root does not count.
    New-Item -ItemType Directory -Path (Join-Path $project "evidence\qa") -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $project "evidence\qa\Q1-root.log") -Value "misplaced" -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $work "02-todo.md") -Value @("## QA", "- [x] Q1: misplaced proof", "  - evidence: evidence/qa/Q1-root.log") -Encoding UTF8
    $r = Invoke-Ff $project @("check-todo", "-WorkDir", $work, "-Prefix", "Q")
    Check "evidence/ in project root is not accepted" (($r.Code -eq 1) -and ($r.Out -match 'BAD-REF\s+Q1.*missing file')) $r.Out
    Remove-Item -LiteralPath (Join-Path $project "evidence") -Recurse -Force
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
    $r = Invoke-Ff $project @("event", "-WorkDir", $work, "-Stage", "dev", "-Status", "FAIL", "-Round", "1", "-Note", "review | D3`nbad")
    Check "FAIL 1 exit 0" ($r.Code -eq 0) $r.Out
    Check "note sanitized (no pipe/newline)" ($r.Out -match 'r1 \| review D3 bad') $r.Out
    $r = Invoke-Ff $project @("event", "-WorkDir", $work, "-Stage", "dev", "-Status", "FAIL", "-Round", "2")
    Check "FAIL 2 exit 0" ($r.Code -eq 0) $r.Out
    $r = Invoke-Ff $project @("event", "-WorkDir", $work, "-Stage", "dev", "-Status", "FAIL", "-Round", "3")
    Check "FAIL 3 -> LOOP_LIMIT exit 3" (($r.Code -eq 3) -and ($r.Out -match 'LOOP_LIMIT')) $r.Out
    $r = Invoke-Ff $project @("event", "-WorkDir", $work, "-Stage", "dev", "-Status", "RESUME", "-Note", "user")
    $r = Invoke-Ff $project @("event", "-WorkDir", $work, "-Stage", "dev", "-Status", "FAIL", "-Round", "4", "-MaxRounds", "2")
    Check "RESUME resets counter" ($r.Code -eq 0) $r.Out
    $r = Invoke-Ff $project @("event", "-WorkDir", $work, "-Stage", "dev", "-Status", "FAIL", "-Round", "5", "-MaxRounds", "2")
    Check "-MaxRounds 2 trips on second FAIL" ($r.Code -eq 3) $r.Out

    $r = Invoke-Ff $project @("status", "-WorkDir", $work, "-MaxRounds", "2")
    Check "status NEXT after loop limit is escalated" ($r.Out -match 'NEXT\s+escalated \(loop limit') $r.Out

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
    $r = Invoke-Ff $project @("event", "-WorkDir", $work, "-Stage", "qa", "-Status", "RESUME", "-Note", "user fixed env")
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
    Set-Content -LiteralPath (Join-Path $work "reviews\dev-r2.md") -Value @("VERDICT: PASS", "ISSUES:", "- none", "DECISIONS: none") -Encoding UTF8
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

    # 11c. Line-ending rewrite of a tracked file fails the dev diff gate; a real one-line change does not.
    $gp2 = Join-Path $project "gitproj2"
    New-Item -ItemType Directory -Path $gp2 -Force | Out-Null
    $lf = (1..10 | ForEach-Object { "line $_" }) -join "`n"
    [System.IO.File]::WriteAllText((Join-Path $gp2 "eol.txt"), $lf + "`n")
    Set-Content -LiteralPath (Join-Path $gp2 ".gitignore") -Value "work/" -Encoding ASCII
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    & git -C $gp2 init -q 2>&1 | Out-Null
    & git -C $gp2 config core.autocrlf false 2>&1 | Out-Null
    & git -C $gp2 add . 2>&1 | Out-Null
    & git -C $gp2 -c user.name=t -c user.email=t@t commit -q -m init 2>&1 | Out-Null
    $ErrorActionPreference = $prevEap
    $gw2 = Get-WorkDirLine (Invoke-Ff $gp2 @("init", "-Title", "eol test")).Out
    [System.IO.File]::WriteAllText((Join-Path $gp2 "eol.txt"), ($lf -replace "`n", "`r`n") + "`r`n")
    $r = Invoke-Ff $gp2 @("diff", "-WorkDir", $gw2, "-Round", "1")
    Check "CRLF rewrite -> diff gate exit 1 with EOL line" (($r.Code -eq 1) -and ($r.Out -match '(?m)^EOL\s+eol\.txt')) $r.Out
    [System.IO.File]::WriteAllText((Join-Path $gp2 "eol.txt"), ($lf -replace 'line 5', 'line five') + "`n")
    $r = Invoke-Ff $gp2 @("diff", "-WorkDir", $gw2, "-Round", "2")
    Check "real one-line change keeps the diff gate green" (($r.Code -eq 0) -and ($r.Out -notmatch '(?m)^EOL\s')) $r.Out

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

    # 13. pick-model: base by role/risk/size, escalation on failures and send-back, MaxModel cap.
    $r = Invoke-Ff $project @("init", "-Title", "model pick")
    $mw = Get-WorkDirLine $r.Out
    Check "init spec has Risk section" (([System.IO.File]::ReadAllText((Join-Path $mw "01-spec.md"))) -match '## Risk') ""
    $pick = {
        param([string[]]$Extra)
        $res = Invoke-Ff $project (@("pick-model", "-WorkDir", $mw) + $Extra)
        $m = [regex]::Match($res.Out, '(?m)^MODEL\s+(\S+)')
        if ($m.Success) { return $m.Groups[1].Value }
        return "ERR(" + $res.Code + "): " + $res.Out
    }
    Check "planner normal -> opus" ((& $pick @("-Role", "planner")) -eq "opus") ""
    Check "developer without todo -> opus" ((& $pick @("-Role", "developer")) -eq "opus") ""
    Set-Content -LiteralPath (Join-Path $mw "02-todo.md") -Value @("## Dev", "- [ ] D1: a", "  - evidence:", "- [ ] D2: b", "  - evidence:", "## QA", "- [ ] Q1: c", "  - evidence:") -Encoding UTF8
    Check "developer small (2 D) -> sonnet" ((& $pick @("-Role", "developer")) -eq "sonnet") ""
    Check "qa normal -> sonnet" ((& $pick @("-Role", "qa")) -eq "sonnet") ""
    Check "wiki -> sonnet" ((& $pick @("-Role", "wiki")) -eq "sonnet") ""
    Check "reviewer is one tier above the worker (dev sonnet -> opus)" ((& $pick @("-Role", "reviewer", "-Stage", "dev")) -eq "opus") ""
    $r = Invoke-Ff $project @("pick-model", "-WorkDir", $mw, "-Role", "reviewer")
    Check "reviewer without -Stage -> exit 2" ($r.Code -eq 2) $r.Out
    $r = Invoke-Ff $project @("pick-model", "-WorkDir", $mw)
    Check "pick-model without -Role -> exit 2" ($r.Code -eq 2) $r.Out
    $specText = [System.IO.File]::ReadAllText((Join-Path $mw "01-spec.md")) -replace 'level: normal', 'level: high'
    [System.IO.File]::WriteAllText((Join-Path $mw "01-spec.md"), $specText)
    Check "planner high risk -> fable" ((& $pick @("-Role", "planner")) -eq "fable") ""
    Check "developer high risk -> opus" ((& $pick @("-Role", "developer")) -eq "opus") ""
    Check "high risk qa worker opus -> reviewer fable" ((& $pick @("-Role", "reviewer", "-Stage", "qa")) -eq "fable") ""
    Check "planner high risk capped by -MaxModel opus" ((& $pick @("-Role", "planner", "-MaxModel", "opus")) -eq "opus") ""
    [System.IO.File]::WriteAllText((Join-Path $mw "01-spec.md"), ($specText -replace 'level: high', 'level: normal'))
    $null = Invoke-Ff $project @("event", "-WorkDir", $mw, "-Stage", "dev", "-Status", "START")
    $null = Invoke-Ff $project @("event", "-WorkDir", $mw, "-Stage", "dev", "-Status", "FAIL", "-Round", "1")
    Check "developer after 1 FAIL stays sonnet" ((& $pick @("-Role", "developer")) -eq "sonnet") ""
    $r = Invoke-Ff $project @("event", "-WorkDir", $mw, "-Stage", "dev", "-Status", "FAIL", "-Round", "2", "-Model", "sonnet")
    Check "event -Model appends [model=...]" ($r.Out -match 'r2 \|\s+\[model=sonnet\]|r2 \| \[model=sonnet\]') $r.Out
    Check "developer after 2 FAILs -> opus" ((& $pick @("-Role", "developer")) -eq "opus") ""
    Check "dev worker escalated to opus -> reviewer fable" ((& $pick @("-Role", "reviewer", "-Stage", "dev")) -eq "fable") ""
    Set-Content -LiteralPath (Join-Path $mw "reviews\dev-r3.md") -Value @("VERDICT: PASS", "ISSUES:", "- none", "DECISIONS: none") -Encoding UTF8
    $null = Invoke-Ff $project @("event", "-WorkDir", $mw, "-Stage", "dev", "-Status", "PASS", "-Round", "3")
    $null = Invoke-Ff $project @("event", "-WorkDir", $mw, "-Stage", "qa", "-Status", "FAIL", "-Round", "1", "-Note", "sendback=IMPL")
    $null = Invoke-Ff $project @("event", "-WorkDir", $mw, "-Stage", "dev", "-Status", "START")
    Check "developer after QA IMPL send-back -> opus" ((& $pick @("-Role", "developer")) -eq "opus") ""
    Check "dev reviewer stays above escalated developer (fable)" ((& $pick @("-Role", "reviewer", "-Stage", "dev")) -eq "fable") ""
    Check "plan reviewer above planner opus -> fable" ((& $pick @("-Role", "reviewer", "-Stage", "plan")) -eq "fable") ""
    $null = Invoke-Ff $project @("event", "-WorkDir", $mw, "-Stage", "dev", "-Status", "RESUME", "-Note", "user")
    Check "QA send-back escalation ends at the user's RESUME (developer back to sonnet)" ((& $pick @("-Role", "developer")) -eq "sonnet") ""
    $r = Invoke-Ff $project @("event", "-WorkDir", $mw, "-Stage", "dev", "-Status", "FAIL", "-Round", "4", "-Model", "sonnet", "-ReviewerModel", "opus")
    Check "event -ReviewerModel appends [reviewer=...]" ($r.Out -match '\[model=sonnet\] \[reviewer=opus\]') $r.Out
    [System.IO.File]::WriteAllText((Join-Path $mw "01-spec.md"), ($specText))
    $r = Invoke-Ff $project @("pick-model", "-WorkDir", $mw, "-Role", "planner", "-MaxModel", "opus")
    Check "cap reason says capped, not escalated" (($r.Out -match 'capped at opus') -and ($r.Out -notmatch 'escalated')) $r.Out
    $r = Invoke-Ff $project @("pick-model", "-WorkDir", $mw, "-Role", "planner", "-MaxModel", "haiku")
    Check "cap below base -> haiku, capped" (($r.Out -match 'MODEL\s+haiku') -and ($r.Out -match 'capped at haiku') -and ($r.Out -notmatch 'escalated')) $r.Out

    # 14. auto-check: STOP / WAIT / RESUME / LIMIT; auto RESUME does not reset counters.
    $ac = Join-Path $project "ac"
    New-Item -ItemType Directory -Path $ac -Force | Out-Null
    $log = Join-Path $ac "events.log"
    $old = (Get-Date).AddMinutes(-90).ToString("yyyy-MM-ddTHH:mm:ss")
    $recent = (Get-Date).AddMinutes(-5).ToString("yyyy-MM-ddTHH:mm:ss")
    $setLog = {
        param([string[]]$Lines, [int]$AgeMinutes)
        [System.IO.File]::WriteAllText($log, (($Lines -join "`n") + "`n"))
        (Get-Item -LiteralPath $log).LastWriteTime = (Get-Date).AddMinutes(-$AgeMinutes)
    }
    $decide = {
        $res = Invoke-Ff $project @("auto-check", "-WorkDir", $ac)
        $m = [regex]::Match($res.Out, '(?m)^DECISION\s+(\S+)')
        if ($m.Success) { return $m.Groups[1].Value }
        return "ERR: " + $res.Out
    }
    & $setLog @() 90
    Check "auto-check no events -> STOP" ((& $decide) -eq "STOP") ""
    & $setLog @("$old | intake | START | r0 | ") 90
    Check "auto-check unapproved intake -> STOP" ((& $decide) -eq "STOP") ""
    & $setLog @("$old | intake | PASS | r0 | ", "$old | plan | START | r0 | ", "$old | plan | BLOCKED_ENV | r1 | no python") 90
    Check "auto-check escalated -> STOP" ((& $decide) -eq "STOP") ""
    & $setLog @("$old | intake | PASS | r0 | ", "$old | wiki | PASS | r1 | ", "$old | done | PASS | r0 | ") 90
    Check "auto-check finished -> STOP" ((& $decide) -eq "STOP") ""
    & $setLog @("$old | intake | PASS | r0 | ", "$recent | dev | START | r0 | ") 5
    Check "auto-check recent activity -> WAIT" ((& $decide) -eq "WAIT") ""
    & $setLog @("$old | intake | PASS | r0 | ", "$old | dev | START | r0 | ", "$old | dev | FAIL | r1 | gate") 90
    $r = Invoke-Ff $project @("auto-check", "-WorkDir", $ac)
    Check "auto-check idle mid-run -> RESUME with NEXT" (($r.Out -match 'DECISION\s+RESUME') -and ($r.Out -match 'NEXT\s+dev round 2')) $r.Out
    $a1 = (Get-Date).AddHours(-3).ToString("yyyy-MM-ddTHH:mm:ss"); $a2 = (Get-Date).AddHours(-2).ToString("yyyy-MM-ddTHH:mm:ss"); $a3 = (Get-Date).AddHours(-1.6).ToString("yyyy-MM-ddTHH:mm:ss")
    & $setLog @("$old | intake | PASS | r0 | ", "$a1 | dev | RESUME | r0 | auto", "$a2 | dev | RESUME | r0 | auto", "$a3 | dev | RESUME | r0 | auto", "$old | dev | FAIL | r1 | gate") 90
    Check "auto-check 3 auto resumes in 24h -> LIMIT" ((& $decide) -eq "LIMIT") ""
    $d26 = (Get-Date).AddHours(-26).ToString("yyyy-MM-ddTHH:mm:ss")
    & $setLog @("$old | intake | PASS | r0 | ", "$d26 | dev | RESUME | r0 | auto", "$d26 | dev | RESUME | r0 | auto", "$d26 | dev | RESUME | r0 | auto", "$old | dev | FAIL | r1 | gate") 90
    Check "auto resumes older than 24h do not count" ((& $decide) -eq "RESUME") ""
    & $setLog @("$old | intake | PASS | r0 | ", "$old | dev | START | r0 | ", "$old | dev | FAIL | r1 | ", "$old | dev | FAIL | r2 | ", "$old | dev | RESUME | r0 | auto", "$old | dev | FAIL | r3 | ") 90
    Check "auto RESUME does not reset the fail counter (3rd FAIL -> STOP)" ((& $decide) -eq "STOP") ""
    & $setLog @("$old | intake | PASS | r0 | ", "$old | dev | START | r0 | ", "$old | dev | FAIL | r1 | ", "$old | dev | FAIL | r2 | ", "$old | dev | RESUME | r0 | user", "$old | dev | FAIL | r3 | ") 90
    Check "user RESUME resets the fail counter (-> RESUME)" ((& $decide) -eq "RESUME") ""

    # 15. Counter bypass closed: a RESUME note that is not "user" never resets counters.
    & $setLog @("$old | intake | PASS | r0 | ", "$old | dev | START | r0 | ", "$old | dev | FAIL | r1 | ", "$old | dev | FAIL | r2 | ", "$old | dev | RESUME | r0 | scheduled", "$old | dev | FAIL | r3 | ") 90
    Check "RESUME note 'scheduled' does not reset the fail counter (-> STOP)" ((& $decide) -eq "STOP") ""

    # 16. auto-check logs the auto RESUME itself; an immediate second firing waits; NEXT survives RESUME markers.
    & $setLog @("$old | intake | PASS | r0 | ", "$old | dev | START | r0 | ", "$old | dev | FAIL | r1 | gate") 90
    $r = Invoke-Ff $project @("auto-check", "-WorkDir", $ac)
    Check "auto-check RESUME prints ACTION and logs the event" (($r.Out -match 'ACTION\s+print') -and ([System.IO.File]::ReadAllText($log) -match '(?m)\| dev \| RESUME \| r0 \| auto')) $r.Out
    Check "second firing right after -> WAIT" ((& $decide) -eq "WAIT") ""
    $r = Invoke-Ff $project @("status", "-WorkDir", $ac)
    Check "NEXT after auto RESUME still dev round 2" ($r.Out -match 'NEXT\s+dev round 2') $r.Out
    & $setLog @("$old | intake | PASS | r0 | ", "$old | intake | RESUME | r0 | auto") 90
    $r = Invoke-Ff $project @("status", "-WorkDir", $ac)
    Check "intake PASS + RESUME -> NEXT plan START" ($r.Out -match 'NEXT\s+plan START') $r.Out
    Check "intake PASS + RESUME is resumable (not 'spec not approved')" ((& $decide) -eq "RESUME") ""
    & $setLog @("$old | intake | PASS | r0 | ", "$old | qa | FAIL | r1 | sendback=IMPL", "$old | qa | RESUME | r0 | auto") 90
    $r = Invoke-Ff $project @("status", "-WorkDir", $ac)
    Check "send-back + RESUME -> NEXT dev START" ($r.Out -match 'NEXT\s+dev START') $r.Out
    & $setLog @("$old | intake | PASS | r0 | ", "$old | plan | START | r0 | ", "$old | plan | BLOCKED_ENV | r1 | x", "$old | plan | RESUME | r0 | user") 90
    $r = Invoke-Ff $project @("status", "-WorkDir", $ac)
    Check "halt + user RESUME -> NEXT stage round" ($r.Out -match 'NEXT\s+plan round 2') $r.Out
    & $setLog @("$old | intake | PASS | r0 | ", "$old | plan | BLOCKED_ENV | r1 | x", "$old | plan | RESUME | r0 | auto") 90
    Check "halt + auto RESUME stays stopped" ((& $decide) -eq "STOP") ""
    & $setLog @("$old | intake | PASS | r0 | ", "$old | wiki | PASS | r2 | ") 90
    $r = Invoke-Ff $project @("status", "-WorkDir", $ac)
    Check "wiki PASS -> NEXT done PASS" ($r.Out -match 'NEXT\s+done PASS') $r.Out

    # 16b. A halt after a PASS does not re-run the passed stage; a user RESUME on another stage still resets counters.
    & $setLog @("$old | intake | PASS | r0 | ", "$old | plan | PASS | r1 | ", "$old | plan | PAUSE | r0 | user stopped", "$old | plan | RESUME | r0 | user") 90
    $r = Invoke-Ff $project @("status", "-WorkDir", $ac)
    Check "PASS -> PAUSE -> user RESUME -> NEXT dev START" ($r.Out -match 'NEXT\s+dev START') $r.Out
    & $setLog @("$old | intake | START | r0 | ", "$old | intake | PAUSE | r0 | user stopped", "$old | intake | RESUME | r0 | user") 90
    $r = Invoke-Ff $project @("status", "-WorkDir", $ac)
    Check "intake PAUSE -> user RESUME -> NEXT intake" ($r.Out -match 'NEXT\s+intake: interview') $r.Out
    & $setLog @("$old | intake | PASS | r0 | ", "$old | dev | START | r0 | ", "$old | dev | FAIL | r1 | ", "$old | dev | FAIL | r2 | ", "$old | dev | FAIL | r3 | ", "$old | dev | LOOP_LIMIT | r3 | ", "$old | qa | RESUME | r0 | user") 90
    $r = Invoke-Ff $project @("status", "-WorkDir", $ac)
    Check "user RESUME logged on another stage still lifts the loop limit" (($r.Out -match 'NEXT\s+dev round 4') -and ($r.Out -match 'FAILS\s+0')) $r.Out

    # 16c. Halt + user RESUME keeps the meaning of the event before the halt, whatever stage the halt was logged on.
    & $setLog @("$old | intake | PASS | r0 | ", "$old | qa | START | r0 | ", "$old | qa | FAIL | r1 | sendback=IMPL x", "$old | qa | PAUSE | r0 | user stopped", "$old | qa | RESUME | r0 | user") 90
    $r = Invoke-Ff $project @("status", "-WorkDir", $ac)
    Check "QA send-back -> PAUSE -> user RESUME -> NEXT dev START (not QA again)" ($r.Out -match 'NEXT\s+dev START') $r.Out
    & $setLog @("$old | intake | PASS | r0 | ", "$old | dev | PASS | r2 | ", "$old | intake | PAUSE | r0 | user stopped", "$old | intake | RESUME | r0 | user") 90
    $r = Invoke-Ff $project @("status", "-WorkDir", $ac)
    Check "PAUSE logged on another stage after dev PASS -> NEXT qa START" ($r.Out -match 'NEXT\s+qa START') $r.Out

    # 16d. Settings: init writes settings.txt; later calls without -MaxRounds use it (scheduled firings too).
    $r = Invoke-Ff $project @("init", "-Title", "settings probe", "-MaxRounds", "2", "-MaxQaCycles", "1", "-MaxModel", "opus")
    $sw = Get-WorkDirLine $r.Out
    Check "init writes settings.txt" (([System.IO.File]::ReadAllText((Join-Path $sw "settings.txt"))) -match 'MaxRounds=2') $r.Out
    $null = Invoke-Ff $project @("event", "-WorkDir", $sw, "-Stage", "dev", "-Status", "START")
    $null = Invoke-Ff $project @("event", "-WorkDir", $sw, "-Stage", "dev", "-Status", "FAIL", "-Round", "1")
    $r = Invoke-Ff $project @("event", "-WorkDir", $sw, "-Stage", "dev", "-Status", "FAIL", "-Round", "2")
    Check "settings MaxRounds=2 applies without passing -MaxRounds" ($r.Code -eq 3) $r.Out
    $r = Invoke-Ff $project @("status", "-WorkDir", $sw)
    Check "status reads settings (max 2, NEXT escalated)" (($r.Out -match 'max 2') -and ($r.Out -match 'NEXT\s+escalated')) $r.Out
    $r = Invoke-Ff $project @("pick-model", "-WorkDir", $sw, "-Role", "planner")
    Check "settings MaxModel=opus caps without passing -MaxModel" ($r.Out -match 'MODEL\s+opus') $r.Out
    $r = Invoke-Ff $project @("pick-model", "-WorkDir", $sw, "-Role", "planner", "-MaxModel", "inherit")
    Check "MaxModel inherit -> MODEL inherit" ($r.Out -match 'MODEL\s+inherit') $r.Out

    # 16e. event -SendBack writes the exact note prefix; invalid outside qa FAIL.
    $r = Invoke-Ff $project @("event", "-WorkDir", $sw, "-Stage", "qa", "-Status", "FAIL", "-Round", "1", "-SendBack", "IMPL", "-Note", "median wrong")
    Check "-SendBack IMPL writes sendback=IMPL note" ($r.Out -match 'r1 \| sendback=IMPL median wrong') $r.Out
    $r = Invoke-Ff $project @("event", "-WorkDir", $sw, "-Stage", "dev", "-Status", "FAIL", "-SendBack", "IMPL")
    Check "-SendBack outside qa FAIL -> exit 2" ($r.Code -eq 2) $r.Out

    # 16f. verify: runs commands from the project root, logs output and exit codes, exit 1 on any failure.
    $r = Invoke-Ff $project @("verify", "-WorkDir", $sw, "-Stage", "dev", "-Round", "1", "-Build", "echo build-ok", "-Test", "exit /b 0")
    $vlog = Join-Path $sw "evidence\dev\verify-r1.log"
    Check "verify all pass -> exit 0 with log" (($r.Code -eq 0) -and (Test-Path $vlog) -and ([System.IO.File]::ReadAllText($vlog) -match 'build-ok') -and ([System.IO.File]::ReadAllText($vlog) -match 'EXIT 0')) $r.Out
    $r = Invoke-Ff $project @("verify", "-WorkDir", $sw, "-Stage", "qa", "-Round", "1", "-Build", "echo ok", "-Test", "exit /b 3")
    Check "verify with a failing command -> exit 1, EXIT 3 logged" (($r.Code -eq 1) -and ($r.Out -match 'FAIL\s+exit 3') -and ([System.IO.File]::ReadAllText((Join-Path $sw "evidence\qa\verify-r1.log")) -match 'EXIT 3')) $r.Out
    $r = Invoke-Ff $project @("verify", "-WorkDir", $sw, "-Stage", "dev", "-Round", "2", "-Build", "none", "-Test", "none")
    Check "verify with no real command -> exit 2" ($r.Code -eq 2) $r.Out

    # 16g. Reversed line range is rejected.
    Set-Content -LiteralPath (Join-Path $sw "02-todo.md") -Value @("## Dev", "- [x] D1: reversed", "  - evidence: src/Lockout.cs:9-2") -Encoding UTF8
    $r = Invoke-Ff $project @("check-todo", "-WorkDir", $sw, "-Prefix", "D")
    Check "reversed range 9-2 -> BAD-REF" (($r.Code -eq 1) -and ($r.Out -match 'reversed')) $r.Out

    # 17. PAUSE stops automatic resumes; heartbeat makes a long-running round look active; LIMIT is checked before WAIT.
    & $setLog @("$old | intake | PASS | r0 | ", "$old | dev | START | r0 | ", "$old | dev | PAUSE | r0 | user stopped") 90
    Check "PAUSE -> STOP" ((& $decide) -eq "STOP") ""
    & $setLog @("$old | intake | PASS | r0 | ", "$old | dev | START | r0 | ") 90
    $r = Invoke-Ff $project @("heartbeat", "-WorkDir", $ac)
    Check "heartbeat writes lock" (($r.Code -eq 0) -and (Test-Path (Join-Path $ac "lock"))) $r.Out
    Check "fresh heartbeat -> WAIT" ((& $decide) -eq "WAIT") ""
    Remove-Item -LiteralPath (Join-Path $ac "lock") -Force
    $n = (Get-Date).AddMinutes(-2).ToString("yyyy-MM-ddTHH:mm:ss")
    & $setLog @("$old | intake | PASS | r0 | ", "$a1 | dev | RESUME | r0 | auto", "$a2 | dev | RESUME | r0 | auto", "$n | dev | RESUME | r0 | auto") 2
    Check "LIMIT is reported even while recently active" ((& $decide) -eq "LIMIT") ""

    # 18. Absolute evidence paths: inside the project accepted, outside rejected, missing inside rejected.
    $absOk = (Join-Path $project "src\Lockout.cs") + ":7"
    $absMissing = (Join-Path $project "src\Ghost.cs") + ":1"
    $absOutside = (Join-Path ([System.IO.Path]::GetTempPath()) "elsewhere.txt") + ":1"
    Set-Content -LiteralPath ($absOutside -replace ':1$', '') -Value "x" -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $sw "02-todo.md") -Value @("## Dev", "- [x] D1: abs ok", "  - evidence: $absOk", "- [x] D2: abs missing", "  - evidence: src/Lockout.cs:2 | $absMissing", "- [x] D3: abs outside", "  - evidence: $absOutside") -Encoding UTF8
    $r = Invoke-Ff $project @("check-todo", "-WorkDir", $sw, "-Prefix", "D")
    Check "absolute path inside the project is a valid ref" ($r.Out -match '(?m)^OK\s+D1') $r.Out
    Check "missing absolute path is caught even next to a valid ref" ($r.Out -match '(?m)^BAD-REF\s+D2.*missing file') $r.Out
    Check "absolute path outside the project is rejected" ($r.Out -match '(?m)^BAD-REF\s+D3.*outside the project') $r.Out
    Remove-Item -LiteralPath ($absOutside -replace ':1$', '') -Force

    # 19. Reviewer at the cap goes one tier below the worker (still a different model).
    $r = Invoke-Ff $project @("pick-model", "-WorkDir", $mw, "-Role", "reviewer", "-Stage", "plan", "-MaxModel", "opus")
    Check "planner at cap opus -> reviewer sonnet (below)" (($r.Out -match 'MODEL\s+sonnet') -and ($r.Out -match 'reviewer below worker')) $r.Out

    # 20. Separate budgets: gate FAILs vs reviewer FAILs; MASTER_FIX resets once, a second one trips.
    $bw = Get-WorkDirLine (Invoke-Ff $project @("init", "-Title", "budget probe")).Out
    $null = Invoke-Ff $project @("event", "-WorkDir", $bw, "-Stage", "dev", "-Status", "START")
    foreach ($n in 1..2) { $null = Invoke-Ff $project @("event", "-WorkDir", $bw, "-Stage", "dev", "-Status", "FAIL", "-Round", "$n", "-Note", "gate: check-todo") }
    foreach ($n in 3..4) { $null = Invoke-Ff $project @("event", "-WorkDir", $bw, "-Stage", "dev", "-Status", "FAIL", "-Round", "$n", "-Note", "reviewer: D2 wrong") }
    $r = Invoke-Ff $project @("status", "-WorkDir", $bw)
    Check "2 gate + 2 reviewer FAILs stay under both budgets" (($r.Out -match 'FAILS\s+2 review \(max 3\), 2 gate \(max 3\)') -and ($r.Out -match 'NEXT\s+dev round 5')) $r.Out
    $r = Invoke-Ff $project @("event", "-WorkDir", $bw, "-Stage", "dev", "-Status", "FAIL", "-Round", "5", "-Note", "gate: diff")
    Check "third gate FAIL trips the gate budget (exit 3)" (($r.Code -eq 3) -and ($r.Out -match 'gate FAILs reached')) $r.Out
    $r = Invoke-Ff $project @("event", "-WorkDir", $bw, "-Stage", "dev", "-Status", "MASTER_FIX", "-Note", "loop: merged the two reviews into one fix list")
    Check "first MASTER_FIX accepted" ($r.Code -eq 0) $r.Out
    $r = Invoke-Ff $project @("status", "-WorkDir", $bw)
    Check "MASTER_FIX resets the budgets and continues" (($r.Out -match 'FAILS\s+0 review') -and ($r.Out -match 'NEXT\s+dev round 6')) $r.Out
    $r = Invoke-Ff $project @("event", "-WorkDir", $bw, "-Stage", "dev", "-Status", "MASTER_FIX", "-Note", "loop: again")
    $bwLog = [System.IO.File]::ReadAllText((Join-Path $bw "events.log"))
    Check "second loop MASTER_FIX -> exit 3 and LOOP_LIMIT logged instead" (($r.Code -eq 3) -and ($r.Out -match 'master fix') -and ($bwLog -match '\| dev \| LOOP_LIMIT \|') -and ($bwLog -notmatch 'MASTER_FIX \| r0 \| loop: again')) $r.Out
    $r = Invoke-Ff $project @("status", "-WorkDir", $bw)
    Check "after the refused fix, NEXT is escalated (not another round)" ($r.Out -match 'NEXT\s+escalated') $r.Out

    # 20b. block fixes have their own budget and do not reset the FAIL counters; the model never drops after a fix.
    $kw = Get-WorkDirLine (Invoke-Ff $project @("init", "-Title", "fix kinds")).Out
    Set-Content -LiteralPath (Join-Path $kw "02-todo.md") -Value @("## Dev", "- [ ] D1: a", "  - evidence:", "- [ ] D2: b", "  - evidence:") -Encoding UTF8
    $null = Invoke-Ff $project @("event", "-WorkDir", $kw, "-Stage", "dev", "-Status", "START")
    foreach ($n in 1..2) { $null = Invoke-Ff $project @("event", "-WorkDir", $kw, "-Stage", "dev", "-Status", "FAIL", "-Round", "$n", "-Note", "reviewer: x") }
    $r = Invoke-Ff $project @("event", "-WorkDir", $kw, "-Stage", "dev", "-Status", "MASTER_FIX", "-Round", "2", "-Note", "block: started the missing local service")
    Check "block MASTER_FIX accepted" ($r.Code -eq 0) $r.Out
    $r = Invoke-Ff $project @("status", "-WorkDir", $kw)
    Check "block MASTER_FIX keeps the reviewer FAIL count (2)" ($r.Out -match 'FAILS\s+2 review') $r.Out
    $r = Invoke-Ff $project @("event", "-WorkDir", $kw, "-Stage", "dev", "-Status", "MASTER_FIX", "-Round", "2", "-Note", "loop: consolidated")
    Check "loop MASTER_FIX still available after a block fix" ($r.Code -eq 0) $r.Out
    $r = Invoke-Ff $project @("pick-model", "-WorkDir", $kw, "-Role", "developer")
    Check "developer stays escalated (opus) after a loop MASTER_FIX" ($r.Out -match 'MODEL\s+opus') $r.Out
    $r = Invoke-Ff $project @("event", "-WorkDir", $kw, "-Stage", "dev", "-Status", "MASTER_FIX", "-Note", "fixed things")
    Check "MASTER_FIX without block:/loop: -> exit 2" ($r.Code -eq 2) $r.Out
    Check "event refreshes the lock" (Test-Path (Join-Path $bw "lock")) ""

    # 21. gate: runs the stage checks with commands from the spec; writes the review file and logs FAIL on failure.
    $gs = Get-WorkDirLine (Invoke-Ff $gp @("init", "-Title", "gate probe")).Out
    $specG = [System.IO.File]::ReadAllText((Join-Path $gs "01-spec.md")) -replace '- build:', '- build: echo build-ok' -replace '- test:', '- test: exit /b 0'
    [System.IO.File]::WriteAllText((Join-Path $gs "01-spec.md"), $specG)
    Set-Content -LiteralPath (Join-Path $gs "02-todo.md") -Value @("## Dev", "- [x] D1: a.txt changed", "  - evidence: src/a.txt:1", "## QA", "- [ ] Q1: q", "  - evidence:") -Encoding UTF8
    $r = Invoke-Ff $gp @("gate", "-WorkDir", $gs, "-Stage", "plan", "-Round", "1")
    Check "plan gate passes on a well-formed TODO" (($r.Code -eq 0) -and ($r.Out -match 'GATE\s+PASS')) $r.Out
    $r = Invoke-Ff $gp @("gate", "-WorkDir", $gs, "-Stage", "dev", "-Round", "1")
    Check "dev gate runs verify, check-todo and diff and passes" (($r.Code -eq 0) -and ($r.Out -match 'STEP\s+verify\s+exit 0') -and ($r.Out -match 'STEP\s+diff\s+exit 0') -and (Test-Path (Join-Path $gs "evidence\dev\verify-r1.log"))) $r.Out
    [System.IO.File]::WriteAllText((Join-Path $gs "01-spec.md"), ($specG -replace 'exit /b 0', 'exit /b 4'))
    $r = Invoke-Ff $gp @("gate", "-WorkDir", $gs, "-Stage", "dev", "-Round", "2")
    $rv = Join-Path $gs "reviews\dev-r2.md"
    Check "failing dev gate -> exit 1, review file and FAIL event written" (($r.Code -eq 1) -and (Test-Path $rv) -and ([System.IO.File]::ReadAllText($rv) -match '^VERDICT: FAIL \(gate\)') -and ([System.IO.File]::ReadAllText((Join-Path $gs "events.log")) -match '\| dev \| FAIL \| r2 \| gate: verify')) $r.Out
    $specNone = [System.IO.File]::ReadAllText((Join-Path $gs "01-spec.md")) -replace '- build: echo build-ok', '- build: none' -replace '- test: exit /b 4', '- test: none'
    [System.IO.File]::WriteAllText((Join-Path $gs "01-spec.md"), $specNone)
    $r = Invoke-Ff $gp @("gate", "-WorkDir", $gs, "-Stage", "qa", "-Round", "1")
    Check "qa gate with no spec commands skips verify" (($r.Out -match 'SKIP\s+verify') -and ($r.Code -eq 1) -and ($r.Out -match 'check-todo')) $r.Out

    # 21b. Empty Verify lines from the init template never turn the next line into a command.
    $et = Get-WorkDirLine (Invoke-Ff $gp @("init", "-Title", "empty verify")).Out
    Set-Content -LiteralPath (Join-Path $et "02-todo.md") -Value @("## Dev", "- [x] D1: a", "  - evidence: src/a.txt:1", "## QA", "- [ ] Q1: q", "  - evidence:") -Encoding UTF8
    $r = Invoke-Ff $gp @("gate", "-WorkDir", $et, "-Stage", "dev", "-Round", "1")
    Check "template spec with empty build/test -> verify skipped, not '- test:' run" (($r.Out -match 'SKIP\s+verify') -and ($r.Out -notmatch 'STEP\s+verify')) $r.Out

    # 21c. Quoted commands and && survive the gate (verify reads the spec itself).
    $qt = Get-WorkDirLine (Invoke-Ff $gp @("init", "-Title", "quoted cmd")).Out
    $specQ = [System.IO.File]::ReadAllText((Join-Path $qt "01-spec.md")) -replace '- build:', '- build: echo "hello world" && exit 0' -replace '- test:', '- test: exit /b 0'
    [System.IO.File]::WriteAllText((Join-Path $qt "01-spec.md"), $specQ)
    Set-Content -LiteralPath (Join-Path $qt "02-todo.md") -Value @("## Dev", "- [x] D1: a", "  - evidence: src/a.txt:1", "## QA", "- [ ] Q1: q", "  - evidence:") -Encoding UTF8
    $r = Invoke-Ff $gp @("gate", "-WorkDir", $qt, "-Stage", "dev", "-Round", "1")
    Check "quoted build command with && runs in the gate" (($r.Code -eq 0) -and ([System.IO.File]::ReadAllText((Join-Path $qt "evidence\dev\verify-r1.log")) -match 'hello world')) $r.Out

    # 21d. "..", and paths into agent worktrees, are rejected as evidence.
    New-Item -ItemType Directory -Path (Join-Path $gp ".claude\worktrees\agent-a") -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $gp ".claude\worktrees\agent-a\fa.txt") -Value "x" -Encoding ASCII
    $outsideSibling = Join-Path (Split-Path $gp -Parent) "sibling.txt"
    Set-Content -LiteralPath $outsideSibling -Value "x" -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $qt "02-todo.md") -Value @("## Dev", "- [x] D1: dotdot", "  - evidence: ../sibling.txt:1", "- [x] D2: worktree", "  - evidence: .claude/worktrees/agent-a/fa.txt:1") -Encoding UTF8
    $r = Invoke-Ff $gp @("check-todo", "-WorkDir", $qt, "-Prefix", "D")
    Check "'..' escaping the project is rejected" ($r.Out -match '(?m)^BAD-REF\s+D1.*outside the project') $r.Out
    Check "evidence inside an agent worktree is rejected" ($r.Out -match '(?m)^BAD-REF\s+D2.*agent worktree') $r.Out
    Remove-Item -LiteralPath $outsideSibling -Force
    Remove-Item -LiteralPath (Join-Path $gp ".claude") -Recurse -Force

    # 21e. A project that itself lives under .claude/worktrees (desktop sessions) keeps valid refs.
    $wtProj = Join-Path $project "host\.claude\worktrees\session-x"
    New-Item -ItemType Directory -Path (Join-Path $wtProj "src") -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $wtProj "src\m.txt") -Value @("one", "two") -Encoding ASCII
    $wtWork = Get-WorkDirLine (Invoke-Ff $wtProj @("init", "-Title", "inside worktree")).Out
    Set-Content -LiteralPath (Join-Path $wtWork "02-todo.md") -Value @("## Dev", "- [x] D1: m", "  - evidence: src/m.txt:2") -Encoding UTF8
    $r = Invoke-Ff $wtProj @("check-todo", "-WorkDir", $wtWork, "-Prefix", "D")
    Check "project inside a session worktree: relative refs stay valid" (($r.Code -eq 0) -and ($r.Out -match '(?m)^OK\s+D1')) $r.Out

    # 22. merge-evidence: parallel developers' group files fold into 02-todo.md; duplicates and unknown ids fail.
    Set-Content -LiteralPath (Join-Path $gs "02-todo.md") -Value @("## Dev", "- [ ] D1: a [group:A]", "  - evidence:", "- [ ] D2: b [group:B]", "  - evidence:", "## QA", "- [ ] Q1: q", "  - evidence:") -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $gs "evidence\dev\group-A.md") -Value @("- [x] D1: a [group:A]", "  - evidence: src/a.txt:1") -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $gs "evidence\dev\group-B.md") -Value @("- [x] D2: b [group:B]", "  - evidence: src/b.txt:1") -Encoding UTF8
    $r = Invoke-Ff $gp @("merge-evidence", "-WorkDir", $gs)
    $todoAfter = [System.IO.File]::ReadAllText((Join-Path $gs "02-todo.md"))
    Check "merge-evidence folds both groups" (($r.Code -eq 0) -and ($todoAfter -match '- \[x\] D1') -and ($todoAfter -match 'evidence: src/b\.txt:1') -and ($todoAfter -match '- \[ \] Q1')) $r.Out
    Set-Content -LiteralPath (Join-Path $gs "evidence\dev\group-C.md") -Value @("- [x] D2: dup", "  - evidence: src/b.txt:1", "- [x] D9: ghost", "  - evidence: src/b.txt:1") -Encoding UTF8
    $r = Invoke-Ff $gp @("merge-evidence", "-WorkDir", $gs)
    Check "merge-evidence reports duplicate and unknown ids (exit 1)" (($r.Code -eq 1) -and ($r.Out -match 'DUPLICATE\s+D2') -and ($r.Out -match 'UNKNOWN\s+D9')) $r.Out
    Remove-Item -LiteralPath (Join-Path $gs "evidence\dev\group-C.md") -Force
    Set-Content -LiteralPath (Join-Path $gs "evidence\dev\group-B.md") -Value @("- [x] D2: b [group:B]", "- evidence: src/b.txt:1") -Encoding UTF8
    $r = Invoke-Ff $gp @("merge-evidence", "-WorkDir", $gs)
    Check "unindented evidence line in a group file is still merged (not blanked)" (($r.Code -eq 0) -and ([System.IO.File]::ReadAllText((Join-Path $gs "02-todo.md")) -match 'evidence: src/b\.txt:1')) $r.Out
    # 23. decision: appends under "## Decisions" (creating it), keeps later sections intact, caps master decisions.
    $dw = Get-WorkDirLine (Invoke-Ff $project @("init", "-Title", "decisions probe", "-MaxDecisions", "2")).Out
    $r = Invoke-Ff $project @("decision", "-WorkDir", $dw, "-Kind", "decided", "-Stage", "plan", "-Note", "hyphenated words count as one word")
    $specD = [System.IO.File]::ReadAllText((Join-Path $dw "01-spec.md"))
    Check "decision creates ## Decisions with a master-decided entry" (($r.Code -eq 0) -and ($specD -match '(?m)^## Decisions\r?\n- master-decided \(\d{4}-\d{2}-\d{2}, plan\): hyphenated words count as one word')) $r.Out
    [System.IO.File]::WriteAllText((Join-Path $dw "01-spec.md"), ($specD.TrimEnd() + "`n`n## Notes`nkeep me`n"))
    $r = Invoke-Ff $project @("decision", "-WorkDir", $dw, "-Kind", "created", "-Stage", "dev", "-Note", "samples/.gitkeep (needed by the build)")
    $specD = [System.IO.File]::ReadAllText((Join-Path $dw "01-spec.md"))
    Check "created entry goes inside ## Decisions, before the next section" (($r.Code -eq 0) -and ($specD -match '(?s)## Decisions.*master-created \(.*dev\): samples/\.gitkeep.*## Notes\r?\nkeep me')) $specD
    $r = Invoke-Ff $project @("decision", "-WorkDir", $dw, "-Kind", "decided", "-Stage", "dev", "-Note", "second")
    Check "second decision accepted (max 2)" ($r.Code -eq 0) $r.Out
    $r = Invoke-Ff $project @("decision", "-WorkDir", $dw, "-Kind", "decided", "-Stage", "dev", "-Note", "third")
    Check "third decision over MaxDecisions -> exit 3, not recorded" (($r.Code -eq 3) -and ([System.IO.File]::ReadAllText((Join-Path $dw "01-spec.md")) -notmatch 'third')) $r.Out
    $null = Invoke-Ff $project @("event", "-WorkDir", $dw, "-Stage", "intake", "-Status", "PASS")
    $r = Invoke-Ff $project @("status", "-WorkDir", $dw)
    Check "status shows the decision counts" ($r.Out -match 'DECISIONS 2 master-decided \(max 2\), 1 master-created') $r.Out
    $r = Invoke-Ff $project @("decision", "-WorkDir", $dw, "-Stage", "dev", "-Note", "x")
    Check "decision without -Kind -> exit 2" ($r.Code -eq 2) $r.Out
    $r = Invoke-Ff $project @("decision", "-WorkDir", $dw, "-Kind", "user", "-Stage", "dev", "-Note", "no CLI", "-Overrides", "master-decided (dev): second")
    $specU = [System.IO.File]::ReadAllText((Join-Path $dw "01-spec.md"))
    Check "user entry is recorded with its override and is not capped" (($r.Code -eq 0) -and ($specU -match '(?m)^- user \(\d{4}-\d{2}-\d{2}, dev\): no CLI \(overrides: master-decided \(dev\): second\)')) $r.Out
    $logD = [System.IO.File]::ReadAllText((Join-Path $dw "events.log"))
    Check "each decision adds a DECIDED line to events.log" ((([regex]::Matches($logD, '\| DECIDED \| r0 \|')).Count -eq 4) -and ($logD -match 'DECIDED \| r0 \| user: no CLI')) $logD
    $r = Invoke-Ff $project @("status", "-WorkDir", $dw)
    Check "DECIDED lines never change NEXT (still plan START after intake PASS)" ($r.Out -match 'NEXT\s+plan START') $r.Out

    # 24. Verdict cross-check: PASS / NEEDS_DECISION must match the round's review file, which must judge
    #     every standing master entry; a second opinion can uphold an entry so later reviewers skip it.
    $vw = Get-WorkDirLine (Invoke-Ff $project @("init", "-Title", "verdict probe")).Out
    $null = Invoke-Ff $project @("event", "-WorkDir", $vw, "-Stage", "intake", "-Status", "PASS")
    $null = Invoke-Ff $project @("event", "-WorkDir", $vw, "-Stage", "plan", "-Status", "START")
    $r = Invoke-Ff $project @("event", "-WorkDir", $vw, "-Stage", "plan", "-Status", "PASS", "-Round", "1")
    Check "PASS without a review file -> rejected (exit 2), not logged" (($r.Code -eq 2) -and ($r.Out -match 'REJECTED') -and ([System.IO.File]::ReadAllText((Join-Path $vw "events.log")) -notmatch '\| plan \| PASS \|')) $r.Out
    $rv1 = Join-Path $vw "reviews\plan-r1.md"
    Set-Content -LiteralPath $rv1 -Value @("VERDICT: FAIL", "ISSUES:", "- [high] D1 - wrong - right", "DECISIONS: none") -Encoding UTF8
    $r = Invoke-Ff $project @("event", "-WorkDir", $vw, "-Stage", "plan", "-Status", "PASS", "-Round", "1")
    Check "PASS while the review says FAIL -> rejected" (($r.Code -eq 2) -and ($r.Out -match 'says VERDICT: FAIL')) $r.Out
    $null = Invoke-Ff $project @("decision", "-WorkDir", $vw, "-Kind", "decided", "-Stage", "plan", "-Note", "hyphenated words count as one word")
    $null = Invoke-Ff $project @("decision", "-WorkDir", $vw, "-Kind", "decided", "-Stage", "plan", "-Note", "return 0 for whitespace-only input")
    Set-Content -LiteralPath $rv1 -Value @("VERDICT: PASS", "ISSUES:", "- none", "DECISIONS:", "- [ok] master-decided (x, plan): hyphenated words count as one word - in scope") -Encoding UTF8
    $r = Invoke-Ff $project @("event", "-WorkDir", $vw, "-Stage", "plan", "-Status", "PASS", "-Round", "1")
    Check "PASS whose review skipped a standing master entry -> rejected" (($r.Code -eq 2) -and ($r.Out -match 'did not judge') -and ($r.Out -match 'whitespace-only')) $r.Out
    Set-Content -LiteralPath $rv1 -Value @("VERDICT: PASS", "ISSUES:", "- none", "DECISIONS:", "- [ok] hyphenated words count as one word - in scope", "- [NEEDS_DECISION] return 0 for whitespace-only input - changes acceptance") -Encoding UTF8
    $r = Invoke-Ff $project @("event", "-WorkDir", $vw, "-Stage", "plan", "-Status", "PASS", "-Round", "1")
    Check "PASS with a [NEEDS_DECISION] master verdict -> rejected" (($r.Code -eq 2) -and ($r.Out -match 'log NEEDS_DECISION')) $r.Out
    Set-Content -LiteralPath $rv1 -Value @("VERDICT: NEEDS_DECISION", "ISSUES:", "- [high] Decisions - whitespace entry changes acceptance - user decides", "DECISIONS:", "- [ok] hyphenated words count as one word - in scope", "- [NEEDS_DECISION] return 0 for whitespace-only input - changes acceptance") -Encoding UTF8
    $r = Invoke-Ff $project @("event", "-WorkDir", $vw, "-Stage", "plan", "-Status", "NEEDS_DECISION", "-Round", "1", "-Note", "reviewer disputes whitespace entry")
    Check "NEEDS_DECISION matching the review is logged" ($r.Code -eq 0) $r.Out
    $r = Invoke-Ff $project @("pick-model", "-WorkDir", $vw, "-Role", "second", "-Stage", "plan")
    Check "second opinion model is one tier above the plan reviewer (fable cap -> fable)" (($r.Out -match 'MODEL\s+fable') -and ($r.Out -match 'second opinion')) $r.Out
    $r = Invoke-Ff $project @("pick-model", "-WorkDir", $vw, "-Role", "second", "-Stage", "dev")
    Check "second opinion for dev (reviewer opus) -> fable" ($r.Out -match 'MODEL\s+fable') $r.Out
    $r = Invoke-Ff $project @("decision", "-WorkDir", $vw, "-Kind", "upheld", "-Stage", "plan", "-Note", "return 0 for whitespace-only input (second opinion fable: in scope)")
    Check "upheld entry recorded" (($r.Code -eq 0) -and ([System.IO.File]::ReadAllText((Join-Path $vw "01-spec.md")) -match '(?m)^- upheld \(')) $r.Out
    $rv2 = Join-Path $vw "reviews\plan-r2.md"
    Set-Content -LiteralPath $rv2 -Value @("VERDICT: PASS", "ISSUES:", "- none", "DECISIONS:", "- [ok] hyphenated words count as one word - in scope") -Encoding UTF8
    $r = Invoke-Ff $project @("event", "-WorkDir", $vw, "-Stage", "plan", "-Status", "PASS", "-Round", "2")
    Check "after the upheld entry, a review judging only the rest may PASS" ($r.Code -eq 0) $r.Out
    $r = Invoke-Ff $project @("event", "-WorkDir", $vw, "-Stage", "plan", "-Status", "FAIL", "-Round", "2", "-Note", "reviewer: x")
    Check "FAIL over a review that says PASS -> rejected" (($r.Code -eq 2) -and ($r.Out -match 'says VERDICT: PASS')) $r.Out
    $null = Invoke-Ff $project @("event", "-WorkDir", $vw, "-Stage", "qa", "-Status", "START")
    $null = Invoke-Ff $project @("event", "-WorkDir", $vw, "-Stage", "qa", "-Status", "FAIL", "-Round", "1", "-Note", "review: master entry upheld by second opinion")
    $null = Invoke-Ff $project @("event", "-WorkDir", $vw, "-Stage", "qa", "-Status", "FAIL", "-Round", "2", "-Note", "review: master entry upheld by second opinion")
    $r = Invoke-Ff $project @("status", "-WorkDir", $vw)
    Check "upheld-only FAILs do not count toward the review budget" ($r.Out -match 'FAILS\s+0 review') $r.Out
    $r = Invoke-Ff $project @("pick-model", "-WorkDir", $vw, "-Role", "qa")
    Check "upheld-only FAILs do not raise the worker model (qa stays sonnet)" ($r.Out -match 'MODEL\s+sonnet') $r.Out
    Set-Content -LiteralPath (Join-Path $vw "reviews\dev-r1.md") -Value @("Worker reply", "RESULT: NEEDS_DECISION - which encoding?") -Encoding UTF8
    $r = Invoke-Ff $project @("event", "-WorkDir", $vw, "-Stage", "dev", "-Status", "NEEDS_DECISION", "-Round", "1", "-Note", "worker asks")
    Check "worker NEEDS_DECISION (RESULT line saved as the round file) is accepted" ($r.Code -eq 0) $r.Out

}
finally {
    Remove-Item -LiteralPath $project -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures -gt 0) { throw "feature-flow fixtures: $failures failure(s)" }
Write-Host "feature-flow fixtures passed."
