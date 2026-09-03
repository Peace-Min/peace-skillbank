param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    # Also build the C# fixture with the local .NET SDK and run parity against the golden C++ port
    # (needs dotnet + a C++ compiler; self-skips with a message when either is missing).
    [switch]$IncludeParityE2E
)

# Behavioural fixtures for the csharp-to-cpp-port skill scripts:
#  - sample-app: real console app + hand-written golden C++ port (build, link, parity, scan)
#  - realish: a .NET-4.7-shaped tree (partial WinForms form + Designer, generic interface/class,
#    nested enum, #if, extension method, Node<->Tree cycle, Item name clash, AssemblyInfo, Resources)
#  - negative paths: no .cs files, missing compiler, unsafe/truncated replies, forbidden constructs.

$ErrorActionPreference = "Stop"

function Assert-Condition {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw "csharp-to-cpp fixture failed: $Message" }
}
function Remove-Dir { param([string]$Path) if (Test-Path -LiteralPath $Path) { [System.IO.Directory]::Delete($Path, $true) } }
function Invoke-Skill {
    # Runs a skill script the way users do: a native powershell.exe child with -File.
    param([string]$Script, [string[]]$Arguments)
    $global:LASTEXITCODE = 0
    $ErrorActionPreference = "Continue"   # a child's stderr line is data here, not a terminating error
    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments 2>&1 | ForEach-Object { "$_" }
    return @{ code = $LASTEXITCODE; text = ($output -join "`n") }
}

$skill = Join-Path $RepositoryRoot "skills\csharp-to-cpp-port"
$scripts = Join-Path $skill "scripts"
$fixture = Join-Path $RepositoryRoot "tests\fixtures\csharp-to-cpp-port"
$sampleApp = Join-Path $fixture "sample-app"
$realish = Join-Path $fixture "realish"
$golden = Join-Path $fixture "expected-cpp"
$cases = Join-Path $fixture "cases"
$out = Join-Path $RepositoryRoot "out\csharp-to-cpp-fixtures"
Remove-Dir $out
New-Item -ItemType Directory -Force -Path $out | Out-Null
$S = @{}
foreach ($n in @("inventory-csharp", "make-unit-prompt", "apply-unit-response", "scan-forbidden", "build-check", "parity-check", "port-status")) {
    $S[$n] = Join-Path $scripts "$n.ps1"
    Assert-Condition (Test-Path -LiteralPath $S[$n]) "missing script $n.ps1"
}
foreach ($f in @("mapping-table.md", "porting-rules.md", "unit-prompt-template.md", "example-port.md", "forbidden-patterns.txt", "model-agnostic-prompt.md", "cli-usage.md", "PortSupport.h")) {
    Assert-Condition (Test-Path -LiteralPath (Join-Path $skill "references\$f")) "missing reference $f"
}
Assert-Condition ((Get-FileHash -LiteralPath (Join-Path $skill "references\PortSupport.h")).Hash -eq (Get-FileHash -LiteralPath (Join-Path $golden "PortSupport.h")).Hash) "golden PortSupport.h must be identical to the reference copy"

# A scratch C++ root: inventory/prompt outputs default to <CppRoot>\port-work.
$cppRoot = Join-Path $out "cpp"
New-Item -ItemType Directory -Force -Path $cppRoot | Out-Null
$wd = Join-Path $cppRoot "port-work"

# ---- inventory: sample app, whole tree -------------------------------------------------------------
$r = Invoke-Skill $S["inventory-csharp"] @("-SourceRoot", $sampleApp, "-CppRoot", $cppRoot)
Assert-Condition ($r.code -eq 0) "inventory (sample) exit $($r.code): $($r.text)"
foreach ($f in @("inventory.json", "PORT_INVENTORY.md", "PORT_ORDER.txt", "PORT_STATUS.md", "status.json")) { Assert-Condition (Test-Path -LiteralPath (Join-Path $wd $f)) "inventory did not write $f" }
$order = @(Get-Content -LiteralPath (Join-Path $wd "PORT_ORDER.txt") | ForEach-Object { ($_ -split "`t")[1] })
Assert-Condition ($order.Count -eq 7) "expected 7 units, got $($order.Count): $($order -join ', ')"
function Get-Index { param([string[]]$List, [string]$Unit) return [array]::IndexOf($List, $Unit) }
Assert-Condition ((Get-Index $order "Models\DeviceKind.cs") -lt (Get-Index $order "Models\Device.cs")) "DeviceKind must precede Device"
Assert-Condition ((Get-Index $order "Util\StringHelpers.cs") -lt (Get-Index $order "Models\Device.cs")) "StringHelpers must precede Device"
Assert-Condition ((Get-Index $order "Models\Device.cs") -lt (Get-Index $order "Services\DeviceRepository.cs")) "Device must precede DeviceRepository"
Assert-Condition ((Get-Index $order "Services\Logger.cs") -lt (Get-Index $order "Services\DeviceRepository.cs")) "Logger must precede DeviceRepository"
Assert-Condition ((Get-Index $order "Program.cs") -eq 6) "Program.cs must be last"
$inv = Get-Content -Raw -LiteralPath (Join-Path $wd "inventory.json") | ConvertFrom-Json
$repoUnit = @($inv.units | Where-Object { $_.path -eq "Services\DeviceRepository.cs" })[0]
foreach ($flag in @("linq", "async", "event", "collections")) { Assert-Condition ($null -ne $repoUnit.flags.$flag) "DeviceRepository should be flagged '$flag'" }
Assert-Condition ($null -ne @($inv.units | Where-Object { $_.path -eq "Util\NativeMethods.cs" })[0].flags.pinvoke) "NativeMethods should be flagged pinvoke"
Assert-Condition (@($inv.cycles).Count -eq 0 -and $inv.projectKindGuess -eq "console-or-library" -and $inv.skippedCount -eq 0) "sample app: no cycles, console kind, nothing skipped"
Assert-Condition ($inv.ownership.Device.mode -eq "shared" -and $inv.ownership.Logger.mode -eq "shared" -and $inv.ownership.DeviceRepository.mode -eq "single") "ownership hints: Device/Logger SHARED (collection, parameter), DeviceRepository SINGLE (got $($inv.ownership.Device.mode)/$($inv.ownership.Logger.mode)/$($inv.ownership.DeviceRepository.mode))"
Assert-Condition ($null -eq $inv.ownership.PSObject.Properties["StringHelpers"]) "static classes get no ownership entry"

# ---- inventory: -Scope pulls prerequisites into the work list ----------------------------------------
$scopeRoot = Join-Path $out "cpp-scope"
$r = Invoke-Skill $S["inventory-csharp"] @("-SourceRoot", $sampleApp, "-CppRoot", $scopeRoot, "-Scope", "Services")
Assert-Condition ($r.code -eq 0) "inventory (scope) exit $($r.code): $($r.text)"
$scopeLines = @(Get-Content -LiteralPath (Join-Path $scopeRoot "port-work\PORT_ORDER.txt"))
$scopeOrder = @($scopeLines | ForEach-Object { ($_ -split "`t")[1] })
Assert-Condition ($scopeOrder -contains "Models\Device.cs" -and $scopeOrder -contains "Models\DeviceKind.cs" -and $scopeOrder -contains "Util\StringHelpers.cs") "scoped work list must include prerequisites of Services"
Assert-Condition ($scopeOrder -notcontains "Program.cs" -and $scopeOrder -notcontains "Util\NativeMethods.cs") "scoped work list must not include unrelated units"
Assert-Condition ((Get-Index $scopeOrder "Models\Device.cs") -lt (Get-Index $scopeOrder "Services\DeviceRepository.cs")) "prerequisites come before the scoped unit"
Assert-Condition (@($scopeLines | Where-Object { $_ -match "^\d+`tModels\\Device\.cs`t.*`tprereq" }).Count -eq 1) "Models\Device.cs must carry the prereq mark"
$ext = Get-Content -Raw -LiteralPath (Join-Path $scopeRoot "port-work\EXTERNAL_DEPS.txt")
Assert-Condition ($ext -match "Services\\DeviceRepository\.cs\t->\tModels\\Device\.cs\tDevice") "EXTERNAL_DEPS must list Device dependency"

# ---- inventory: negative paths -----------------------------------------------------------------------
$empty = Join-Path $out "empty"; New-Item -ItemType Directory -Force -Path $empty | Out-Null
$r = Invoke-Skill $S["inventory-csharp"] @("-SourceRoot", $empty, "-OutputDirectory", (Join-Path $out "work-empty"))
Assert-Condition ($r.code -eq 2 -and $r.text -match "No \.cs files found") "inventory on an empty dir must exit 2 with a clear message: $($r.text)"
$r = Invoke-Skill $S["inventory-csharp"] @("-SourceRoot", (Join-Path $out "does-not-exist"))
Assert-Condition ($r.code -eq 2 -and $r.text -match "not an existing directory") "inventory on a missing dir must exit 2"

# ---- inventory: realish tree (partial+designer, skips, cycle SCC, name clash, generics) ---------------
$realRoot = Join-Path $out "cpp-realish"
$r = Invoke-Skill $S["inventory-csharp"] @("-SourceRoot", $realish, "-CppRoot", $realRoot)
Assert-Condition ($r.code -eq 0) "inventory (realish) exit $($r.code): $($r.text)"
$rwd = Join-Path $realRoot "port-work"
$rinv = Get-Content -Raw -LiteralPath (Join-Path $rwd "inventory.json") | ConvertFrom-Json
Assert-Condition ($rinv.fileCount -eq 15 -and $rinv.skippedCount -eq 2 -and @($rinv.units).Count -eq 12) "realish: 15 files -> 2 skipped, 12 units (got skipped=$($rinv.skippedCount) units=$(@($rinv.units).Count))"
Assert-Condition (@($rinv.skipped | Where-Object { $_.path -eq "Properties\AssemblyInfo.cs" }).Count -eq 1 -and @($rinv.skipped | Where-Object { $_.path -eq "Properties\Resources.Designer.cs" }).Count -eq 1) "AssemblyInfo and Resources.Designer must be skipped"
$form = @($rinv.units | Where-Object { $_.path -eq "Forms\MainForm.cs" })
Assert-Condition ($form.Count -eq 1 -and @($form[0].files).Count -eq 2 -and (@($form[0].files) -contains "Forms\MainForm.Designer.cs")) "MainForm.cs + MainForm.Designer.cs must be ONE unit"
Assert-Condition ((@($form[0].marks) -contains "partial") -and (@($form[0].marks) -contains "designer") -and (@($form[0].marks) -contains "ui")) "MainForm unit marks: partial, designer, ui (got $($form[0].marks -join ','))"
Assert-Condition (@($rinv.units | Where-Object { $_.path -eq "Forms\MainForm.Designer.cs" }).Count -eq 0) "Designer file must not be its own unit"
Assert-Condition (@($rinv.cycles).Count -eq 1) "realish: exactly one cycle group (got $(@($rinv.cycles).Count))"
$cyc = @($rinv.cycles[0]) | Sort-Object
Assert-Condition (($cyc -join ',') -eq "Core\Node.cs,Core\Tree.cs") "cycle group must be exactly Node+Tree (got $($cyc -join ','))"
$consumer = @($rinv.units | Where-Object { $_.path -eq "Services\Consumer.cs" })[0]
Assert-Condition ((@($consumer.deps) -contains "Services\Item.cs") -and (@($consumer.deps) -notcontains "Core\Item.cs") -and (@($consumer.deps) -notcontains "Legacy\Item.cs")) "Item must resolve to the unit's OWN namespace before a using (deps: $($consumer.deps -join ','))"
$report = @($rinv.units | Where-Object { $_.path -eq "Services\Sub\Report.cs" })[0]
Assert-Condition ((@($report.deps) -contains "Services\Item.cs") -and (@($report.deps) -notcontains "Core\Item.cs")) "Item must resolve through the ENCLOSING namespace before a using (deps: $($report.deps -join ','))"
$legacy = @($rinv.units | Where-Object { $_.path -eq "Legacy\Item.cs" })[0]
Assert-Condition (@($legacy.deps).Count -eq 0) "#region names and same-named members must not create dependencies (deps: $($legacy.deps -join ','))"
Assert-Condition (@($rinv.ambiguousReferences).Count -eq 0) "no reference should stay ambiguous in realish (got: $($rinv.ambiguousReferences -join '; '))"
Assert-Condition ((@($consumer.deps) -contains "Util\Extensions.cs") -and (@($consumer.deps) -contains "Core\Tree.cs")) "Consumer deps must include Extensions and Tree"
Assert-Condition ($rinv.projectKindGuess -eq "winforms") "realish kind must be winforms"
$rorder = @(Get-Content -LiteralPath (Join-Path $rwd "PORT_ORDER.txt") | ForEach-Object { ($_ -split "`t")[1] })
Assert-Condition ((Get-Index $rorder "Core\IRepository.cs") -lt (Get-Index $rorder "Core\Repo.cs")) "IRepository before Repo"
Assert-Condition ((Get-Index $rorder "Core\Node.cs") -lt (Get-Index $rorder "Forms\MainForm.cs")) "Node before MainForm"
$rst = Get-Content -Raw -LiteralPath (Join-Path $rwd "PORT_STATUS.md")
Assert-Condition ($rst -match 'skipped=2' -and $rst -match 'Properties\\AssemblyInfo\.cs` \| skipped') "PORT_STATUS must list skipped files as skipped"

# ---- make-unit-prompt: ported deps, not-ported deps, partial units, entry point, determinism ------------
$p1 = Join-Path $out "prompt-ported.md"
$r = Invoke-Skill $S["make-unit-prompt"] @("-Unit", "Services\DeviceRepository.cs", "-CppRoot", $golden, "-WorkDir", $wd, "-OutputPath", $p1)
Assert-Condition ($r.code -eq 0 -and $r.text -match 'UnportedDeps: 0') "make-unit-prompt (ported) exit $($r.code): $($r.text)"
$prompt = Get-Content -Raw -LiteralPath $p1
Assert-Condition (([regex]::Matches($prompt, 'PORTED \(authoritative\)')).Count -eq 3) "ported prompt must embed 3 real headers"
Assert-Condition ($prompt -notmatch 'NOT PORTED') "ported prompt must have no unported dependency"
Assert-Condition ($prompt -match 'public class DeviceRepository' -and $prompt -match 'std::wstring' -and $prompt -match 'Hard rules') "prompt must embed source, mapping and rules"
Assert-Condition ($prompt -match 'Create the file\(s\) below with your file-writing tool' -and $prompt -match [regex]::Escape((Join-Path $golden "Services\DeviceRepository.h"))) "agent mode must ask for files via the file tool with absolute paths"
Assert-Condition ($prompt -notmatch '\{\{[A-Z_]+\}\}') "prompt must have no unfilled placeholders"
Assert-Condition ($prompt -match 'Prompt size: about \d+ tokens') "prompt must state its size"
Assert-Condition ($prompt -match 'Ownership \(computed' -and $prompt -match '`Device`: SHARED' -and $prompt -match '`Logger`: SHARED' -and $prompt -match '`DeviceRepository`: SINGLE owner -> plain value') "prompt must carry the computed ownership list"
Assert-Condition ($prompt -notmatch '(?m)^\s*\.\.\.\s*$' -and $prompt -notmatch '#include \.\.\.') "prompt skeleton must not contain elisions"
Assert-Condition (Test-Path -LiteralPath (Join-Path $golden "PortSupport.h")) "PortSupport.h must exist in the C++ root after make-unit-prompt"
$p2 = Join-Path $out "prompt-ported-2.md"
$r = Invoke-Skill $S["make-unit-prompt"] @("-Unit", "6", "-CppRoot", $golden, "-WorkDir", $wd, "-OutputPath", $p2)
Assert-Condition ($r.code -eq 0 -and ((Get-Content -Raw -LiteralPath $p2) -eq $prompt)) "make-unit-prompt must be deterministic and accept an index"

$pPaste = Join-Path $out "prompt-paste.md"
$r = Invoke-Skill $S["make-unit-prompt"] @("-Unit", "Services\DeviceRepository.cs", "-CppRoot", $golden, "-WorkDir", $wd, "-OutputPath", $pPaste, "-Mode", "paste")
Assert-Condition ($r.code -eq 0 -and ((Get-Content -Raw -LiteralPath $pPaste) -match '// FILE: Services/DeviceRepository\.h')) "paste mode must show the // FILE: contract"

$pMain = Join-Path $out "prompt-main.md"
$r = Invoke-Skill $S["make-unit-prompt"] @("-Unit", "Program.cs", "-CppRoot", $golden, "-WorkDir", $wd, "-OutputPath", $pMain)
$mainPrompt = Get-Content -Raw -LiteralPath $pMain
Assert-Condition ($r.code -eq 0 -and $mainPrompt -match 'Write exactly ONE file' -and $mainPrompt -match 'wmain' -and $mainPrompt -notmatch 'Program\.h') "entry-point unit must ask for a single .cpp with wmain"

$emptyCpp = Join-Path $out "cpp-empty"; New-Item -ItemType Directory -Force -Path $emptyCpp | Out-Null
$p3 = Join-Path $out "prompt-unported.md"
$r = Invoke-Skill $S["make-unit-prompt"] @("-Unit", "Services/DeviceRepository.cs", "-CppRoot", $emptyCpp, "-WorkDir", $wd, "-OutputPath", $p3)
Assert-Condition ($r.code -eq 0 -and $r.text -match 'UnportedDeps: 3' -and $r.text -match 'UNPORTED DEPENDENCIES') "unported deps must be reported on stdout: $($r.text)"
$up = Get-Content -Raw -LiteralPath $p3
Assert-Condition (([regex]::Matches($up, 'NOT PORTED')).Count -eq 3 -and $up -match 'STOP and port that unit first') "unported deps must be marked NOT PORTED with the stop instruction"
Assert-Condition ($up -match 'public class Device' -and $up -match 'public string Describe\(\);' -and $up -notmatch 'return \$"\[') "declaration summary must keep signatures and drop bodies"
Assert-Condition ((Get-ChildItem -LiteralPath $wd -Recurse -Directory -Filter stubs -ErrorAction SilentlyContinue).Count -eq 0) "no stub directory may be generated any more"

$pForm = Join-Path $out "prompt-form.md"
$r = Invoke-Skill $S["make-unit-prompt"] @("-Unit", "Forms\MainForm.Designer.cs", "-CppRoot", $realRoot, "-OutputPath", $pForm)
$fp = Get-Content -Raw -LiteralPath $pForm
Assert-Condition ($r.code -eq 0 -and $fp -match 'partial. type spread over 2 C# files' -and $fp -match '### `Forms\\MainForm\.cs`' -and $fp -match '### `Forms\\MainForm\.Designer\.cs`' -and $fp -match 'InitializeComponent') "partial unit prompt must merge both files (addressed by a member file)"
$pNode = Join-Path $out "prompt-node.md"
$r = Invoke-Skill $S["make-unit-prompt"] @("-Unit", "Core\Node.cs", "-CppRoot", $realRoot, "-OutputPath", $pNode)
Assert-Condition ($r.code -eq 0 -and ((Get-Content -Raw -LiteralPath $pNode) -match 'depend on each other \(cycle\)')) "cycle member prompt must explain the forward-declaration procedure"
$pMainForm = Join-Path $out "prompt-mainform.md"
Invoke-Skill $S["make-unit-prompt"] @("-Unit", "Forms/MainForm.cs", "-CppRoot", $realRoot, "-OutputPath", $pMainForm) | Out-Null
$mf = Get-Content -Raw -LiteralPath $pMainForm
Assert-Condition ($mf -match 'IRepository\.h` - uses: IRepository') "uses: must list the interface"
$pProg = Join-Path $out "prompt-realish-program.md"
Invoke-Skill $S["make-unit-prompt"] @("-Unit", "Program.cs", "-CppRoot", $realRoot, "-OutputPath", $pProg) | Out-Null
$rp = Get-Content -Raw -LiteralPath $pProg
Assert-Condition ($rp -match 'NOT PORTED: `Core/Repo\.h`') "Program must depend on Repo (generic static access)"
Assert-Condition ($rp -match '(?m)^\s+Strict = 0,' -and $rp -match '(?m)^\s+Lenient = 1') "NOT PORTED summary must keep nested enum members"
Assert-Condition ($rp -match 'public static Repo<T> Instance \{ get; \}' -and $rp -notmatch 'Instance \{ get; set; \}') "summary must not invent a setter"
Assert-Condition ($rp -match 'public int Count \{ get; \}' -and $rp -notmatch 'public int Count;') "multi-line property must stay a property"
Assert-Condition (([regex]::Matches($rp, 'DebugInfo\(\)')).Count -eq 1) "#if DEBUG must contribute one branch only"
$pUi = Join-Path $out "prompt-ui-missing.md"
$r = Invoke-Skill $S["make-unit-prompt"] @("-Unit", "Forms/MainForm.cs", "-CppRoot", $realRoot, "-OutputPath", $pUi)
Assert-Condition ($r.code -eq 0 -and $r.text -match 'UiMappingMissing: 1' -and ((Get-Content -Raw -LiteralPath $pUi) -match 'UI UNIT WITHOUT A UI MAPPING')) "a ui unit without port-work\mapping-extra.md must be refused: $($r.text)"
Copy-Item -LiteralPath (Join-Path $skill "references\ui-win32.md") -Destination (Join-Path $rwd "mapping-extra.md")
$r = Invoke-Skill $S["make-unit-prompt"] @("-Unit", "Forms/MainForm.cs", "-CppRoot", $realRoot, "-OutputPath", $pUi)
Assert-Condition ($r.code -eq 0 -and $r.text -match 'UiMappingMissing: 0' -and ((Get-Content -Raw -LiteralPath $pUi) -match 'CreateWindowExW')) "with mapping-extra.md the UI rows must be embedded"
Remove-Item -LiteralPath (Join-Path $rwd "mapping-extra.md") -Force
$pCons = Join-Path $out "prompt-consumer.md"
Invoke-Skill $S["make-unit-prompt"] @("-Unit", "Services/Consumer.cs", "-CppRoot", $realRoot, "-OutputPath", $pCons) | Out-Null
Assert-Condition ((Get-Content -Raw -LiteralPath $pCons) -match 'Extensions\.h` - uses: IsLeaf\(\)') "uses: must list extension methods"
Assert-Condition ((Get-Content -Raw -LiteralPath $pCons) -match 'finish-unit\.ps1" -CppRoot') "agent-mode prompt must end with the finish-unit command"
$r = Invoke-Skill $S["make-unit-prompt"] @("-Unit", "Nope\Missing.cs", "-CppRoot", $golden, "-WorkDir", $wd)
Assert-Condition ($r.code -eq 2 -and $r.text -match 'unit not in inventory' -and $r.text -match 'known units: .*Models\\Device\.cs') "unknown unit must exit 2 and list known units"

# ---- apply-unit-response: reply shapes, unsafe paths, truncation, -Expect -----------------------------------
$applied = Join-Path $out "applied"
$resp = Join-Path $out "MODEL_RESPONSE.md"
[System.IO.File]::WriteAllLines($resp, @('Sure:', '// FILE: Foo/Bar.h', '```cpp', '#pragma once', 'int Bar();', '```', '', '```cpp', '// FILE: Foo/Bar.cpp', '#include "Foo/Bar.h"', 'int Bar() { return 1; }', '```', '### Foo/Baz.h', '```cpp', '#pragma once', '```', '**// FILE: Foo/Qux.h**', '```cpp', '#pragma once', '```', '// FILE: ../evil.h', '```cpp', 'int x;', '```', '// FILE: C:\abs\x.cpp', '```cpp', 'int y;', '```'))
$r = Invoke-Skill $S["apply-unit-response"] @("-ResponsePath", $resp, "-CppRoot", $applied)
Assert-Condition ($r.code -eq 1) "apply must exit 1 when some blocks are rejected (got $($r.code)): $($r.text)"
foreach ($f in @("Foo\Bar.h", "Foo\Bar.cpp", "Foo\Baz.h", "Foo\Qux.h")) { Assert-Condition (Test-Path -LiteralPath (Join-Path $applied $f)) "apply must accept shape for $f" }
Assert-Condition (-not (Test-Path -LiteralPath (Join-Path $out "evil.h")) -and $r.text -match 'rejected \.\.[\\/]evil\.h' -and $r.text -match 'rejected C:\\abs\\x\.cpp') "apply must reject and report unsafe paths"
Assert-Condition ((Get-Content -Raw -LiteralPath (Join-Path $applied "Foo\Bar.cpp")) -notmatch '// FILE:') "marker inside the fence must be stripped"
$r = Invoke-Skill $S["apply-unit-response"] @("-ResponsePath", $resp, "-CppRoot", $applied)
Assert-Condition ($r.code -ne 0 -and $r.text -match 'exists; pass -Overwrite') "apply must refuse to overwrite silently (exit 2 when nothing could be written)"
$trunc = Join-Path $out "truncated.md"
[System.IO.File]::WriteAllLines($trunc, @('// FILE: T/A.h', '```cpp', '#pragma once', '```', '// FILE: T/A.cpp', '```cpp', '#include "T/A.h"', 'int f() {'))
$r = Invoke-Skill $S["apply-unit-response"] @("-ResponsePath", $trunc, "-CppRoot", $applied, "-Expect", "T/A.h,T/A.cpp")
Assert-Condition ($r.code -eq 1 -and $r.text -match 'fence never closed' -and $r.text -match 'missing expected file T\\A\.cpp') "truncated reply must be reported as missing expected file"
[System.IO.File]::WriteAllText((Join-Path $out "no-blocks.md"), "no code here")
$r = Invoke-Skill $S["apply-unit-response"] @("-ResponsePath", (Join-Path $out "no-blocks.md"), "-CppRoot", $applied)
Assert-Condition ($r.code -eq 2) "apply with no blocks must exit 2"

# ---- scan-forbidden ------------------------------------------------------------------------------------
$r = Invoke-Skill $S["scan-forbidden"] @("-Path", $golden)
Assert-Condition ($r.code -eq 0) "golden port must pass the forbidden scan: $($r.text)"
$bad = Join-Path $out "bad.cpp"
[System.IO.File]::WriteAllLines($bad, @('#using <mscorlib.dll>', 'using namespace System;', 'String^ s = gcnew String("x");', 'Foo* f = new Foo;', 'Foo* g = new Foo();', 'swprintf(buf, L"%d", 1);', 'std::cout << 1;', 'std::wofstream w(L"x");', 'auto u = std::make_unique<Foo>();', 'int n = (int)3.5;', '// ... rest of the implementation', '/* remaining methods omitted */', 'int ok = 1; // C# used new Foo() here', 'auto p = std::make_shared<Foo>(1);'))
$r = Invoke-Skill $S["scan-forbidden"] @("-Path", $bad)
Assert-Condition ($r.code -eq 1) "bad file must fail the scan"
foreach ($rule in @("cli-using-directive", "cli-using-system", "cli-gcnew", "raw-new", "printf", "std-cout", "wofstream", "elision")) { Assert-Condition ($r.text -match "\|error\|$rule\|") "scan must report rule $rule" }
Assert-Condition ($r.text -notmatch '\|unique-ptr\|') "std::unique_ptr is allowed for SINGLE polymorphic owners"
Assert-Condition (([regex]::Matches($r.text, '\|raw-new\|')).Count -eq 2) "raw-new must fire on 'new Foo;' and 'new Foo()' but not on a comment or make_shared"
Assert-Condition (([regex]::Matches($r.text, '\|elision\|')).Count -eq 2) "elision must catch both prose forms"
Assert-Condition ($r.text -match '\|warn\|c-cast\|') "C-style casts must be warned"
$okc = Join-Path $out "ok-comments.cpp"
[System.IO.File]::WriteAllLines($okc, @('int a = 1; // ... parameter unchanged', 'int b = 2; // fields omitted from C#', 'std::wstring s = L"remaining items are the same";', 'puts("x");'))
$r = Invoke-Skill $S["scan-forbidden"] @("-Path", $okc)
Assert-Condition (([regex]::Matches($r.text, '\|elision\|')).Count -eq 0) "ordinary comments must not trigger elision: $($r.text)"
Assert-Condition ($r.text -match '\|narrow-stdout\|') "puts() must be flagged (narrow write after InitConsole)"

# ---- example-port.md must itself be a valid port (extract + scan; compile when a compiler exists) ----------
$exRoot = Join-Path $out "example-cpp"; New-Item -ItemType Directory -Force -Path $exRoot | Out-Null
Copy-Item -LiteralPath (Join-Path $skill "references\PortSupport.h") -Destination (Join-Path $exRoot "PortSupport.h")
$r = Invoke-Skill $S["apply-unit-response"] @("-ResponsePath", (Join-Path $skill "references\example-port.md"), "-CppRoot", $exRoot, "-Expect", "Config/AppSettings.h,Config/AppSettings.cpp")
Assert-Condition ($r.code -eq 0) "example-port.md must parse into the two files: $($r.text)"
$r = Invoke-Skill $S["scan-forbidden"] @("-Path", $exRoot)
Assert-Condition ($r.code -eq 0) "example-port.md must pass the forbidden scan: $($r.text)"

# ---- build-check: negative path always; positive when a compiler exists ------------------------------------
$bwNeg = Join-Path $out "build-neg"
$r = Invoke-Skill $S["build-check"] @("-CppRoot", $golden, "-Unit", "Services\Logger.cpp", "-WorkDir", $bwNeg, "-Compiler", "msvc", "-ClPath", "C:\definitely\missing\cl.exe")
Assert-Condition ($r.code -eq 2) "build-check with a bad -ClPath must exit 2 (got $($r.code))"
$neg = Get-Content -Raw -LiteralPath (Join-Path $bwNeg "BUILD_RESULT.txt")
Assert-Condition ($neg -match 'Status: NO_COMPILER' -and $neg -match '-ClPath not found: C:\\definitely\\missing\\cl\.exe' -and $neg -match '## Remedy') "NO_COMPILER report must say what was checked and how to fix it"
$r = Invoke-Skill $S["build-check"] @("-CppRoot", $golden, "-Unit", "Nope\Missing.cpp", "-WorkDir", $bwNeg)
Assert-Condition ($r.code -eq 2 -and $r.text -match 'unit not found') "build-check with a missing unit must exit 2"

$bw = Join-Path $out "build"
$probe = Invoke-Skill $S["build-check"] @("-CppRoot", $golden, "-Unit", "Models\DeviceKind.cpp", "-WorkDir", $bw)
$haveCompiler = ($probe.code -ne 2)
if ($haveCompiler) {
    Assert-Condition ($probe.code -eq 0) "golden DeviceKind.cpp must compile: $($probe.text)"
    $exe = Join-Path $bw "out\SampleApp.exe"
    $r = Invoke-Skill $S["build-check"] @("-CppRoot", $golden, "-All", "-Link", "-OutputExe", $exe, "-WorkDir", $bw)
    Assert-Condition ($r.code -eq 0 -and (Test-Path -LiteralPath $exe)) "golden port must build and link: $($r.text)"
    $br = Get-Content -Raw -LiteralPath (Join-Path $bw "BUILD_RESULT.txt")
    Assert-Condition ($br -match 'Status: PASS' -and $br -match 'Units: 7' -and $br -match 'Link: PASS') "BUILD_RESULT contract (PASS/Units/Link)"
    $r = Invoke-Skill $S["build-check"] @("-CppRoot", $exRoot, "-Unit", "Config\AppSettings.cpp", "-WorkDir", (Join-Path $out "build-example"))
    Assert-Condition ($r.code -eq 0) "example-port.md must compile: $($r.text)"

    # Fake MSVC (real cl.exe/link.exe contracts, no real compilation): proves the msvc branch of build-check
    # constructs INCLUDE/LIB/PATH, passes /Fo /Zs /std:, parses `file(line): error Cnnnn:` and links with -LinkArgs.
    $gxxLine = @(Get-Content -LiteralPath (Join-Path $bw "BUILD_RESULT.txt") | Where-Object { $_ -match 'MinGW g\+\+ at (.+g\+\+\.exe)' })
    if ($gxxLine.Count -gt 0 -and $gxxLine[0] -match 'MinGW g\+\+ at (.+g\+\+\.exe)') {
        $gxx = $Matches[1].Trim()
        $fakeRoot = Join-Path $out "FAKEMSVC"
        $msvcBin = Join-Path $fakeRoot "VC\Tools\MSVC\14.99.0\bin\Hostx64\x64"
        foreach ($d in @($msvcBin, (Join-Path $fakeRoot "VC\Tools\MSVC\14.99.0\include"), (Join-Path $fakeRoot "VC\Tools\MSVC\14.99.0\lib\x64"), (Join-Path $fakeRoot "Kits\Include\10.0.1.0\um"), (Join-Path $fakeRoot "Kits\Include\10.0.1.0\ucrt"), (Join-Path $fakeRoot "Kits\Include\10.0.1.0\shared"), (Join-Path $fakeRoot "Kits\Lib\10.0.1.0\ucrt\x64"), (Join-Path $fakeRoot "Kits\Lib\10.0.1.0\um\x64"), (Join-Path $fakeRoot "Kits\bin\10.0.1.0\x64"))) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
        [System.IO.File]::WriteAllText((Join-Path $fakeRoot "VC\Tools\MSVC\14.99.0\include\string"), "// fake STL marker`n")
        [System.IO.File]::WriteAllText((Join-Path $fakeRoot "Kits\Include\10.0.1.0\um\windows.h"), "// fake SDK marker`n")
        $env:PATH = (Split-Path -Parent $gxx) + ";" + $env:PATH
        & $gxx -O0 -o (Join-Path $msvcBin "cl.exe") (Join-Path $fixture "fake-msvc\cl.c") 2>&1 | Out-Null
        & $gxx -O0 -o (Join-Path $msvcBin "link.exe") (Join-Path $fixture "fake-msvc\link.c") 2>&1 | Out-Null
        Assert-Condition ((Test-Path -LiteralPath (Join-Path $msvcBin "cl.exe")) -and (Test-Path -LiteralPath (Join-Path $msvcBin "link.exe"))) "fake cl.exe/link.exe must build with MinGW"
        $fakeCpp = Join-Path $out "fake-msvc-cpp"
        Copy-Item -Recurse -LiteralPath $golden -Destination $fakeCpp
        $r = Invoke-Skill $S["build-check"] @("-CppRoot", $fakeCpp, "-Compiler", "msvc", "-ClPath", (Join-Path $msvcBin "cl.exe"), "-WindowsKitsRoot", (Join-Path $fakeRoot "Kits"), "-All", "-Link", "-OutputExe", (Join-Path $fakeCpp "out\app.exe"), "-LinkArgs", "Ws2_32.lib", "-WorkDir", (Join-Path $fakeCpp "port-work"))
        $fb = Get-Content -Raw -LiteralPath (Join-Path $fakeCpp "port-work\BUILD_RESULT.txt")
        Assert-Condition ($r.code -eq 0 -and $fb -match 'Compiler: msvc - MSVC 14\.99\.0 \+ SDK 10\.0\.1\.0' -and $fb -match 'Units: 7' -and $fb -match 'Link: PASS' -and $fb -match 'fake link: library Ws2_32\.lib') "msvc branch must build the environment, compile 7 units, and link with -LinkArgs: $($r.text)`n$fb"
        Add-Content -LiteralPath (Join-Path $fakeCpp "Util\StringHelpers.cpp") -Value "`nint broken() { return undefined_symbol; }"
        $r = Invoke-Skill $S["build-check"] @("-CppRoot", $fakeCpp, "-Compiler", "msvc", "-ClPath", (Join-Path $msvcBin "cl.exe"), "-WindowsKitsRoot", (Join-Path $fakeRoot "Kits"), "-Unit", "Util/StringHelpers.cpp", "-WorkDir", (Join-Path $fakeCpp "port-work"))
        $fb = Get-Content -Raw -LiteralPath (Join-Path $fakeCpp "port-work\BUILD_RESULT.txt")
        Assert-Condition ($r.code -eq 1 -and $fb -match '(?m)^Util\\StringHelpers\.cpp\|\d+\|C2065\|.*undefined_symbol') "msvc diagnostics must be parsed into file|line|code|message: $fb"
        $r = Invoke-Skill $S["build-check"] @("-CppRoot", $fakeCpp, "-Compiler", "msvc", "-ClPath", (Join-Path $msvcBin "cl.exe"), "-WindowsKitsRoot", (Join-Path $fakeRoot "Kits"), "-Unit", "Models/Device.h", "-WorkDir", (Join-Path $fakeCpp "port-work"))
        Assert-Condition ($r.code -eq 0) "msvc header syntax check (/Zs) must pass: $($r.text)"
        $r = Invoke-Skill $S["build-check"] @("-CppRoot", $fakeCpp, "-Compiler", "msvc", "-ClPath", (Join-Path $msvcBin "cl.exe"), "-WindowsKitsRoot", (Join-Path $out "no-kits"), "-Unit", "Models/Device.cpp", "-WorkDir", (Join-Path $fakeCpp "port-work"))
        Assert-Condition ($r.code -eq 2 -and $r.text -match 'Windows 10/11 SDK not found') "missing SDK must be reported as NO_COMPILER with the reason: $($r.text)"
        Write-Host "csharp-to-cpp fixtures: fake-MSVC branch exercised (env, /Fo, /Zs, diagnostics, link, -LinkArgs)."
    }
    else { Write-Host "csharp-to-cpp fixtures: no MinGW path found in the probe output; fake-MSVC test skipped." }

    # PortSupport must reproduce .NET Framework 4.7 number formatting and accept long/DWORD.
    $probeRoot = Join-Path $out "portsupport-probe"; New-Item -ItemType Directory -Force -Path $probeRoot | Out-Null
    Copy-Item -LiteralPath (Join-Path $skill "references\PortSupport.h") -Destination (Join-Path $probeRoot "PortSupport.h")
    Copy-Item -LiteralPath (Join-Path $fixture "portsupport-probe\Probe.cpp") -Destination (Join-Path $probeRoot "Probe.cpp")
    $r = Invoke-Skill $S["build-check"] @("-CppRoot", $probeRoot, "-All", "-Link", "-OutputExe", (Join-Path $probeRoot "out\probe.exe"), "-WorkDir", (Join-Path $probeRoot "port-work"))
    Assert-Condition ($r.code -eq 0) "PortSupport probe must compile (long/DWORD overloads): $($r.text)"
    $probeOutFile = Join-Path $probeRoot "probe.out.txt"
    $pp = Start-Process -FilePath (Join-Path $probeRoot "out\probe.exe") -NoNewWindow -PassThru -Wait -RedirectStandardOutput $probeOutFile
    $probeLines = @(([System.IO.File]::ReadAllText($probeOutFile, (New-Object System.Text.UTF8Encoding($false))) -replace "`r", "").Trim() -split "`n")
    Assert-Condition ($probeLines[0] -eq "5|7|9") "integer overloads: $($probeLines[0])"
    Assert-Condition ($probeLines[1] -eq "1E+15|1E-05|NaN|Infinity|0|1.33333333333333|1.5|100") "G15 spelling must match .NET Framework: $($probeLines[1])"
    Assert-Condition ($probeLines[2] -eq "2.68|0.13|1.01|0.05|8.33|1|3|0.00|-2.68|1234.57|0.00|100.00") "F-format must round the 15-digit decimal half away from zero like .NET Framework: $($probeLines[2])"

    # finish-unit: PASS -> NEXT; broken unit -> FAIL rounds -> BLOCKED; blocked dependency reported; forbidden stops the build
    $fuRoot = Join-Path $out "finish-cpp"
    Copy-Item -Recurse -LiteralPath $golden -Destination $fuRoot
    Invoke-Skill $S["inventory-csharp"] @("-SourceRoot", $sampleApp, "-CppRoot", $fuRoot) | Out-Null
    $r = Invoke-Skill (Join-Path $scripts "finish-unit.ps1") @("-CppRoot", $fuRoot, "-Unit", "Models/DeviceKind.cs")
    Assert-Condition ($r.code -eq 0 -and $r.text -match 'RESULT: PASS' -and $r.text -match 'NEXT: Services\\Logger\.cs') "finish-unit PASS must name the next unit: $($r.text)"
    Add-Content -LiteralPath (Join-Path $fuRoot "Util\StringHelpers.cpp") -Value "`nint broken() { return undefined_symbol; }"
    $r = Invoke-Skill (Join-Path $scripts "finish-unit.ps1") @("-CppRoot", $fuRoot, "-Unit", "Util/StringHelpers.cs")
    Assert-Condition ($r.code -eq 1 -and $r.text -match 'RESULT: FAIL \(round 1 of 3\)' -and $r.text -match 'undefined_symbol') "finish-unit FAIL round 1: $($r.text)"
    Invoke-Skill (Join-Path $scripts "finish-unit.ps1") @("-CppRoot", $fuRoot, "-Unit", "Util/StringHelpers.cs") | Out-Null
    $r = Invoke-Skill (Join-Path $scripts "finish-unit.ps1") @("-CppRoot", $fuRoot, "-Unit", "Util/StringHelpers.cs")
    Assert-Condition ($r.code -eq 1 -and $r.text -match 'RESULT: BLOCKED' -and $r.text -match 'NEXT: ') "finish-unit must block after 3 rounds: $($r.text)"
    $fst = Get-Content -Raw -LiteralPath (Join-Path $fuRoot "port-work\PORT_STATUS.md")
    Assert-Condition ($fst -match 'Util\\StringHelpers\.cs` \| blocked') "blocked state must be recorded"
    $r = Invoke-Skill $S["make-unit-prompt"] @("-Unit", "Models/Device.cs", "-CppRoot", $fuRoot, "-OutputPath", (Join-Path $out "prompt-blocked-dep.md"))
    Assert-Condition ($r.text -match 'BlockedDeps: 1' -and ((Get-Content -Raw -LiteralPath (Join-Path $out "prompt-blocked-dep.md")) -match 'BLOCKED DEPENDENCIES')) "a blocked dependency must be reported instead of burning rounds: $($r.text)"
    [System.IO.File]::WriteAllText((Join-Path $fuRoot "Util\NativeMethods.cpp"), 'int x = 1; // ... rest of the implementation')
    $r = Invoke-Skill (Join-Path $scripts "finish-unit.ps1") @("-CppRoot", $fuRoot, "-Unit", "Util/NativeMethods.cs")
    Assert-Condition ($r.code -eq 1 -and $r.text -match 'RESULT: FORBIDDEN') "finish-unit must stop on forbidden constructs before building"

    # Round 2: a broken unit -> FAIL with file|line|code|message; the next prompt embeds those lines.
    $broken = Join-Path $out "broken-cpp"
    Copy-Item -Recurse -LiteralPath $golden -Destination $broken
    Add-Content -LiteralPath (Join-Path $broken "Util\StringHelpers.cpp") -Value "`nint broken() { return undefined_symbol; }"
    $bwd = Join-Path $broken "port-work"
    Invoke-Skill $S["inventory-csharp"] @("-SourceRoot", $sampleApp, "-CppRoot", $broken) | Out-Null
    $r = Invoke-Skill $S["build-check"] @("-CppRoot", $broken, "-Unit", "Util\StringHelpers.cpp")
    Assert-Condition ($r.code -eq 1) "broken unit must exit 1"
    $brb = Get-Content -Raw -LiteralPath (Join-Path $bwd "BUILD_RESULT.txt")
    Assert-Condition ($brb -match 'Status: FAIL' -and $brb -match '(?m)^Util\\StringHelpers\.cpp\|\d+\|[^|]*\|.*undefined_symbol') "FAIL report must carry file|line|code|message for the broken line"
    $pr2 = Join-Path $out "prompt-round2.md"
    $r = Invoke-Skill $S["make-unit-prompt"] @("-Unit", "Util\StringHelpers.cs", "-CppRoot", $broken, "-OutputPath", $pr2)
    $round2 = Get-Content -Raw -LiteralPath $pr2
    Assert-Condition ($r.code -eq 0 -and $r.text -match 'build errors included: yes' -and $round2 -match 'The last build of this unit FAILED' -and $round2 -match 'undefined_symbol') "round-2 prompt must embed the build errors"
    # An error inside a PORTED header (call/declaration mismatch) must reach the prompt too.
    $broken2 = Join-Path $out "broken2-cpp"
    Copy-Item -Recurse -LiteralPath $golden -Destination $broken2
    Add-Content -LiteralPath (Join-Path $broken2 "Models\Device.h") -Value "`nnamespace SampleApp::Models { int Oops(); int Oops2() { return undefined_in_header; } }"
    Invoke-Skill $S["inventory-csharp"] @("-SourceRoot", $sampleApp, "-CppRoot", $broken2) | Out-Null
    Invoke-Skill $S["build-check"] @("-CppRoot", $broken2, "-Unit", "Services\DeviceRepository.cpp") | Out-Null
    $pr3 = Join-Path $out "prompt-round2-header.md"
    Invoke-Skill $S["make-unit-prompt"] @("-Unit", "Services\DeviceRepository.cs", "-CppRoot", $broken2, "-OutputPath", $pr3) | Out-Null
    Assert-Condition ((Get-Content -Raw -LiteralPath $pr3) -match 'Models\\Device\.h\|\d+\|.*undefined_in_header') "errors located in a dependency header must be embedded, not filtered out"
}
else {
    Write-Host "csharp-to-cpp fixtures: no C++ compiler found; skipping compile/link/parity checks (negative paths verified)."
}

# ---- parity: negative path always; end-to-end when opted in and the tools exist -------------------------------
$r = Invoke-Skill $S["parity-check"] @("-CsExe", (Join-Path $out "missing.exe"), "-CppExe", (Join-Path $out "missing2.exe"), "-CasesDir", $cases, "-WorkDir", (Join-Path $out "parity-neg"))
Assert-Condition ($r.code -eq 2 -and $r.text -match 'C# program not found') "parity with a missing C# exe must exit 2 with a clear message"
$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if ($IncludeParityE2E -and $haveCompiler -and $dotnet) {
    $ver = (& $dotnet.Source --version) -replace '-.*$', ''
    $tfm = "net" + ([version]$ver).Major + ".0"
    $csOut = Join-Path $out "cs-build"
    $buildLog = Join-Path $out "dotnet-build.log"
    $p = Start-Process -FilePath $dotnet.Source -ArgumentList @("build", ('"' + (Join-Path $sampleApp "SampleApp.csproj") + '"'), "-nologo", "-v", "q", "-p:FixtureTfm=$tfm", "-o", ('"' + $csOut + '"')) -NoNewWindow -PassThru -Wait -RedirectStandardOutput $buildLog -RedirectStandardError "$buildLog.err"
    Assert-Condition ($p.ExitCode -eq 0) "dotnet build of the C# fixture failed (see $buildLog)"
    $csExe = Join-Path $csOut "SampleApp.exe"
    if (-not (Test-Path -LiteralPath $csExe)) { $csExe = Join-Path $csOut "SampleApp.dll" }
    $r = Invoke-Skill $S["parity-check"] @("-CsExe", $csExe, "-CppExe", (Join-Path $bw "out\SampleApp.exe"), "-CasesDir", $cases, "-WorkDir", (Join-Path $out "parity"))
    Assert-Condition ($r.code -eq 0) "golden C++ port must match the C# program on every case: $($r.text)"
    $pr = Get-Content -Raw -LiteralPath (Join-Path $out "parity\PARITY_RESULT.txt")
    Assert-Condition ($pr -match 'Status: PASS' -and $pr -match 'Cases: 4' -and $pr -match 'numeric \[PASS\]' -and $pr -match 'unknown-kind \[PASS\].*exit C#=2 C\+\+=2') "PARITY_RESULT contract (4 cases incl. numeric enum and Korean/double/bool lines)"
    $csOutText = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $out "parity\parity\default.cs.out.txt")
    Assert-Condition ($csOutText -match 'ratio: 0\.5' -and $csOutText -match 'online\(2\): True' -and $csOutText -match [char]0xC7A5) "C# output must contain the double/bool/Korean lines the port has to match"
    Write-Host "csharp-to-cpp fixtures: parity E2E passed (C# $tfm vs golden C++)."
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) {
        $port = 18765
        $srv = Start-Process -FilePath $python.Source -ArgumentList @(('"' + (Join-Path $fixture "fake-endpoint.py") + '"'), "$port", ('"' + $golden + '"')) -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $out "fake-endpoint.out.txt") -RedirectStandardError (Join-Path $out "fake-endpoint.err.txt")
        try {
            $ready = $false
            for ($i = 0; $i -lt 40 -and -not $ready; $i++) { Start-Sleep -Milliseconds 250; try { $c = New-Object System.Net.Sockets.TcpClient; $c.Connect("127.0.0.1", $port); $c.Close(); $ready = $true } catch { } }
            Assert-Condition $ready "fake endpoint did not start (see $out\fake-endpoint.err.txt)"
            $evalOut = Join-Path $RepositoryRoot "out\csharp-to-cpp-eval\fixture-endpoint"
            $ErrorActionPreference = "Continue"
            $evalText = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepositoryRoot "tests\run-csharp-to-cpp-eval-loop.ps1") -RepositoryRoot $RepositoryRoot -Endpoint "http://127.0.0.1:$port/v1" -Model "fake" -OutputDirectory $evalOut -CsExe $csExe -CasesDir $cases 2>&1 | ForEach-Object { "$_" }) -join "`n"
            $evalCode = $LASTEXITCODE
            $ErrorActionPreference = "Stop"
            $summary = Get-Content -Raw -LiteralPath (Join-Path $evalOut "RUN_SUMMARY.md")
            Assert-Condition ($evalCode -eq 0 -and $summary -match 'Final build pass: 7 / 7' -and $summary -match 'First-try build pass: 7 / 7' -and $summary -match 'Parity: PASS') "eval loop over the fake endpoint must pass every unit and parity: $evalText"
            $progBytes = [System.IO.File]::ReadAllText((Join-Path $evalOut "cpp\Program.cpp"), (New-Object System.Text.UTF8Encoding($false)))
            Assert-Condition ($progBytes.Contains([string][char]0xC7A5 + [string][char]0xCE58)) "Korean text must survive the HTTP path (UTF-8 without charset header)"
            $stringHelpers = Join-Path $evalOut "cpp\Util\StringHelpers.cpp"
            Assert-Condition ((Test-Path -LiteralPath $stringHelpers) -and ((Get-Content -Raw -LiteralPath $stringHelpers) -notmatch '<think>')) "heading-shaped reply must be applied and <think> stripped"
            Write-Host "csharp-to-cpp fixtures: eval loop over a fake OpenAI endpoint passed (7/7, parity, UTF-8, think stripped)."
        }
        finally { try { Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue } catch { } }
    }
    else { Write-Host "csharp-to-cpp fixtures: python not found; fake-endpoint eval test skipped." }
}
elseif ($IncludeParityE2E) {
    Write-Host "csharp-to-cpp fixtures: parity E2E skipped (dotnet: $([bool]$dotnet), compiler: $haveCompiler)."
}

# ---- port-status: states, member-file lookup, dependents, stale ------------------------------------------------
$r = Invoke-Skill $S["port-status"] @("-WorkDir", $wd, "-Unit", "Models/DeviceKind.cs", "-State", "builds", "-Note", "fixture")
Assert-Condition ($r.code -eq 0) "port-status update failed: $($r.text)"
$st = Get-Content -Raw -LiteralPath (Join-Path $wd "PORT_STATUS.md")
Assert-Condition ($st -match 'builds=1' -and $st -match '`Models\\DeviceKind\.cs` \| builds') "PORT_STATUS.md must reflect the update"
Invoke-Skill $S["port-status"] @("-WorkDir", $wd, "-Unit", "Models\Device.cs", "-State", "builds") | Out-Null
$r = Invoke-Skill $S["port-status"] @("-WorkDir", $wd, "-Unit", "Models\DeviceKind.cs", "-DependentsOf")
Assert-Condition ($r.code -eq 0 -and $r.text -match 'Models\\Device\.cs\s+builds' -and $r.text -match 'Services\\DeviceRepository\.cs\s+todo') "DependentsOf must list dependents with states: $($r.text)"
$r = Invoke-Skill $S["port-status"] @("-WorkDir", $wd, "-Unit", "Models\DeviceKind.cs", "-State", "builds", "-StaleDependents")
Assert-Condition ($r.code -eq 0 -and $r.text -match 'Models\\Device\.cs -> todo \(stale\)') "StaleDependents must reset built dependents to todo"
$r = Invoke-Skill $S["port-status"] @("-CppRoot", $realRoot, "-Unit", "Forms\MainForm.Designer.cs", "-State", "translated")
Assert-Condition ($r.code -eq 0 -and $r.text -match 'Forms\\MainForm\.cs -> translated') "port-status must accept -CppRoot and a member file of a partial unit"
$r = Invoke-Skill $S["port-status"] @("-CppRoot", $realRoot, "-Unit", "Forms/MainForm.cs+Forms/MainForm.Designer.cs", "-State", "todo")
Assert-Condition ($r.code -eq 0 -and $r.text -match 'Forms\\MainForm\.cs -> todo') "port-status must accept the a.cs+b.cs form"
$r = Invoke-Skill $S["port-status"] @("-CppRoot", $scopeRoot, "-Unit", "Models/DeviceKind.cs", "-State", "builds")
Assert-Condition ($r.text -match 'NEXT: Services\\Logger\.cs') "NEXT must be the first todo in WORK-LIST order (scope: DeviceKind builds -> Logger): $($r.text)"
$r = Invoke-Skill $S["port-status"] @("-CppRoot", $scopeRoot, "-Next")
Assert-Condition ($r.code -eq 0 -and $r.text -match '^NEXT: Services\\Logger\.cs') "-Next prints the next unit"
$r = Invoke-Skill $S["port-status"] @("-WorkDir", $wd, "-Unit", "Nope.cs", "-State", "builds")
Assert-Condition ($r.code -eq 2 -and $r.text -match 'unit not in inventory') "port-status with an unknown unit must exit 2"

Write-Host "csharp-to-cpp fixtures passed (compiler available: $haveCompiler)."
exit 0
