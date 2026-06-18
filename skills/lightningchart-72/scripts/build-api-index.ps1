<#
.SYNOPSIS
  Extract the public API surface of the LightningChart (Arction) 7.2 assemblies into
  a local, gitignored api-index.json + api-symbols.txt (Tier 1 = existence/signature).

.NOTES
  - Reads ONLY public type/member NAMES + signatures via reflection. No constants,
    field values, or license data are read. The Arction.Licensing assembly is skipped.
  - The DLL directory is a PARAMETER. Nothing here hardcodes a machine path, and the
    DLLs / generated index are never committed (see repo .gitignore).
  - One-time, local. The runtime (search/verify) only reads the JSON; no .NET needed then.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File build-api-index.ps1 -DllDir "D:\path\to\Lib\Arction"
#>
param(
    [Parameter(Mandatory = $true)][string]$DllDir,
    [string]$MainDll,
    [string]$OutDir
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path -LiteralPath $DllDir)) { throw "DllDir not found: $DllDir" }
if (-not $OutDir) { $OutDir = Join-Path (Split-Path -Parent $PSScriptRoot) "references" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# Resolve sibling assemblies from the same folder (never the licensing assembly's members).
$resolveDir = (Resolve-Path -LiteralPath $DllDir).Path
$handler = [System.ResolveEventHandler] {
    param($sender, $e)
    $name = (New-Object System.Reflection.AssemblyName($e.Name)).Name
    if ($name -eq "Arction.Licensing") { return $null }
    $candidate = Join-Path $resolveDir "$name.dll"
    if (Test-Path -LiteralPath $candidate) { return [System.Reflection.Assembly]::LoadFrom($candidate) }
    return $null
}
[System.AppDomain]::CurrentDomain.add_AssemblyResolve($handler)

# Auto-detect the main charting assembly so a differently-named edition (e.g. WinForms) still works,
# rather than failing on a hardcoded default.
if (-not $MainDll) {
    $autoMain = Get-ChildItem -LiteralPath $resolveDir -Filter "*LightningChartUltimate*.dll" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $autoMain) {
        $present = (Get-ChildItem -LiteralPath $resolveDir -Filter "*.dll" -ErrorAction SilentlyContinue).Name -join ", "
        throw "No *LightningChartUltimate*.dll found in $resolveDir. Pass -MainDll explicitly. DLLs present: $present"
    }
    $MainDll = $autoMain.Name
}
$mainPath = Join-Path $resolveDir $MainDll
if (-not (Test-Path -LiteralPath $mainPath)) { throw "Main DLL not found: $mainPath" }
$asm = [System.Reflection.Assembly]::LoadFrom($mainPath)
$asmVersion = $asm.GetName().Version.ToString()

try { $types = $asm.GetExportedTypes() }
catch [System.Reflection.ReflectionTypeLoadException] { $types = $_.Exception.Types | Where-Object { $_ } }

function Get-Kind($t) {
    if ($t.IsEnum) { "enum" } elseif ($t.IsInterface) { "interface" }
    elseif ($t.IsValueType) { "struct" } else { "class" }
}

$objectMethods = @("ToString", "Equals", "GetHashCode", "GetType")
$out = New-Object System.Collections.Generic.List[object]

foreach ($t in $types) {
    if (-not $t.Namespace) { continue }
    if ($t.Namespace -like "*Licensing*") { continue }
    # Reflection renders generic type names as "Name`N" (e.g. EventArgs`2); the model cites
    # them without the backtick arity, so strip it for grep/verify-friendly symbols.
    $rec = [ordered]@{ ns = $t.Namespace; name = ($t.Name -replace '`\d+$', ''); kind = (Get-Kind $t) }
    try { if ($t.BaseType -and $t.BaseType.Name -ne "Object") { $rec.base = $t.BaseType.Name } } catch {}

    if ($t.IsEnum) {
        try { $rec.values = @($t.GetEnumNames()) } catch { $rec.values = @() }
    }
    else {
        $props = New-Object System.Collections.Generic.List[object]
        try {
            foreach ($p in $t.GetProperties()) {
                $props.Add([ordered]@{ n = $p.Name; t = $p.PropertyType.Name })
            }
        } catch {}
        $rec.props = $props

        $methods = New-Object System.Collections.Generic.List[object]
        try {
            foreach ($m in $t.GetMethods()) {
                if ($m.IsSpecialName) { continue }                       # get_/set_/add_/op_
                if ($objectMethods -contains $m.Name) { continue }
                $params = @($m.GetParameters() | ForEach-Object { [ordered]@{ n = $_.Name; t = $_.ParameterType.Name } })
                $methods.Add([ordered]@{ n = $m.Name; ret = $m.ReturnType.Name; params = $params })
            }
        } catch {}
        $rec.methods = $methods

        $ctors = New-Object System.Collections.Generic.List[object]
        try {
            foreach ($c in $t.GetConstructors()) {
                $cparams = @($c.GetParameters() | ForEach-Object { [ordered]@{ n = $_.Name; t = $_.ParameterType.Name } })
                $ctors.Add([ordered]@{ params = $cparams })
            }
        } catch {}
        $rec.ctors = $ctors
    }
    $out.Add($rec)
}

$index = [ordered]@{
    assembly = $MainDll
    version  = $asmVersion
    typeCount = $out.Count
    types    = $out
}

$jsonPath = Join-Path $OutDir "api-index.json"
[System.IO.File]::WriteAllText($jsonPath, ($index | ConvertTo-Json -Depth 8 -Compress), (New-Object System.Text.UTF8Encoding($false)))

# Flat, grep-friendly symbol list (types + Type.Member + Enum.Value).
$symbols = New-Object System.Collections.Generic.List[string]
foreach ($r in $out) {
    $symbols.Add($r.name)
    if ($r.kind -eq "enum") {
        foreach ($v in $r.values) { $symbols.Add("$($r.name).$v") }
    }
    else {
        foreach ($p in $r.props) { $symbols.Add("$($r.name).$($p.n)") }
        foreach ($m in $r.methods) { $symbols.Add("$($r.name).$($m.n)") }
        if ($r.ctors) { foreach ($c in $r.ctors) { $symbols.Add("$($r.name)..ctor($($c.params.Count))") } }
    }
}
$symPath = Join-Path $OutDir "api-symbols.txt"
[System.IO.File]::WriteAllText($symPath, (($symbols | Sort-Object -Unique) -join [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))

Write-Host "API index built (v$asmVersion)."
Write-Host "  Types: $($out.Count)"
Write-Host "  Symbols: $($symbols.Count)"
Write-Host "  api-index.json: $jsonPath ($([math]::Round((Get-Item $jsonPath).Length/1KB)) KB)"
Write-Host "  api-symbols.txt: $symPath"
