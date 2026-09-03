# CLI reference

All scripts: Windows PowerShell 5.1+ or PowerShell 7, run natively (no Git Bash / cmd wrapping).
List parameters take ONE comma-separated value (`-Expect a.h,a.cpp`): `powershell -File` cannot repeat a named parameter.
Working folder for outputs: `<CppRoot>\port-work` (every script that takes `-CppRoot` defaults to
it; `inventory-csharp.ps1` needs `-CppRoot` or `-OutputDirectory`).
Exit codes everywhere: `0` success, `1` the check failed (build errors, forbidden hits, parity diff,
rejected reply), `2` environment or input problem (message on stderr says exactly what and where).

## inventory-csharp.ps1

```text
-SourceRoot <dir>          C# project root (required)
-CppRoot <dir>             C++ output root; outputs go to <CppRoot>\port-work
-OutputDirectory <dir>     explicit output folder (overrides the default)
-Scope <relative dir>      narrow this pass; the work list still gains the prerequisites (marked prereq)
-ExcludeDirectory <names>  default bin, obj, .vs, packages, TestResults, node_modules, .git
```

Units: one `.cs` file, or all files of one `partial` type (e.g. `Form.cs` + `Form.Designer.cs`),
listed under the non-Designer file. Skipped (never ported): `AssemblyInfo.cs`, `GlobalSuppressions.cs`,
`*.g.cs`, `*.g.i.cs`, `*.AssemblyAttributes.cs`, `TemporaryGeneratedFile_*`, `Resources.Designer.cs`,
`Settings.Designer.cs`. Dependency cycles are reported as strongly connected groups. A type name that
exists in several namespaces is resolved through the referencing file's `namespace`/`using`s.

Outputs `inventory.json`, `PORT_INVENTORY.md`, `PORT_ORDER.txt` (index, unit, lines, flags, marks,
files joined by `+`), `EXTERNAL_DEPS.txt` (with -Scope), and creates `status.json` + `PORT_STATUS.md`
when missing (skipped files start in state `skipped`).

## make-unit-prompt.ps1

```text
-Unit <unit path | member file | index>   from PORT_ORDER.txt (required)
-CppRoot <dir>                 C++ output root; ported headers are found as <unit path>.h (required)
-WorkDir <dir>                 default <CppRoot>\port-work
-Mode agent|paste              agent (default): write files with the tool, reply with paths;
                               paste: reply with "// FILE:" + fenced blocks for apply-unit-response.ps1
-MappingTable / -Rules / -Template / -Example <file>   override the bundled references
-NoExample                     omit the worked example (shorter prompt)
-ExtraNote <text>              extra section for the next round (e.g. "your reply had no file blocks")
-OutputPath <file>             default <WorkDir>\UNIT_PROMPT.md
```

Prints `UnportedDeps: N`, `BlockedDeps: M` and `UiMappingMissing: 0|1`. If `<WorkDir>\mapping-extra.md`
exists its rows are appended to the mapping table (copy `references\ui-win32.md` or `ui-mfc.md` there once
the UI framework is chosen). Dependencies whose header exists are embedded verbatim (authoritative);
the others are shown as C# declarations with bodies removed and an instruction to port them first
(or, inside a cycle group, to forward-declare). Copies `references\PortSupport.h` into the C++ root
the first time. Reports the approximate prompt size in tokens.

## apply-unit-response.ps1

```text
-ResponsePath <file>   model reply (required)
-CppRoot <dir>         (required)
-Allow <prefixes>      comma-separated; only accept paths starting with these (e.g. Services/Logger)
-Expect <a,b>          comma-separated paths that must be present; missing -> exit 1 "reply truncated or wrong format?"
-Overwrite             replace existing files
```

Accepted reply shapes: `// FILE: path` before the fence, `// FILE: path` as the first line inside the
fence, or a `### path` / `**path**` heading before the fence. Unclosed fences are rejected.

## scan-forbidden.ps1

```text
-Path <files|dirs>     (required; comma-separated for several); PortSupport.h is skipped
-Patterns <file>       default references\forbidden-patterns.txt  (name|severity|regex per line)
-OutputPath <file>     optional report
```

## build-check.ps1

```text
-CppRoot <dir>                     (required)
-Unit <relative .cpp|.h> | -All    comma-separated list allowed; .h is syntax-checked only; -All skips port-work, build, out, .vs, CMakeFiles
-Standard c++17                    passed as /std: or -std=
-IncludeDir <dirs>                 extra include roots
-WorkDir <dir>                     default <CppRoot>\port-work
-Compiler auto|msvc|gcc            default auto
-ClPath <cl.exe> | -GxxPath <g++.exe>
-WindowsKitsRoot <dir>             default %ProgramFiles(x86)%\Windows Kits\10
-Link -OutputExe <exe>             link all objects (MSVC link.exe or g++ -municode)
-LinkArgs <args>                   extra linker inputs: Ws2_32.lib (MSVC) or -lws2_32 (MinGW)
-ExtraArgs <args>                  appended to every compile
-TimeoutSeconds 180
```

Compiler discovery order (auto): `-ClPath` -> `cl.exe` already on PATH with INCLUDE set -> every
Visual Studio / Build Tools instance from vswhere (newest `VC\Tools\MSVC\<ver>` that actually has
`include\string`, plus the newest Windows 10/11 SDK) -> `-GxxPath` -> `g++.exe` on PATH -> known
MinGW locations (CLion bundle, MSYS2, mingw64, Qt, TDM-GCC). The MSVC environment (PATH/INCLUDE/LIB)
is constructed explicitly, so a partial VS install without `vcvarsall.bat` still works when the
headers are present, and is reported as `NO_COMPILER` with the reason when they are not.
The MSVC branch has only been exercised for discovery on a partial install; MinGW is verified.

`BUILD_RESULT.txt` contract:

```text
# BUILD_RESULT
Status: PASS|FAIL|NO_COMPILER
Compiler: msvc|gcc - <note>
Standard: c++17
CppRoot: <dir>
Units: N
Unit: <path> OK|FAIL errors=E warnings=W
Link: PASS -> <exe> | FAIL (...) | SKIPPED (...)      (only with -Link)
Errors: E
Warnings: W

## Errors (file|line|code|message)
...
## Warnings (first 30, file|line|code|message)
...
## Raw compiler output
...
```

## parity-check.ps1

```text
-CsExe <exe|dll>       original program (a .dll is run through dotnet)
-CppExe <exe>          the linked port
-CasesDir <dir>        <name>.args (one line of arguments; empty file = none) + optional <name>.stdin
-CppRoot <dir> | -WorkDir <dir>   work dir (default .\port-work); raw outputs under <WorkDir>\parity\
-CsCodePage 65001      code page both children write; the console output encoding is set for them
-TimeoutSeconds 60
```

Both programs run per case; stdout is normalised (CRLF->LF, BOM stripped, trailing whitespace and
trailing newlines ignored) and compared together with the exit code. `.NET Framework double.ToString()`
is "G15" and the port's `PortSupport::ToWString(double)` matches that; a .NET Core original prints
shortest round-trip digits instead, so prefer fixed-format numbers in cases when comparing against
.NET Core builds.

## finish-unit.ps1

```text
-CppRoot <dir> -Unit <unit>   (required) runs scan-forbidden -> build-check -> port-status for the unit
-MaxRounds 3                  failed rounds before the unit is marked blocked (attempts kept in status.json)
-IncludeDir <dirs> / -Standard c++17 / -WorkDir <dir>
```

Prints one `RESULT:` line (`PASS`, `FAIL (round k of N)`, `FORBIDDEN (n)`, `BLOCKED`, `MISSING <file>`,
`NO_COMPILER`) and, after PASS/BLOCKED, a `NEXT: <unit>` line (first `todo` in work-list order).
Exit 0 PASS, 1 FAIL/FORBIDDEN/BLOCKED, 2 environment/input.

## port-status.ps1

```text
-CppRoot <dir> | -WorkDir <dir>   one of them (default .\port-work only when neither is given)
-Unit <unit | member file | a.cs+b.Designer.cs> -State todo|translated|builds|verified|blocked|skipped [-Note <text>]
-StaleDependents       with -Unit/-State: dependents already built go back to todo (header changed)
-DependentsOf -Unit U  list the units that depend on U with their states
-Next                  print NEXT: <first todo unit in PORT_ORDER.txt order>
-Show                  print totals (also regenerates PORT_STATUS.md)
```

## Local model context

`UNIT_PROMPT.md` is 3-5k tokens for a 30-line unit and 8-12k for a 300-line one. In paste mode that is
the whole request: `num_ctx` >= 16384. Inside Claude Code (agent mode) the harness system prompt, tool
schemas, `SKILL.md` and the `Read` of the prompt come on top: set `num_ctx` (Ollama: `OLLAMA_CONTEXT_LENGTH`
or a Modelfile) to at least 32768, 65536 recommended. Ollama's default 4096 truncates silently. Split
units above ~400 lines by hand.
