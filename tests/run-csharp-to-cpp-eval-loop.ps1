param(
    [string]$SourceRoot,
    [string]$RepositoryRoot,
    [string]$OutputDirectory,

    # OpenAI-compatible chat endpoint base, e.g. http://localhost:11434/v1 (Ollama), http://host:8000/v1 (vLLM/LM Studio).
    [string]$Endpoint,
    [string]$Model = "qwen3:20b",
    [string]$ApiKey = "none",
    [int]$ModelTimeoutSeconds = 600,

    # Loop tuning under test (A/B: run twice with different references and diff RUN_SUMMARY.md).
    [int]$MaxRounds = 3,
    [int]$MaxUnits = 0,
    [string]$MappingTable,
    [string]$Rules,
    [switch]$NoExample,

    # Optional parity at the end.
    [string]$CsExe,
    [string]$CasesDir,

    # No model: replay canned responses from -ResponseDir (<unit base>.md) or synthesize them from a golden C++ tree.
    [switch]$SkipModel,
    [string]$ResponseDir,
    [string]$GoldenRoot
)

# Self-running eval loop for the csharp-to-cpp-port skill: drives a local model through the real
# per-unit loop (prompt -> apply -> scan -> build -> re-prompt with errors) and scores the run
# deterministically (first-try build pass rate, final pass rate, forbidden hits, parity).
# Model output goes through files only (no pipe-buffer deadlocks); <think>...</think> blocks are stripped.

$ErrorActionPreference = "Stop"
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $RepositoryRoot) { $RepositoryRoot = (Resolve-Path (Join-Path $scriptDir "..")).Path }
$skill = Join-Path $RepositoryRoot "skills\csharp-to-cpp-port"
$scripts = Join-Path $skill "scripts"
$fixture = Join-Path $RepositoryRoot "tests\fixtures\csharp-to-cpp-port"
if (-not $SourceRoot) { $SourceRoot = Join-Path $fixture "sample-app" }
if ($SkipModel -and -not $ResponseDir -and -not $GoldenRoot) { $GoldenRoot = Join-Path $fixture "expected-cpp" }
if (-not $SkipModel -and -not $Endpoint) { throw "pass -Endpoint <openai-compatible base url> (or -SkipModel with -GoldenRoot/-ResponseDir)" }
$utf8 = New-Object System.Text.UTF8Encoding($false)

if (-not $OutputDirectory) {
    $runId = [DateTimeOffset]::Now.ToString("yyyyMMdd-HHmmss")
    $OutputDirectory = Join-Path (Join-Path $RepositoryRoot "out\csharp-to-cpp-eval") $runId
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$safeRoot = Join-Path $RepositoryRoot "out"
if (Test-Path -LiteralPath $OutputDirectory) {
    if (-not $OutputDirectory.StartsWith($safeRoot + "\", [System.StringComparison]::OrdinalIgnoreCase)) { throw "Refusing to remove OutputDirectory outside the repository out directory: $OutputDirectory" }
    [System.IO.Directory]::Delete($OutputDirectory, $true)
}
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$cppRoot = Join-Path $OutputDirectory "cpp"
New-Item -ItemType Directory -Force -Path $cppRoot | Out-Null
$workDir = Join-Path $cppRoot "port-work"

function Invoke-Skill {
    # Native powershell.exe child with -File: named parameters bind correctly, exit code is the script's own.
    param([string]$Script, [string[]]$Arguments)
    $global:LASTEXITCODE = 0
    $ErrorActionPreference = "Continue"   # a child's stderr line is data here, not a terminating error
    $text = (& powershell -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments 2>&1 | ForEach-Object { "$_" }) -join "`n"
    return @{ code = $LASTEXITCODE; text = $text }
}

$systemPrompt = "You are a C# to C++ porting executor. You receive exactly one C# file plus a fixed mapping table, hard rules, the declarations you may use, and sometimes the compiler errors from your last attempt. Produce exactly the two files requested, complete, in the strict '// FILE:' + fenced block format. Do not explain. Do not port anything else. Do not invent declarations: write '// TODO(port): needs <what>' where something is missing. When errors are listed, fix only those."

function Get-ModelResponse {
    param([string]$PromptPath, [string]$UnitBase, [int]$Round, [string]$SavePath)
    if ($SkipModel) {
        if ($ResponseDir) {
            $canned = Join-Path $ResponseDir ("{0}.md" -f ($UnitBase -replace '[\\/]', '__'))
            if (-not (Test-Path -LiteralPath $canned)) { return $null }
            Copy-Item -LiteralPath $canned -Destination $SavePath
            return $SavePath
        }
        $h = Join-Path $GoldenRoot ($UnitBase + ".h"); $c = Join-Path $GoldenRoot ($UnitBase + ".cpp")
        if (-not (Test-Path -LiteralPath $c)) { return $null }   # entry-point units have no header
        $rel = $UnitBase.Replace('\', '/')
        $nl = "`n"; $fence = '```'
        $body = ""
        if (Test-Path -LiteralPath $h) { $body += "// FILE: $rel.h$nl$fence" + "cpp$nl" + [System.IO.File]::ReadAllText($h).TrimEnd() + "$nl$fence$nl$nl" }
        $body += "// FILE: $rel.cpp$nl$fence" + "cpp$nl" + [System.IO.File]::ReadAllText($c).TrimEnd() + "$nl$fence$nl"
        [System.IO.File]::WriteAllText($SavePath, $body, $utf8)
        return $SavePath
    }
    $prompt = [System.IO.File]::ReadAllText($PromptPath)
    $payload = @{ model = $Model; temperature = 0; stream = $false; max_tokens = 8192; messages = @(@{ role = "system"; content = $systemPrompt }, @{ role = "user"; content = $prompt }) } | ConvertTo-Json -Depth 6 -Compress
    $bytes = $utf8.GetBytes($payload)
    $headers = @{ "Authorization" = "Bearer $ApiKey" }
    $uri = ($Endpoint.TrimEnd('/')) + "/chat/completions"
    try {
        # Invoke-WebRequest + explicit UTF-8 decoding: PS 5.1 Invoke-RestMethod decodes a reply without a
        # charset header as ISO-8859-1 and silently double-encodes Korean text in the ported files.
        $web = Invoke-WebRequest -UseBasicParsing -Method Post -Uri $uri -Headers $headers -ContentType "application/json; charset=utf-8" -Body $bytes -TimeoutSec $ModelTimeoutSeconds
        $raw = $utf8.GetString($web.RawContentStream.ToArray())
        $resp = $raw | ConvertFrom-Json
    }
    catch {
        [System.IO.File]::WriteAllText("$SavePath.error.txt", $_.Exception.Message, $utf8)
        return $null
    }
    $content = ""
    try { $content = [string]$resp.choices[0].message.content } catch { $content = "" }
    $content = [regex]::Replace($content, '(?s)<think>.*?</think>', '')
    $content = [regex]::Replace($content, '(?s)<think>.*$', '').Trim()   # unclosed <think> (max_tokens hit) leaves no code
    [System.IO.File]::WriteAllText($SavePath, $content + "`n", $utf8)
    return $SavePath
}

# 1. inventory
$inv = Invoke-Skill (Join-Path $scripts "inventory-csharp.ps1") @("-SourceRoot", $SourceRoot, "-CppRoot", $cppRoot)
if ($inv.code -ne 0) { throw "inventory failed: $($inv.text)" }
$units = @(Get-Content -LiteralPath (Join-Path $workDir "PORT_ORDER.txt") | ForEach-Object { ($_ -split "`t")[1] })
if ($MaxUnits -gt 0 -and $units.Count -gt $MaxUnits) { $units = $units[0..($MaxUnits - 1)] }

# 2. per-unit loop
$rows = @()
$unitIndex = 0
foreach ($unit in $units) {
    $unitIndex++
    $base = $unit -replace '\.cs$', ''
    $tag = ($base -replace '[\\/]', '__')
    $firstTryPass = $false; $finalPass = $false; $rounds = 0; $forbidden = 0; $lastError = ""; $modelFailed = $false; $extraNote = ""; $blockedByDep = $false; $todoCount = 0
    for ($round = 1; $round -le $MaxRounds; $round++) {
        $rounds = $round
        $promptPath = Join-Path $OutputDirectory ("{0}.round{1}.UNIT_PROMPT.md" -f $tag, $round)
        $mpArgs = @("-Unit", $unit, "-WorkDir", $workDir, "-CppRoot", $cppRoot, "-OutputPath", $promptPath, "-Mode", "paste")
        if ($extraNote) { $mpArgs += @("-ExtraNote", $extraNote) }
        if ($MappingTable) { $mpArgs += @("-MappingTable", $MappingTable) }
        if ($Rules) { $mpArgs += @("-Rules", $Rules) }
        if ($NoExample) { $mpArgs += "-NoExample" }
        $mp = Invoke-Skill (Join-Path $scripts "make-unit-prompt.ps1") $mpArgs
        if ($mp.code -ne 0) { $lastError = "make-unit-prompt: " + $mp.text; break }
        if ($mp.text -match 'BlockedDeps: ([1-9]\d*)') { $lastError = "blocked dependency (not the model's fault)"; $blockedByDep = $true; $rounds = 0; break }
        $isEntry = ($mp.text -match 'entry point, no header')
        $relBase = $base -replace '\\', '/'
        $expect = @(($relBase + ".cpp")); if (-not $isEntry) { $expect += ($relBase + ".h") }
        $respPath = Join-Path $OutputDirectory ("{0}.round{1}.MODEL_RESPONSE.md" -f $tag, $round)
        $got = Get-ModelResponse -PromptPath $promptPath -UnitBase $base -Round $round -SavePath $respPath
        if (-not $got) { $modelFailed = $true; $lastError = "no model response (see $respPath.error.txt or missing canned/golden files)"; break }
        $apArgs = @("-ResponsePath", $respPath, "-CppRoot", $cppRoot, "-Allow", $relBase, "-Overwrite")
        $apArgs += @("-Expect", ($expect -join ','))
        $ap = Invoke-Skill (Join-Path $scripts "apply-unit-response.ps1") $apArgs
        if ($ap.code -ne 0) {
            $lastError = "reply format: " + (($ap.text -split "`n" | Where-Object { $_ -match 'rejected|missing|no file blocks' } | Select-Object -First 2) -join '; ')
            $extraNote = "Your previous reply could not be applied ($lastError). Reply again using EXACTLY the format in the last section: one '// FILE: <path>' line, then a fenced cpp block with the COMPLETE file, for each file."
            if ($ap.code -eq 2) { continue }
        }
        else { $extraNote = "" }
        $scanPaths = @((Join-Path $cppRoot ($base + ".cpp")))
        if (Test-Path -LiteralPath (Join-Path $cppRoot ($base + ".h"))) { $scanPaths += (Join-Path $cppRoot ($base + ".h")) }
        $sc = Invoke-Skill (Join-Path $scripts "scan-forbidden.ps1") @("-Path", ($scanPaths -join ','))
        $forbidden = ([regex]::Matches($sc.text, '\|error\|')).Count
        if (-not (Test-Path -LiteralPath (Join-Path $cppRoot ($base + ".cpp")))) { continue }
        $bc = Invoke-Skill (Join-Path $scripts "build-check.ps1") @("-CppRoot", $cppRoot, "-Unit", ($base + ".cpp"), "-WorkDir", $workDir)
        Copy-Item -LiteralPath (Join-Path $workDir "BUILD_RESULT.txt") -Destination (Join-Path $OutputDirectory ("{0}.round{1}.BUILD_RESULT.txt" -f $tag, $round)) -ErrorAction SilentlyContinue
        if ($bc.code -eq 2) { $lastError = "NO_COMPILER: " + $bc.text; break }
        if ($bc.code -eq 0) {
            $finalPass = $true; if ($round -eq 1) { $firstTryPass = $true }
            foreach ($sp in $scanPaths) { $todoCount += ([regex]::Matches([System.IO.File]::ReadAllText($sp), 'TODO\(port\)')).Count }
            break
        }
        $lastError = (@(Get-Content -LiteralPath (Join-Path $workDir "BUILD_RESULT.txt") | Where-Object { $_ -match '^[^|#]+\|\d+\|' }) | Select-Object -First 1)
    }
    $state = if ($finalPass) { "builds" } else { "blocked" }
    Invoke-Skill (Join-Path $scripts "port-status.ps1") @("-WorkDir", $workDir, "-Unit", $unit, "-State", $state, "-Note", ("eval rounds=$rounds")) | Out-Null
    $rows += [pscustomobject]@{ unit = $unit; rounds = $rounds; firstTry = $firstTryPass; final = $finalPass; forbidden = $forbidden; todos = $todoCount; blockedByDep = $blockedByDep; modelFailed = $modelFailed; lastError = $lastError }
    Write-Host ("[{0}/{1}] {2}: {3} (rounds={4}, forbidden={5})" -f $unitIndex, $units.Count, $unit, $(if ($finalPass) { "PASS" } else { "FAIL" }), $rounds, $forbidden)
}

# 3. whole build + optional parity
$exe = Join-Path $OutputDirectory "out\app.exe"
$all = Invoke-Skill (Join-Path $scripts "build-check.ps1") @("-CppRoot", $cppRoot, "-All", "-Link", "-OutputExe", $exe, "-WorkDir", $workDir)
$linkOk = ($all.code -eq 0)
$parity = "not run"
if ($CsExe -and $CasesDir -and $linkOk) {
    $pc = Invoke-Skill (Join-Path $scripts "parity-check.ps1") @("-CsExe", $CsExe, "-CppExe", $exe, "-CasesDir", $CasesDir, "-WorkDir", $workDir)
    $parity = if ($pc.code -eq 0) { "PASS" } elseif ($pc.code -eq 1) { "FAIL" } else { "error: " + $pc.text }
}

# 4. RUN_SUMMARY.md (deterministic score)
$n = $rows.Count
$first = @($rows | Where-Object { $_.firstTry }).Count
$final = @($rows | Where-Object { $_.final }).Count
$forb = 0; $todos = 0; $byDep = 0
foreach ($r in $rows) { $forb += [int]$r.forbidden; $todos += [int]$r.todos; if ($r.blockedByDep) { $byDep++ } }
$md = @("# RUN_SUMMARY (csharp-to-cpp-port eval)", "",
    "- Source: $SourceRoot", "- Model: $(if ($SkipModel) { 'none (replay)' } else { "$Model @ $Endpoint" })", "- MaxRounds: $MaxRounds",
    "- Units: $n", "- First-try build pass: $first / $n", "- Final build pass: $final / $n", "- Forbidden-pattern errors (final files): $forb", "- TODO(port) markers in passing units: $todos", "- Units skipped because a dependency was blocked (not scored): $byDep",
    "- Whole-program link: $(if ($linkOk) { 'PASS' } else { 'FAIL' })", "- Parity: $parity", "",
    "| Unit | Rounds | First try | Final | Forbidden | TODO(port) | Last error |", "|------|--------|-----------|-------|-----------|------------|------------|")
foreach ($r in $rows) { $md += ("| ``{0}`` | {1} | {2} | {3} | {4} | {5} | {6} |" -f $r.unit, $r.rounds, $(if ($r.firstTry) { 'yes' } else { 'no' }), $(if ($r.final) { 'PASS' } elseif ($r.blockedByDep) { 'SKIP' } else { 'FAIL' }), $r.forbidden, $r.todos, ($r.lastError -replace '\|', '/' -replace '\r?\n', ' ')) }
$md += @("", "Score = final pass rate, then first-try rate, then fewer forbidden hits and fewer TODO(port) markers. One run is one sample: repeat 3 times per variant (temperature 0 is not fully deterministic on every server) and compare medians; adopt the candidate only when no metric regresses.")
[System.IO.File]::WriteAllText((Join-Path $OutputDirectory "RUN_SUMMARY.md"), (($md -join "`n") + "`n"), $utf8)
Write-Host "eval: final $final/$n, first-try $first/$n, forbidden=$forb, link=$(if ($linkOk) { 'PASS' } else { 'FAIL' }), parity=$parity"
Write-Host "  $OutputDirectory\RUN_SUMMARY.md"
if ($final -eq $n -and $linkOk) { exit 0 } else { exit 1 }
