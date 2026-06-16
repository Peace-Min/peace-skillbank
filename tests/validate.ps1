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

Assert-Condition (Test-Path -LiteralPath $skillPath) "Missing SKILL.md"
Assert-Condition (Test-Path -LiteralPath $scriptPath) "Missing extract script"
Assert-Condition (Test-Path -LiteralPath $openAiYamlPath) "Missing agents/openai.yaml"
Assert-Condition (Test-Path -LiteralPath $promptPath) "Missing model-agnostic prompt"

$frontMatter = Get-FrontMatter -Path $skillPath
Assert-Condition ($frontMatter -match "(?m)^name:\s*diagsession-memory-analysis\s*$") "Invalid skill name"
Assert-Condition ($frontMatter -match "(?m)^description:\s+.+") "Missing skill description"

$openAiYaml = Get-Content -Raw -LiteralPath $openAiYamlPath
Assert-Condition ($openAiYaml -match 'display_name:\s*"DiagSession Memory Analysis"') "Missing display_name"
Assert-Condition ($openAiYaml -match 'default_prompt:\s*"Use \$diagsession-memory-analysis') "default_prompt must mention skill name"

$shortDescriptionMatch = [regex]::Match($openAiYaml, 'short_description:\s*"([^"]+)"')
Assert-Condition $shortDescriptionMatch.Success "Missing short_description"
$shortDescriptionLength = $shortDescriptionMatch.Groups[1].Value.Length
Assert-Condition ($shortDescriptionLength -ge 25 -and $shortDescriptionLength -le 64) "short_description must be 25-64 characters"

Test-PowerShellSyntax -Path $scriptPath

$gitIgnorePath = Join-Path $RepositoryRoot ".gitignore"
$gitIgnore = Get-Content -Raw -LiteralPath $gitIgnorePath
foreach ($pattern in @("*.diagsession", "*.gcdump", "LLM_MEMORY_INPUT.txt", "MANIFEST.txt", "reports/", "extracted-gcdumps/")) {
    Assert-Condition ($gitIgnore -match [regex]::Escape($pattern)) "Missing .gitignore pattern: $pattern"
}

Write-Host "Validation passed."
