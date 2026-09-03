---
name: csharp-to-cpp-port
description: Ports an existing C# project (.NET Framework 4.7 or .NET) to native Windows C++17 one unit at a time with a deterministic loop designed for weak or local models (Qwen/Ollama-class) - dependency-ordered inventory of the C# tree (partial classes merged, generated files skipped), per-unit prompt assembly with a FIXED C#-to-C++ mapping table (std::wstring, RAII, shared_ptr, PortSupport.h helpers), MSVC/MinGW build check that feeds compact errors back into the next prompt, a forbidden-pattern scan (no C++/CLI, no raw new, no printf), and C#-vs-C++ output parity. Use whenever the user asks to convert, translate, migrate or port C# / .NET code to C++ (C#을 C++로 변환, C# 코드 C++ 포팅, 닷넷 프로젝트를 네이티브 C++로 이식, 디렉토리 단위로 C++ 변환) - directory by directory or file by file, never the whole project at once.
---

# C# to C++ Port (one unit at a time)

You are porting a C# project to Windows C++17. The scripts do the fragile work (dependency order,
prompt assembly, build check, scanning, parity); you port exactly ONE unit per step and never
re-decide project choices. A unit is one `.cs` file, or the files of one `partial` class together.

## Default Behavior

When the user names a C# project or directory:

1. Run `inventory-csharp.ps1 -SourceRoot <C# root> -CppRoot <C++ root>` (add `-Scope <relative dir>`
   when the user assigned a sub-directory; the whole tree is still scanned and the work list gains the
   out-of-scope prerequisites, marked `prereq`). All outputs go to `<C++ root>\port-work\`.
   For a solution of several projects, point `-SourceRoot` at the folder that contains ALL of them and
   use ONE `-CppRoot`: cross-project uses become ordinary dependencies, so a shared component is ported
   once and every consumer includes the same header. Per-project libraries/executables are not generated.
2. Read `PORT_INVENTORY.md` and `DECISIONS.md`. Tell the user: project kind, unit count, skipped files,
   the project table and cross-project dependencies when there is more than one `.csproj`, feature totals
   that need a human decision (`winforms`, `wpf`, `pinvoke`, `reflection`, `unsafe`, `dynamic`,
   `threading`), cycle groups, ambiguous references, `EXTERNAL_DEPS.txt` entries, and how many decisions
   are pending review. `DECISIONS.md` is seeded automatically with every standing default that applies to
   this project; it is the list the user reviews at the end, so nothing is decided silently.
3. If the project is WinForms/WPF, stop and ask which UI framework the C++ side uses. For Win32 or MFC,
   copy `references/ui-win32.md` or `references/ui-mfc.md` to `<C++ root>\port-work\mapping-extra.md`
   (its rows are appended to the mapping table automatically); anything else needs rows written by the
   human. Until that file exists, `make-unit-prompt.ps1` prints `UiMappingMissing: 1` for `ui` units and
   they must be left `todo`. Non-UI units proceed regardless.
4. Run the per-unit loop in `PORT_ORDER.txt` order, starting at the first `todo` unit in `PORT_STATUS.md`.

Do not ask for mapping decisions: `references/mapping-table.md` is final unless the user edits it.

## Per-unit loop

For the unit `U` (its path from `PORT_ORDER.txt`, written with `/`; a partial unit shows its files joined
with `+`):

1. `make-unit-prompt.ps1 -Unit U -CppRoot <C++ root>` writes `port-work\UNIT_PROMPT.md` and prints
   `UnportedDeps: N` and `BlockedDeps: M`.
   - `M > 0`: do not port `U`. Run `port-status.ps1 -CppRoot <C++ root> -Unit U -State blocked -Note
     "waiting on <dep>"` and go to the unit on its `NEXT:` line.
   - `N > 0` and the prompt does not say the dependency is a cycle with `U`: do not port `U`; port the
     listed dependencies first (they are earlier in `PORT_ORDER.txt`), then come back.
2. Read `UNIT_PROMPT.md` in full and do exactly what its last section says: create the named file(s)
   under the C++ root with your file-writing tool (`<path>.h` + `<path>.cpp`; only the `.cpp` for the
   file holding `Main`), complete. Never paste code into the chat, never touch `PortSupport.h` or a
   PORTED header.
3. Run the `finish-unit.ps1` command printed at the end of the prompt (forbidden scan -> build check
   -> status, in one step) and act on its `RESULT:` line:
   - `PASS`: take the unit on the `NEXT:` line and go to step 1.
   - `FAIL (round k of 3)`: re-run step 1 for `U` (the errors are now embedded), fix ONLY those errors
     in the files you wrote, run `finish-unit.ps1` again.
   - `FORBIDDEN`: fix the listed constructs, run `finish-unit.ps1` again (no round is used).
   - `BLOCKED`: the unit is marked blocked after 3 rounds; take the `NEXT:` unit and report the blocked
     unit to the user at the end.
   - `NO_COMPILER` / `MISSING`: relay the message to the user verbatim.

After the last unit: `build-check.ps1 -CppRoot <C++ root> -All -Link -OutputExe <exe>`; if the user
has the original program built and a `cases\` directory, run `parity-check.ps1 -CppRoot <C++ root>
...` and mark units `verified` with `port-status.ps1 -CppRoot <C++ root> -Unit U -State verified`
when `PARITY_RESULT.txt` says `PASS`. Finally run `review-report.ps1 -CppRoot <C++ root>` and give the
user `REVIEW.md`: the decisions still to confirm, every `TODO(port)` marker grouped by note, the blocked
and skipped units, and the last build/parity status. That file is the hand-over.

## Hard rules

- Never put the whole project, or more than one unit, into a prompt. Dependencies enter as their
  ported headers, or as C# declarations marked NOT PORTED.
- Never invent a declaration, header, or API. Missing pieces get `// TODO(port): needs ...` at the use
  site and are reported.
- Never ask the user how to map a type or construct (Color, enum, App.config, threading...). The mapping
  table decides; with no row, take the closest one and write `// TODO(port): <assumption>`. The only
  genuine questions are the UI framework and unblocking a `blocked` unit. Ask those ONCE, then record the
  answer immediately: `record-decision.ps1 -CppRoot <C++ root> -Id <id> -Decision "..." -Source human
  -Rationale "..." -Review "why it may need revisiting"`. An answer that is not recorded is lost.
- Every function body in full. No `// ...`, no "rest unchanged", no partial files.
- Modern C++17 only: `std::wstring` strings, ownership exactly as the prompt's computed list says
  (SHARED -> `std::shared_ptr`, SINGLE -> value or `std::unique_ptr`), `[[nodiscard]]`/`noexcept`/`override`,
  `PortSupport::ToWString` for numbers and bools, no C++/CLI syntax, no raw `new`/`delete`, no C casts,
  no `std::wofstream`.
- A `PASS` from build-check means it compiles, not that it is correct. Only parity or a human review
  moves a unit to `verified`.
- If build-check reports `NO_COMPILER`, relay its "Checked" and "Remedy" lines verbatim; do not guess
  at compiler paths.
- Marks in `PORT_ORDER.txt`: `prereq` = out-of-scope but required first; `cycle` = port the group
  together with forward declarations; `partial`/`designer` = one unit from several files; `ui` = needs
  the UI framework decision. Files listed under "Skipped" are never ported.
- Generic classes/interfaces are templates with every definition in the header; nothing else changes.
- After `PortSupport::InitConsole()` only `std::wcout`/`std::wcerr` may write to the console; any narrow
  write (`std::cout`, `printf`, `puts`, `fwrite`) silently discards all later output.

## Running the scripts

Use the PowerShell tool when the harness has one. Otherwise, from the shell tool, call
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File <script> <args>` directly (one level; never
`cmd /c powershell ...`, never Git Bash paths), because nested quoting breaks non-ASCII (Korean) paths.
Scripts find MSVC via vswhere and build the compiler environment themselves; MinGW `g++` is the
fallback. Nothing is downloaded or installed. `references/cli-usage.md` has every parameter.

```powershell
$skill = "C:\path\to\peace-skillbank\skills\csharp-to-cpp-port"
powershell -NoProfile -ExecutionPolicy Bypass -File "$skill\scripts\inventory-csharp.ps1" -SourceRoot C:\src\MyApp -CppRoot C:\src\MyApp.Cpp [-Scope Services]
powershell -NoProfile -ExecutionPolicy Bypass -File "$skill\scripts\make-unit-prompt.ps1" -Unit Services/Logger.cs -CppRoot C:\src\MyApp.Cpp
powershell -NoProfile -ExecutionPolicy Bypass -File "$skill\scripts\finish-unit.ps1" -CppRoot C:\src\MyApp.Cpp -Unit Services/Logger.cs
powershell -NoProfile -ExecutionPolicy Bypass -File "$skill\scripts\port-status.ps1" -CppRoot C:\src\MyApp.Cpp -Next
```

Write unit paths with forward slashes (`Services/Logger.cs`): a backslash typed from a Bash-style shell
tool is swallowed. Every script accepts either separator. Always pass `-CppRoot` (or `-WorkDir`);
scripts never guess the working folder from the harness's current directory.

## Outputs (`<C++ root>\port-work\`)

`DECISIONS.md` / `decisions.json` (every project-level choice and its review status), `REVIEW.md` (the
end-of-port hand-over); `PORT_INVENTORY.md`, `PORT_ORDER.txt`, `EXTERNAL_DEPS.txt`, `inventory.json`; `PORT_STATUS.md` /
`status.json` (`todo -> translated -> builds -> verified`, `blocked`, `skipped`; `NEXT:` = first todo in
work-list order); `UNIT_PROMPT.md`;
`BUILD_RESULT.txt` (`Status`, `Unit:` lines, `file|line|code|message`); `PARITY_RESULT.txt`.
`PortSupport.h` is placed in the C++ root on first use.

## Model-Agnostic Usage

`make-unit-prompt.ps1 -Mode paste` produces a prompt for a model without tools: paste it, save the
reply as `port-work\MODEL_RESPONSE.md`, run `apply-unit-response.ps1 -ResponsePath ... -CppRoot ...
-Expect <path>.h,<path>.cpp`, continue at step 3. `references/model-agnostic-prompt.md` is
the system instruction for that case.

## Limitations

- The inventory is a regex scan, not Roslyn: flag counts are approximate; a type reached only through
  inheritance or an extension method can be missed; ambiguous references are listed for a human.
- Units are ported leaf-first; there are no guessed stubs. A directory assigned before its
  prerequisites simply pulls those prerequisites into the work list.
- Parity needs deterministic console output and the original C# build.
- UI frameworks, COM, reflection-heavy code, real concurrency, and `unsafe` blocks need human
  decisions first; `async` is ported synchronously and marked `TODO(port)`.
- The MSVC branch of build-check has been exercised for discovery only on a partial install; MinGW is
  the verified compiler. Report the first MSVC run's result.
