param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [switch]$IncludeClrMdE2E,     # opt-in: also build+dump+run the ClrMD root-chain tool (needs .NET SDK; heavy)
    [switch]$IncludeSparrowE2E,   # opt-in: also build+run the Sparrow XLS export tool (needs .NET SDK + NPOI restore)
    [switch]$IncludeSyntaxFixE2E, # opt-in: also build+run the SparrowSyntaxFix rewriter tool (needs .NET SDK + Roslyn restore)
    [switch]$IncludeCommentE2E,   # opt-in: also build+run the SparrowCommentFix tool (needs .NET SDK + Roslyn restore)
    [switch]$IncludeSparrowLoopTests, # opt-in: also run the cross-rule loop/idempotency/compile tests (needs .NET SDK + Roslyn/WPF)
    [switch]$IncludeSparrowRealPatternTests, # opt-in: also run the grounded real-OSTES-pattern pipeline regression (needs .NET SDK + Roslyn)
    [switch]$IncludeSparrowRealXlsC3Tests, # opt-in: also run the real-xls C3 detect+fix regression (verbatim xls code; needs .NET SDK + Roslyn)
    [switch]$IncludeSparrowExhaustiveXls # opt-in: exhaustive Track A/B coverage over the REAL OSTES xls (needs .NET SDK + the xls in Downloads; self-skips if absent)
)

$ErrorActionPreference = "Stop"

function Assert-Condition {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Test-PowerShellSyntax {
    param([Parameter(Mandatory = $true)][string]$Path)

    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
    Assert-Condition ($errors.Count -eq 0) "PowerShell parse failed: $Path"
}

function Get-FrontMatter {
    param([Parameter(Mandatory = $true)][string]$Path)

    $content = Get-Content -Raw -LiteralPath $Path
    $match = [regex]::Match($content, "(?s)\A---\r?\n(.*?)\r?\n---")
    Assert-Condition $match.Success "Missing YAML frontmatter: $Path"
    return $match.Groups[1].Value
}

$skillRoot = Join-Path $RepositoryRoot "skills\diagsession-memory-analysis"
$skillPath = Join-Path $skillRoot "SKILL.md"
$scriptPath = Join-Path $skillRoot "scripts\extract-gcdump-reports.ps1"
$loopScriptPath = Join-Path $RepositoryRoot "tests\run-diagsession-analysis-loop.ps1"
$skillEvalLoopScriptPath = Join-Path $RepositoryRoot "tests\run-skill-eval-loop.ps1"
$responseValidatorPath = Join-Path $RepositoryRoot "tests\validate-diagsession-response.ps1"
$responseContractPath = Join-Path $RepositoryRoot "tests\diagsession-report-contract.ps1"
$openAiYamlPath = Join-Path $skillRoot "agents\openai.yaml"
$promptPath = Join-Path $skillRoot "references\model-agnostic-prompt.md"
$cliUsagePath = Join-Path $skillRoot "references\cli-usage.md"
$standardReportTemplatePath = Join-Path $skillRoot "references\standard-report-template.md"
$claudeCommandPath = Join-Path $RepositoryRoot "commands\diagsession-memory-analysis.md"
$claudeProjectDiagSkillPath = Join-Path $RepositoryRoot ".claude\skills\diagsession-memory-analysis\SKILL.md"
$claudeProjectLightningSkillPath = Join-Path $RepositoryRoot ".claude\skills\lightningchart-72\SKILL.md"
$humanUsagePath = Join-Path $RepositoryRoot "docs\diagsession-memory-analysis-usage.md"
$loopValidationDocPath = Join-Path $RepositoryRoot "docs\diagsession-loop-validation.md"
$claudePluginPath = Join-Path $RepositoryRoot ".claude-plugin\plugin.json"
$claudeMarketplacePath = Join-Path $RepositoryRoot ".claude-plugin\marketplace.json"

Assert-Condition (Test-Path -LiteralPath $skillPath) "Missing SKILL.md"
Assert-Condition (Test-Path -LiteralPath $scriptPath) "Missing extract script"
Assert-Condition (Test-Path -LiteralPath $loopScriptPath) "Missing diagsession loop test script"
Assert-Condition (Test-Path -LiteralPath $skillEvalLoopScriptPath) "Missing skill eval loop script"
Assert-Condition (Test-Path -LiteralPath $responseValidatorPath) "Missing response validator script"
Assert-Condition (Test-Path -LiteralPath $responseContractPath) "Missing response contract helper"
Assert-Condition (Test-Path -LiteralPath $openAiYamlPath) "Missing agents/openai.yaml"
Assert-Condition (Test-Path -LiteralPath $promptPath) "Missing model-agnostic prompt"
Assert-Condition (Test-Path -LiteralPath $cliUsagePath) "Missing CLI usage reference"
Assert-Condition (Test-Path -LiteralPath $standardReportTemplatePath) "Missing standard report template"
Assert-Condition (Test-Path -LiteralPath $claudeCommandPath) "Missing Claude command alias"
Assert-Condition (Test-Path -LiteralPath $claudeProjectDiagSkillPath) "Missing Claude project skill entrypoint for diagsession-memory-analysis"
Assert-Condition (Test-Path -LiteralPath $claudeProjectLightningSkillPath) "Missing Claude project skill entrypoint for lightningchart-72"
Assert-Condition (Test-Path -LiteralPath $humanUsagePath) "Missing human usage guide"
Assert-Condition (Test-Path -LiteralPath $loopValidationDocPath) "Missing loop validation guide"
Assert-Condition (Test-Path -LiteralPath $claudePluginPath) "Missing Claude plugin manifest"
Assert-Condition (Test-Path -LiteralPath $claudeMarketplacePath) "Missing Claude marketplace manifest"

$frontMatter = Get-FrontMatter -Path $skillPath
Assert-Condition ($frontMatter -match "(?m)^name:\s*diagsession-memory-analysis\s*$") "Invalid skill name"
Assert-Condition ($frontMatter -match "(?m)^description:\s+.+") "Missing skill description"

$extractScriptContent = Get-Content -Raw -LiteralPath $scriptPath
foreach ($manifestField in @("ArchiveIndex", "ArchiveEntryLastWriteTime", "ArchiveEntryLengthBytes", "GcdumpLengthBytes", "GcdumpRetention")) {
    Assert-Condition ($extractScriptContent -match [regex]::Escape($manifestField)) "Extract script must emit manifest/LLM metadata field: $manifestField"
}

$skillContent = Get-Content -Raw -Encoding UTF8 -LiteralPath $skillPath
Assert-Condition ($skillContent -match "## Default Behavior") "SKILL.md must define default behavior for short prompts"
Assert-Condition ($skillContent -match "analysis-only") "SKILL.md must keep the skill analysis-only"
Assert-Condition ($skillContent -match "handoff summary") "SKILL.md must require a follow-up handoff summary"
Assert-Condition ($skillContent -match "inventory analysis") "SKILL.md must allow single-snapshot inventory analysis"
Assert-Condition ($skillContent -notmatch "## Validation") "Runtime SKILL.md should not include maintainer validation details"
Assert-Condition ($skillContent -notmatch '[\u2010-\u2015]') "SKILL.md must avoid typographic dashes that break default Windows validation"

$commandContent = Get-Content -Raw -LiteralPath $claudeCommandPath
Assert-Condition ($commandContent -match '\$ARGUMENTS') "Claude command alias must pass through arguments"
Assert-Condition ($commandContent -match "diagsession-memory-analysis") "Claude command alias must delegate to the skill"
Assert-Condition ($commandContent -match "Do not edit source code") "Claude command alias must preserve analysis-only scope"

$projectDiagSkillContent = Get-Content -Raw -LiteralPath $claudeProjectDiagSkillPath
$projectLightningSkillContent = Get-Content -Raw -LiteralPath $claudeProjectLightningSkillPath
$projectDiagFrontMatter = Get-FrontMatter -Path $claudeProjectDiagSkillPath
$projectLightningFrontMatter = Get-FrontMatter -Path $claudeProjectLightningSkillPath
Assert-Condition ($projectDiagFrontMatter -match "(?m)^name:\s*diagsession-memory-analysis\s*$") "Claude project diagsession entrypoint must expose /diagsession-memory-analysis"
Assert-Condition ($projectLightningFrontMatter -match "(?m)^name:\s*lightningchart-72\s*$") "Claude project lightningchart entrypoint must expose /lightningchart-72"
Assert-Condition ($projectDiagSkillContent -match "skills/diagsession-memory-analysis/SKILL.md") "Claude project diagsession entrypoint must delegate to the canonical skill"
Assert-Condition ($projectDiagSkillContent -match "skills/diagsession-memory-analysis/") "Claude project diagsession entrypoint must point to bundled resources"
Assert-Condition ($projectLightningSkillContent -match "skills/lightningchart-72/SKILL.md") "Claude project lightningchart entrypoint must delegate to the canonical skill"
Assert-Condition ($projectLightningSkillContent -match "setup-local-corpus.ps1") "Claude project lightningchart entrypoint must mention corpus setup"

$readmePath = Join-Path $RepositoryRoot "README.md"
$readmeContent = Get-Content -Raw -LiteralPath $readmePath
$humanUsageContent = Get-Content -Raw -LiteralPath $humanUsagePath
Assert-Condition ($readmeContent -match [regex]::Escape("docs/diagsession-memory-analysis-usage.md")) "README must link the human usage guide"
Assert-Condition ($readmeContent -match [regex]::Escape(".claude/skills/")) "README must document clone-time Claude project skill discovery"
Assert-Condition ($readmeContent -match [regex]::Escape("/lightningchart-72")) "README must document clone-time lightningchart command"
Assert-Condition ($readmeContent.Contains('[`diagsession-memory-analysis`](docs/diagsession-memory-analysis-usage.md)')) "README current skill list must link each skill docs page"
Assert-Condition ($humanUsageContent -match [regex]::Escape("/diagsession-memory-analysis")) "Human usage guide must document the short Claude command"
Assert-Condition ($humanUsageContent -match "Snapshot 1") "Human usage guide must document snapshot ordering"
Assert-Condition ($humanUsageContent -match "analysis-only") "Human usage guide must state analysis-only scope"

$loopValidationDoc = Get-Content -Raw -LiteralPath $loopValidationDocPath
$standardReportTemplate = Get-Content -Raw -LiteralPath $standardReportTemplatePath
Assert-Condition ($loopValidationDoc -match [regex]::Escape("run-diagsession-analysis-loop.ps1")) "Loop validation guide must document the loop runner"
Assert-Condition ($loopValidationDoc -match [regex]::Escape("validate-diagsession-response.ps1")) "Loop validation guide must document the response validator"
Assert-Condition ($loopValidationDoc -match [regex]::Escape("extract/ANALYSIS.md")) "Loop validation guide must document the canonical analysis output"
Assert-Condition ($standardReportTemplate -match [regex]::Escape("## 8. Follow-up Fix Session Handoff")) "Standard report template must include handoff heading"

$skillEvalLoopContent = Get-Content -Raw -LiteralPath $skillEvalLoopScriptPath
Assert-Condition ($skillEvalLoopContent -notmatch '\[string\]\$ToolPath\s*=') "Skill eval loop must not force a default dotnet-gcdump ToolPath"
Assert-Condition ($skillEvalLoopContent -match "Refusing to remove OutputDirectory") "Skill eval loop must guard recursive output cleanup"

$openAiYaml = Get-Content -Raw -LiteralPath $openAiYamlPath
Assert-Condition ($openAiYaml -match 'display_name:\s*"DiagSession Memory Analysis"') "Missing display_name"
Assert-Condition ($openAiYaml -match 'default_prompt:\s*"Use \$diagsession-memory-analysis') "default_prompt must mention skill name"

$shortDescriptionMatch = [regex]::Match($openAiYaml, 'short_description:\s*"([^"]+)"')
Assert-Condition $shortDescriptionMatch.Success "Missing short_description"
$shortDescriptionLength = $shortDescriptionMatch.Groups[1].Value.Length
Assert-Condition ($shortDescriptionLength -ge 25 -and $shortDescriptionLength -le 64) "short_description must be 25-64 characters"

$claudePlugin = Get-Content -Raw -LiteralPath $claudePluginPath | ConvertFrom-Json
Assert-Condition ($claudePlugin.name -eq "peace-skillbank") "Invalid Claude plugin name"
Assert-Condition ($claudePlugin.license -eq "MIT") "Invalid Claude plugin license"
Assert-Condition ($claudePlugin.version -match '^\d+\.\d+\.\d+$') "Claude plugin version must be semver-like"

$claudeMarketplace = Get-Content -Raw -LiteralPath $claudeMarketplacePath | ConvertFrom-Json
Assert-Condition ($claudeMarketplace.name -eq "peace-skillbank") "Invalid Claude marketplace name"
Assert-Condition ($claudeMarketplace.metadata.description.Length -gt 0) "Claude marketplace description is required"
Assert-Condition ($claudeMarketplace.plugins.Count -ge 1) "Claude marketplace must list at least one plugin"
Assert-Condition ($claudeMarketplace.plugins[0].source -eq "./") "Claude marketplace plugin should source the repository root"
Assert-Condition ($claudeMarketplace.plugins[0].version -eq $claudePlugin.version) "Marketplace version must match plugin version"
Assert-Condition ($claudeMarketplace.plugins[0].name -eq $claudePlugin.name) "Marketplace plugin name must match plugin manifest name"
Assert-Condition ($claudeMarketplace.plugins[0].description -eq $claudePlugin.description) "Marketplace plugin description must stay in sync with plugin manifest"
Assert-Condition ($claudeMarketplace.plugins[0].license -eq $claudePlugin.license) "Marketplace plugin license must match plugin manifest"
Assert-Condition ($claudeMarketplace.plugins[0].repository -eq $claudePlugin.repository) "Marketplace plugin repository must match plugin manifest"

foreach ($powershellScriptPath in @($scriptPath, $loopScriptPath, $skillEvalLoopScriptPath, $responseValidatorPath, $responseContractPath, (Join-Path $RepositoryRoot "tests\build-fixture.ps1"))) {
    Test-PowerShellSyntax -Path $powershellScriptPath
}

# Behavioral fixtures for diagsession extraction + report contract (synthetic .diagsession; no tool needed).
$diagFixtures = Join-Path $RepositoryRoot "tests\diagsession-fixtures.ps1"
Assert-Condition (Test-Path -LiteralPath $diagFixtures) "Missing diagsession fixture runner"
Test-PowerShellSyntax -Path $diagFixtures
& $diagFixtures -RepositoryRoot $RepositoryRoot

# Behavioral fixtures for the #29 root-cause enrichment (candidate selection + native boundary +
# graceful fallback; the ClrMD root-chain stage needs a local dump and is dev-tested separately).
$rcFixtures = Join-Path $RepositoryRoot "tests\diagsession-rootchain-fixtures.ps1"
Assert-Condition (Test-Path -LiteralPath $rcFixtures) "Missing diagsession-rootchain fixture runner"
Test-PowerShellSyntax -Path $rcFixtures
& $rcFixtures -RepositoryRoot $RepositoryRoot

# Offline gate for the #29 A/B eval scorer (deterministic canned answers; no dump/tool/Ollama).
$rcEvalFixtures = Join-Path $RepositoryRoot "tests\rootchain-eval-fixtures.ps1"
Assert-Condition (Test-Path -LiteralPath $rcEvalFixtures) "Missing rootchain-eval scorer fixture runner"
Test-PowerShellSyntax -Path $rcEvalFixtures
& $rcEvalFixtures -RepositoryRoot $RepositoryRoot

# ClrMD root-chain E2E (#35): always syntax-check; only RUN when opted in (builds + dumps; needs the SDK).
$clrmdE2E = Join-Path $RepositoryRoot "tests\diagsession-clrmd-e2e.ps1"
Assert-Condition (Test-Path -LiteralPath $clrmdE2E) "Missing ClrMD E2E smoke test"
Test-PowerShellSyntax -Path $clrmdE2E
if ($IncludeClrMdE2E) { & $clrmdE2E -RepositoryRoot $RepositoryRoot }

# Sparrow XLS export E2E: always syntax-check + assert the tool/fixture projects exist; only RUN when
# opted in (builds + restores NPOI; needs the SDK). Mirrors the ClrMD E2E wiring above.
$sparrowToolProj = Join-Path $RepositoryRoot "skills\sparrow-static-analysis\tools\SparrowXlsExport\SparrowXlsExport.csproj"
$sparrowToolProgram = Join-Path $RepositoryRoot "skills\sparrow-static-analysis\tools\SparrowXlsExport\Program.cs"
$sparrowFixtureProj = Join-Path $RepositoryRoot "skills\sparrow-static-analysis\tools\SparrowXlsExport\FixtureGen\FixtureGen.csproj"
$sparrowFixtureProgram = Join-Path $RepositoryRoot "skills\sparrow-static-analysis\tools\SparrowXlsExport\FixtureGen\Program.cs"
$sparrowE2E = Join-Path $RepositoryRoot "tests\sparrow-xlsexport-fixtures.ps1"
foreach ($sparrowFile in @($sparrowToolProj, $sparrowToolProgram, $sparrowFixtureProj, $sparrowFixtureProgram, $sparrowE2E)) {
    Assert-Condition (Test-Path -LiteralPath $sparrowFile) "Missing Sparrow XLS export file: $sparrowFile"
}
Test-PowerShellSyntax -Path $sparrowE2E
if ($IncludeSparrowE2E) { & $sparrowE2E -RepositoryRoot $RepositoryRoot }

# SparrowSyntaxFix E2E: always syntax-check + assert the tool/fixture projects exist; only RUN when opted
# in (builds + restores Roslyn; needs the SDK). Mirrors the Sparrow XLS export wiring above.
$syntaxToolProj = Join-Path $RepositoryRoot "skills\sparrow-static-analysis\tools\SparrowSyntaxFix\SparrowSyntaxFix.csproj"
$syntaxToolProgram = Join-Path $RepositoryRoot "skills\sparrow-static-analysis\tools\SparrowSyntaxFix\Program.cs"
$syntaxEngine = Join-Path $RepositoryRoot "skills\sparrow-static-analysis\tools\SparrowSyntaxFix\RewriteEngine.cs"
$syntaxNullCast = Join-Path $RepositoryRoot "skills\sparrow-static-analysis\tools\SparrowSyntaxFix\NullCastRewriter.cs"
$syntaxNullVar = Join-Path $RepositoryRoot "skills\sparrow-static-analysis\tools\SparrowSyntaxFix\NullVarRewriter.cs"
$syntaxVarHelpers = Join-Path $RepositoryRoot "skills\sparrow-static-analysis\tools\SparrowSyntaxFix\VarRewriteHelpers.cs"
$syntaxObjectVar = Join-Path $RepositoryRoot "skills\sparrow-static-analysis\tools\SparrowSyntaxFix\ObjectVarRewriter.cs"
$syntaxObjectInitializer = Join-Path $RepositoryRoot "skills\sparrow-static-analysis\tools\SparrowSyntaxFix\ObjectInitializerRewriter.cs"
$syntaxArrayVar = Join-Path $RepositoryRoot "skills\sparrow-static-analysis\tools\SparrowSyntaxFix\ArrayVarRewriter.cs"
$syntaxForeachCast = Join-Path $RepositoryRoot "skills\sparrow-static-analysis\tools\SparrowSyntaxFix\ForeachCastRewriter.cs"
$syntaxObviousVar = Join-Path $RepositoryRoot "skills\sparrow-static-analysis\tools\SparrowSyntaxFix\ObviousVarRewriter.cs"
$syntaxLocalConst = Join-Path $RepositoryRoot "skills\sparrow-static-analysis\tools\SparrowSyntaxFix\LocalConstRewriter.cs"
$syntaxParens = Join-Path $RepositoryRoot "skills\sparrow-static-analysis\tools\SparrowSyntaxFix\ParensRewriter.cs"
$syntaxReadme = Join-Path $RepositoryRoot "skills\sparrow-static-analysis\tools\SparrowSyntaxFix\README.md"
$syntaxFixtureProj = Join-Path $RepositoryRoot "skills\sparrow-static-analysis\tools\SparrowSyntaxFix\FixtureTests\FixtureTests.csproj"
$syntaxFixtureProgram = Join-Path $RepositoryRoot "skills\sparrow-static-analysis\tools\SparrowSyntaxFix\FixtureTests\Program.cs"
$syntaxE2E = Join-Path $RepositoryRoot "tests\sparrow-syntaxfix-fixtures.ps1"
foreach ($syntaxFile in @($syntaxToolProj, $syntaxToolProgram, $syntaxEngine, $syntaxNullCast, $syntaxNullVar, $syntaxVarHelpers, $syntaxObjectVar, $syntaxObjectInitializer, $syntaxArrayVar, $syntaxForeachCast, $syntaxObviousVar, $syntaxLocalConst, $syntaxParens, $syntaxReadme, $syntaxFixtureProj, $syntaxFixtureProgram, $syntaxE2E)) {
    Assert-Condition (Test-Path -LiteralPath $syntaxFile) "Missing SparrowSyntaxFix file: $syntaxFile"
}
Test-PowerShellSyntax -Path $syntaxE2E
if ($IncludeSyntaxFixE2E) { & $syntaxE2E -RepositoryRoot $RepositoryRoot }

# SparrowCommentFix E2E (Track B): always syntax-check + assert the tool/program/fixtures files exist; only
# RUN when opted in (builds + restores Roslyn; needs the SDK). Mirrors the Sparrow XLS export wiring above.
$commentToolProj = Join-Path $RepositoryRoot "skills\sparrow-static-analysis\tools\SparrowCommentFix\SparrowCommentFix.csproj"
$commentToolProgram = Join-Path $RepositoryRoot "skills\sparrow-static-analysis\tools\SparrowCommentFix\Program.cs"
$commentE2E = Join-Path $RepositoryRoot "tests\sparrow-commentfix-fixtures.ps1"
foreach ($commentFile in @($commentToolProj, $commentToolProgram, $commentE2E)) {
    Assert-Condition (Test-Path -LiteralPath $commentFile) "Missing SparrowCommentFix file: $commentFile"
}
Test-PowerShellSyntax -Path $commentE2E
if ($IncludeCommentE2E) { & $commentE2E -RepositoryRoot $RepositoryRoot }

# Sparrow cross-rule loop/idempotency/compile tests ("충분한 루프 테스트"): always syntax-check + assert the
# script exists; only RUN when opted in (builds both tools + WPF/System.Data compile checks; needs the SDK).
$sparrowLoop = Join-Path $RepositoryRoot "tests\sparrow-loop-tests.ps1"
Assert-Condition (Test-Path -LiteralPath $sparrowLoop) "Missing Sparrow loop test script"
Test-PowerShellSyntax -Path $sparrowLoop
if ($IncludeSparrowLoopTests) { & $sparrowLoop -RepositoryRoot $RepositoryRoot }

# Sparrow grounded real-OSTES-pattern pipeline regression: seed ONE compilable net8.0 file with the real xls
# shapes, run the full Track A/B pipeline, assert 0-errors before/after + convergence + per-pattern transforms.
# Always syntax-check + assert existence; only RUN when opted in (builds both tools + compiles; needs the SDK).
$sparrowRealPattern = Join-Path $RepositoryRoot "tests\sparrow-realpattern-tests.ps1"
Assert-Condition (Test-Path -LiteralPath $sparrowRealPattern) "Missing Sparrow real-pattern test script"
Test-PowerShellSyntax -Path $sparrowRealPattern
if ($IncludeSparrowRealPatternTests) { & $sparrowRealPattern -RepositoryRoot $RepositoryRoot }

# Sparrow real-xls C3 regression: fixtures embed the EXACT xls-detected source (verbatim, prefix stripped) for the
# five v0.1.50 C3 rules; assert BOTH detection (rule fires -> positive edit count) AND remediation (correct
# transform + parses clean + idempotent). Always syntax-check + assert existence; only RUN when opted in.
$sparrowRealXlsC3 = Join-Path $RepositoryRoot "tests\sparrow-realxls-c3-tests.ps1"
Assert-Condition (Test-Path -LiteralPath $sparrowRealXlsC3) "Missing Sparrow real-xls C3 test script"
Test-PowerShellSyntax -Path $sparrowRealXlsC3
if ($IncludeSparrowRealXlsC3Tests) { & $sparrowRealXlsC3 -RepositoryRoot $RepositoryRoot }

# EXHAUSTIVE Sparrow Track A/B xls coverage: extract the REAL flagged code of EVERY Track A/B finding in the
# OSTES issues .xls, generate a parseable snippet for each, run the matching tool+rule over all of them, and
# report per-finding transformed vs not-transformed. Always syntax-check + assert the runner/generator exist;
# only RUN when opted in. The runner ITSELF self-skips (does not fail) when the .xls is absent from Downloads,
# so it never breaks a normal gate run and never requires the (uncommitted) xls to be present.
$sparrowExhaustive = Join-Path $RepositoryRoot "tests\sparrow-exhaustive-xls-test.ps1"
$sparrowExhaustiveProj = Join-Path $RepositoryRoot "tests\SparrowExhaustiveXls\SparrowExhaustiveXls.csproj"
$sparrowExhaustiveProgram = Join-Path $RepositoryRoot "tests\SparrowExhaustiveXls\Program.cs"
foreach ($exhFile in @($sparrowExhaustive, $sparrowExhaustiveProj, $sparrowExhaustiveProgram)) {
    Assert-Condition (Test-Path -LiteralPath $exhFile) "Missing exhaustive Sparrow xls file: $exhFile"
}
Test-PowerShellSyntax -Path $sparrowExhaustive
if ($IncludeSparrowExhaustiveXls) { & $sparrowExhaustive -RepositoryRoot $RepositoryRoot }

# Track A auto-fix kit (LLM-free): assert the .editorconfig + runner exist and the runner parses.
# (Run-TrackA.ps1 carries Korean text -> must stay UTF-8-with-BOM or PS 5.1 mis-parses it.)
$trackAEditorConfig = Join-Path $RepositoryRoot "skills\sparrow-static-analysis\references\bucket1-autofix.editorconfig"
$trackARunner = Join-Path $RepositoryRoot "skills\sparrow-static-analysis\references\Run-TrackA.ps1"
Assert-Condition (Test-Path -LiteralPath $trackAEditorConfig) "Missing Track A .editorconfig template"
Assert-Condition (Test-Path -LiteralPath $trackARunner) "Missing Track A runner Run-TrackA.ps1"
Test-PowerShellSyntax -Path $trackARunner

# SparrowCommentFix one-call runner (Track B): assert it exists + parses. Like Run-TrackA.ps1 it carries
# Korean text -> must stay UTF-8-with-BOM or PS 5.1 mis-parses it.
$commentRunner = Join-Path $RepositoryRoot "skills\sparrow-static-analysis\tools\SparrowCommentFix\Run-SparrowCommentFix.ps1"
Assert-Condition (Test-Path -LiteralPath $commentRunner) "Missing SparrowCommentFix runner Run-SparrowCommentFix.ps1"
Test-PowerShellSyntax -Path $commentRunner

$claude = Get-Command claude -ErrorAction SilentlyContinue
if ($claude) {
    Push-Location $RepositoryRoot
    try {
        & $claude.Source plugin validate . | Out-Host
        Assert-Condition ($LASTEXITCODE -eq 0) "Claude plugin marketplace validation failed"

        & $claude.Source plugin validate $claudePluginPath | Out-Host
        Assert-Condition ($LASTEXITCODE -eq 0) "Claude plugin manifest validation failed"
    }
    finally {
        Pop-Location
    }
}
else {
    Write-Host "Claude CLI not found; skipping Claude plugin validation."
}

$gitIgnorePath = Join-Path $RepositoryRoot ".gitignore"
$gitIgnore = Get-Content -Raw -LiteralPath $gitIgnorePath
foreach ($pattern in @("*.diagsession", "*.gcdump", "*.heapstat.txt", "*.log", "LLM_MEMORY_INPUT.txt", "MANIFEST.txt", "reports/", "extracted-gcdumps/", "out/", "LLM_REQUEST.md", "ANALYSIS.md", "MODEL_RESPONSE.md", "MODEL_RESPONSE.stderr.txt", "RUN_SUMMARY.md", "RESPONSE_VALIDATION.md")) {
    Assert-Condition ($gitIgnore -match [regex]::Escape($pattern)) "Missing .gitignore pattern: $pattern"
}

# --- lightningchart-72 skill (machinery only; licensed corpus stays local) ---
$lcRoot = Join-Path $RepositoryRoot "skills\lightningchart-72"
$lcSkillPath = Join-Path $lcRoot "SKILL.md"
$lcApiIndexScript = Join-Path $lcRoot "scripts\build-api-index.ps1"
foreach ($lcFile in @(
        $lcSkillPath,
        (Join-Path $lcRoot "README.md"),
        (Join-Path $lcRoot "references\README.md"),
        (Join-Path $lcRoot "references\demos\README.md"),
        $lcApiIndexScript,
        (Join-Path $lcRoot "agents\openai.yaml"),
        (Join-Path $lcRoot "scripts\setup-local-corpus.ps1"),
        (Join-Path $lcRoot "scripts\build-manual-index.py"),
        (Join-Path $lcRoot "scripts\verify-symbols.py"),
        (Join-Path $lcRoot "scripts\search.py"))) {
    Assert-Condition (Test-Path -LiteralPath $lcFile) "Missing lightningchart-72 file: $lcFile"
}

$lcFrontMatter = Get-FrontMatter -Path $lcSkillPath
Assert-Condition ($lcFrontMatter -match "(?m)^name:\s*lightningchart-72\s*$") "Invalid lightningchart-72 skill name"
Assert-Condition ($lcFrontMatter -match "(?m)^description:\s+.+") "Missing lightningchart-72 skill description"

$lcSkillContent = Get-Content -Raw -Encoding UTF8 -LiteralPath $lcSkillPath
$lcTypographicDashes = @([char]0x2010, [char]0x2011, [char]0x2012, [char]0x2013, [char]0x2014, [char]0x2015)
Assert-Condition (-not ($lcTypographicDashes | Where-Object { $lcSkillContent.Contains($_) })) "lightningchart-72 SKILL.md must avoid typographic dashes that break default Windows validation"
foreach ($marker in @("verify-symbols", "Tier 1", "Type.Member", "not found")) {
    Assert-Condition ($lcSkillContent -match [regex]::Escape($marker)) "lightningchart-72 SKILL.md must keep grounding-contract marker: $marker"
}

# Enforcement-honesty: the verification step is an AGENT-RUN script, not an automatic Claude Code
# hook (this repo ships no hook). Forbid the misleading "verify hook" label and require the honest
# "agent-run" framing so the contract never silently reverts to implying harness enforcement.
Assert-Condition ($lcSkillContent -notmatch "(?i)verify hook") "lightningchart-72 SKILL.md must not call the verify script a 'verify hook' (it is agent-run, not a harness hook)"
Assert-Condition ($lcSkillContent -match "agent-run") "lightningchart-72 SKILL.md must state the verify step is agent-run (not a harness hook)"

Test-PowerShellSyntax -Path $lcApiIndexScript
Test-PowerShellSyntax -Path (Join-Path $lcRoot "scripts\setup-local-corpus.ps1")

$python = Get-Command python -ErrorAction SilentlyContinue
if ($python) {
    foreach ($lcPy in @("build-manual-index.py", "verify-symbols.py", "search.py")) {
        # ast.parse is a syntax check that does not write __pycache__ bytecode.
        & $python.Source -c "import ast,sys; ast.parse(open(sys.argv[1], encoding='utf-8').read())" (Join-Path $lcRoot "scripts\$lcPy")
        Assert-Condition ($LASTEXITCODE -eq 0) "Python syntax error in lightningchart-72 script: $lcPy"
    }
}
else {
    Write-Host "Python not found; skipping lightningchart-72 Python syntax checks."
}

# Behavioral fixtures for the verify-symbols hook (synthetic index; self-skips without Python).
$lcVerifyFixtures = Join-Path $RepositoryRoot "tests\verify-symbols-fixtures.ps1"
$lcVerifyFixtureIndex = Join-Path $RepositoryRoot "tests\fixtures\lightningchart-72\api-index.json"
Assert-Condition (Test-Path -LiteralPath $lcVerifyFixtures) "Missing verify-symbols fixture runner"
Assert-Condition (Test-Path -LiteralPath $lcVerifyFixtureIndex) "Missing synthetic verify-symbols fixture index"
Test-PowerShellSyntax -Path $lcVerifyFixtures
& $lcVerifyFixtures -RepositoryRoot $RepositoryRoot

# Behavioral fixtures for the one-command corpus setup CLI (preflight/auto-detect/fail-fast paths).
$lcSetupFixtures = Join-Path $RepositoryRoot "tests\setup-corpus-fixtures.ps1"
Assert-Condition (Test-Path -LiteralPath $lcSetupFixtures) "Missing setup-corpus fixture runner"
Test-PowerShellSyntax -Path $lcSetupFixtures
& $lcSetupFixtures -RepositoryRoot $RepositoryRoot

foreach ($lcPattern in @("skills/lightningchart-72/references/manual/", "skills/lightningchart-72/references/manual-index.json", "skills/lightningchart-72/references/api-index.json", "skills/lightningchart-72/references/api-symbols.txt", "skills/lightningchart-72/references/demos/*", "*.dll")) {
    Assert-Condition ($gitIgnore -match [regex]::Escape($lcPattern)) "Missing .gitignore pattern: $lcPattern"
}

$lcUsageDoc = Join-Path $RepositoryRoot "docs\lightningchart-72-usage.md"
Assert-Condition (Test-Path -LiteralPath $lcUsageDoc) "Missing lightningchart-72 usage guide (docs/lightningchart-72-usage.md)"
Assert-Condition ($readmeContent.Contains('[`lightningchart-72`](docs/lightningchart-72-usage.md)')) "README current-skill list must link the lightningchart-72 usage guide"

$lcCommandPath = Join-Path $RepositoryRoot "commands\lightningchart-72.md"
Assert-Condition (Test-Path -LiteralPath $lcCommandPath) "Missing lightningchart-72 Claude command alias"
$lcCommandContent = Get-Content -Raw -LiteralPath $lcCommandPath
Assert-Condition ($lcCommandContent -match '\$ARGUMENTS') "lightningchart-72 command alias must pass through arguments"
Assert-Condition ($lcCommandContent -match "lightningchart-72") "lightningchart-72 command alias must delegate to the skill"

$lcOpenAiYaml = Get-Content -Raw -LiteralPath (Join-Path $lcRoot "agents\openai.yaml")
Assert-Condition ($lcOpenAiYaml -match 'display_name:\s*"[^"]+"') "lightningchart-72 openai.yaml needs a display_name"
Assert-Condition ($lcOpenAiYaml -match 'default_prompt:\s*"Use \$lightningchart-72') "lightningchart-72 openai.yaml default_prompt must mention the skill name"
$lcShort = [regex]::Match($lcOpenAiYaml, 'short_description:\s*"([^"]+)"')
Assert-Condition $lcShort.Success "lightningchart-72 openai.yaml needs a short_description"
Assert-Condition ($lcShort.Groups[1].Value.Length -ge 25 -and $lcShort.Groups[1].Value.Length -le 64) "lightningchart-72 short_description must be 25-64 characters"

# --- frontier-handoff skill (offline -> frontier handoff prompt builder; machinery only) ---
$fhRoot = Join-Path $RepositoryRoot "skills\frontier-handoff"
$fhSkillPath = Join-Path $fhRoot "SKILL.md"
$fhFinalize = Join-Path $fhRoot "scripts\finalize-handoff.py"
$fhOpenAi = Join-Path $fhRoot "agents\openai.yaml"
$fhEvals = Join-Path $fhRoot "evals\evals.json"
$fhReadme = Join-Path $fhRoot "README.md"
$fhUsageDoc = Join-Path $RepositoryRoot "docs\frontier-handoff-usage.md"
$fhProjectEntry = Join-Path $RepositoryRoot ".claude\skills\frontier-handoff\SKILL.md"
$fhCommand = Join-Path $RepositoryRoot "commands\frontier-handoff.md"
foreach ($fhFile in @($fhSkillPath, $fhFinalize, $fhOpenAi, $fhEvals, $fhReadme, $fhUsageDoc, $fhProjectEntry, $fhCommand)) {
    Assert-Condition (Test-Path -LiteralPath $fhFile) "Missing frontier-handoff file: $fhFile"
}

# Short-command alias must exist at parity with the other two skills, pass $ARGUMENTS, and delegate.
$fhCommandContent = Get-Content -Raw -LiteralPath $fhCommand
Assert-Condition ($fhCommandContent -match [regex]::Escape('$ARGUMENTS')) "commands/frontier-handoff.md must pass `$ARGUMENTS to the skill"
Assert-Condition ($fhCommandContent -match "finalize-handoff.py") "commands/frontier-handoff.md must reference the finalize script"

# Canonical SKILL.md frontmatter -- catches an unclosed/invalid frontmatter that breaks discovery.
$fhFrontMatter = Get-FrontMatter -Path $fhSkillPath
Assert-Condition ($fhFrontMatter -match "(?m)^name:\s*frontier-handoff\s*$") "Invalid frontier-handoff skill name / unclosed frontmatter"
Assert-Condition ($fhFrontMatter -match "(?m)^description:\s+.+") "Missing frontier-handoff skill description"

# Clone-time project-skill entrypoint must exist, be valid, and delegate to the canonical skill + script.
$fhProjectFront = Get-FrontMatter -Path $fhProjectEntry
Assert-Condition ($fhProjectFront -match "(?m)^name:\s*frontier-handoff\s*$") "frontier-handoff project entrypoint must expose /frontier-handoff"
$fhProjectContent = Get-Content -Raw -LiteralPath $fhProjectEntry
Assert-Condition ($fhProjectContent -match "skills/frontier-handoff/SKILL.md") "frontier-handoff project entrypoint must delegate to the canonical skill"
Assert-Condition ($fhProjectContent -match "finalize-handoff.py") "frontier-handoff project entrypoint must reference the finalize script"
Assert-Condition ($readmeContent -match [regex]::Escape("/frontier-handoff")) "README clone-time list must include /frontier-handoff"
Assert-Condition ($readmeContent.Contains('[`frontier-handoff`](docs/frontier-handoff-usage.md)')) "README current-skill list must link the frontier-handoff usage guide"

# openai.yaml metadata.
$fhOpenAiContent = Get-Content -Raw -LiteralPath $fhOpenAi
Assert-Condition ($fhOpenAiContent -match 'display_name:\s*"[^"]+"') "frontier-handoff openai.yaml needs a display_name"
Assert-Condition ($fhOpenAiContent -match 'default_prompt:\s*"Use \$frontier-handoff') "frontier-handoff openai.yaml default_prompt must mention the skill name"
$fhShort = [regex]::Match($fhOpenAiContent, 'short_description:\s*"([^"]+)"')
Assert-Condition $fhShort.Success "frontier-handoff openai.yaml needs a short_description"
Assert-Condition ($fhShort.Groups[1].Value.Length -ge 25 -and $fhShort.Groups[1].Value.Length -le 64) "frontier-handoff short_description must be 25-64 characters"

# Policy: the canonical skill must NOT claim automatic secret masking (it was removed by design).
$fhSkillContent = Get-Content -Raw -Encoding UTF8 -LiteralPath $fhSkillPath
Assert-Condition ($fhSkillContent -notmatch "(?i)mask") "frontier-handoff SKILL.md must not claim secret masking"

# Quality rules from real-world handoff feedback (keep the two adopted improvements from drifting out):
#  - the core function must be collected in FULL, not elided;
#  - an observed/measured symptom must carry its measurement methodology (how / how many runs).
Assert-Condition ($fhSkillContent -match "(?i)at the heart of the problem must appear in FULL") "frontier-handoff SKILL.md must require the core function in full (no elision)"
Assert-Condition ($fhSkillContent -match "(?i)how it was measured and over how many runs") "frontier-handoff SKILL.md must require measurement methodology for observed/measured symptoms"
# A pre-finalize self-check turns the "core function in full" rule from an aspiration into a checked step.
Assert-Condition ($fhSkillContent -match "(?i)before finalizing, re-read") "frontier-handoff SKILL.md must keep the pre-finalize completeness self-check"

# finalize-handoff.py: syntax + behavior (appends the directive once; no duplicate on a second pass).
if ($python) {
    & $python.Source -c "import ast,sys; ast.parse(open(sys.argv[1], encoding='utf-8').read())" $fhFinalize
    Assert-Condition ($LASTEXITCODE -eq 0) "Python syntax error in finalize-handoff.py"

    $fhTmp = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($fhTmp, "## Goal`nx`n## Ask`ny", (New-Object System.Text.UTF8Encoding($false)))
        $fhOut1 = (& $python.Source $fhFinalize $fhTmp | Out-String)
        Assert-Condition ($fhOut1 -match "How to answer \(the implementer is a weak offline model\)") "finalize-handoff.py must append the mandatory response directive"
        [System.IO.File]::WriteAllText($fhTmp, $fhOut1, (New-Object System.Text.UTF8Encoding($false)))
        $fhOut2 = (& $python.Source $fhFinalize $fhTmp | Out-String)
        $fhDirCount = ([regex]::Matches($fhOut2, "How to answer \(the implementer is a weak offline model\)")).Count
        Assert-Condition ($fhDirCount -eq 1) "finalize-handoff.py must not duplicate the directive on a second pass"

        # Dedup must be anchored to the heading LINE: a draft that merely *mentions* the directive
        # title in prose must still get the directive appended (the heading must not be suppressed
        # by a bare substring match).
        $fhProse = "## Problem`nthe model keeps ignoring the How to answer (the implementer is a weak offline model) section.`n## Ask`nhelp"
        [System.IO.File]::WriteAllText($fhTmp, $fhProse, (New-Object System.Text.UTF8Encoding($false)))
        $fhOut3 = (& $python.Source $fhFinalize $fhTmp | Out-String)
        $fhHeadingCount = ([regex]::Matches($fhOut3, "(?m)^## How to answer \(the implementer is a weak offline model\)")).Count
        Assert-Condition ($fhHeadingCount -eq 1) "finalize-handoff.py must still append the directive when the draft only mentions its title in prose"
    }
    finally {
        Remove-Item -LiteralPath $fhTmp -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Validation passed."
