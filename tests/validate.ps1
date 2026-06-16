param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
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
$openAiYamlPath = Join-Path $skillRoot "agents\openai.yaml"
$promptPath = Join-Path $skillRoot "references\model-agnostic-prompt.md"
$cliUsagePath = Join-Path $skillRoot "references\cli-usage.md"
$claudeCommandPath = Join-Path $RepositoryRoot "commands\diagsession-memory-analysis.md"
$claudePluginPath = Join-Path $RepositoryRoot ".claude-plugin\plugin.json"
$claudeMarketplacePath = Join-Path $RepositoryRoot ".claude-plugin\marketplace.json"

Assert-Condition (Test-Path -LiteralPath $skillPath) "Missing SKILL.md"
Assert-Condition (Test-Path -LiteralPath $scriptPath) "Missing extract script"
Assert-Condition (Test-Path -LiteralPath $openAiYamlPath) "Missing agents/openai.yaml"
Assert-Condition (Test-Path -LiteralPath $promptPath) "Missing model-agnostic prompt"
Assert-Condition (Test-Path -LiteralPath $cliUsagePath) "Missing CLI usage reference"
Assert-Condition (Test-Path -LiteralPath $claudeCommandPath) "Missing Claude command alias"
Assert-Condition (Test-Path -LiteralPath $claudePluginPath) "Missing Claude plugin manifest"
Assert-Condition (Test-Path -LiteralPath $claudeMarketplacePath) "Missing Claude marketplace manifest"

$frontMatter = Get-FrontMatter -Path $skillPath
Assert-Condition ($frontMatter -match "(?m)^name:\s*diagsession-memory-analysis\s*$") "Invalid skill name"
Assert-Condition ($frontMatter -match "(?m)^description:\s+.+") "Missing skill description"

$skillContent = Get-Content -Raw -LiteralPath $skillPath
Assert-Condition ($skillContent -match "## Default Behavior") "SKILL.md must define default behavior for short prompts"
Assert-Condition ($skillContent -match "analysis-only") "SKILL.md must keep the skill analysis-only"
Assert-Condition ($skillContent -match "handoff summary") "SKILL.md must require a follow-up handoff summary"
Assert-Condition ($skillContent -notmatch "## Validation") "Runtime SKILL.md should not include maintainer validation details"

$commandContent = Get-Content -Raw -LiteralPath $claudeCommandPath
Assert-Condition ($commandContent -match '\$ARGUMENTS') "Claude command alias must pass through arguments"
Assert-Condition ($commandContent -match "diagsession-memory-analysis") "Claude command alias must delegate to the skill"
Assert-Condition ($commandContent -match "Do not edit source code") "Claude command alias must preserve analysis-only scope"

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

Test-PowerShellSyntax -Path $scriptPath

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
foreach ($pattern in @("*.diagsession", "*.gcdump", "LLM_MEMORY_INPUT.txt", "MANIFEST.txt", "reports/", "extracted-gcdumps/")) {
    Assert-Condition ($gitIgnore -match [regex]::Escape($pattern)) "Missing .gitignore pattern: $pattern"
}

Write-Host "Validation passed."
