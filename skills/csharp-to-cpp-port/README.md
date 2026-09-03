# csharp-to-cpp-port

You have a C# project (.NET Framework 4.7 or .NET) that must become native Windows C++, and the
model doing the typing is a weak or local one. Handing it the whole project fails in predictable
ways: silent context truncation, invented headers, no place to plug compiler feedback in. This skill
makes the port a deterministic loop where scripts do the fragile work and the model ports exactly
one unit per step against a fixed mapping table.

Full human guide (Korean): [docs/csharp-to-cpp-port-usage.md](../../docs/csharp-to-cpp-port-usage.md).

## The loop

```text
inventory-csharp.ps1   whole tree -> units (partial classes merged, generated files skipped),
   |                   dependency order (cycles as groups), prerequisites for a -Scope pass
   v  for each unit
make-unit-prompt.ps1   mapping table + rules + source + PORTED headers (or NOT PORTED declarations)
   |                   + last build errors -> UNIT_PROMPT.md ; prints UnportedDeps: N
   v  model writes <path>.h + <path>.cpp with its file tool (or apply-unit-response.ps1 from a reply)
scan-forbidden.ps1     no C++/CLI, no raw new/delete, no printf, no wofstream, no elided bodies
build-check.ps1        MSVC (vswhere, explicit env) or MinGW g++ -> BUILD_RESULT.txt (file|line|code|msg)
   |  FAIL -> back to make-unit-prompt (errors embedded), max 3 rounds, then "blocked"
   v  PASS
port-status.ps1        todo -> translated -> builds -> verified ; -StaleDependents after a re-port
   |
   v  after the last unit
build-check.ps1 -All -Link, parity-check.ps1   original C# exe vs C++ exe on the same inputs
```

## Directory-by-directory work

Assign a directory per pass with `-Scope Services`. The whole tree is still scanned, the work list
gains that directory's not-yet-ported prerequisites (marked `prereq`, ported first), and
`EXTERNAL_DEPS.txt` lists what the directory needs from elsewhere. There are no guessed stubs: a
dependency is either its real ported header or a "NOT PORTED, port it first" declaration list.

## What is fixed, what you decide

- Fixed in `references/mapping-table.md`: modern C++17 idioms (`[[nodiscard]]`, `noexcept`, `override`,
  `auto`, range-for, no C casts), `std::wstring`, ownership computed by the inventory per type (SHARED ->
  `std::shared_ptr`, SINGLE -> value or `std::unique_ptr`; the model never decides), RAII for `IDisposable`, synchronous port of `async` (marked
  `TODO(port)`), `enum class` + `ToString/TryParse`, exceptions, and `PortSupport.h` helpers for the
  places where naive C++ silently differs from .NET (double/bool formatting, UTF-8 file output,
  console encoding).
- You decide: the UI framework for WinForms/WPF code (none is assumed; `references/ui-win32.md` and
  `references/ui-mfc.md` are ready-made row sets to drop into `port-work/mapping-extra.md`), COM,
  `unsafe`, reflection, real concurrency.

## Verified with

`tests/fixtures/csharp-to-cpp-port/`:

- `sample-app`: a real .NET console app (LINQ, `event`, `IDisposable`, `async`, P/Invoke, `int?`,
  `string.Format`, Korean text, double/bool output, numeric enum parsing) with a hand-written golden
  C++17 port that builds with MinGW and produces byte-identical output on four argument cases.
- `realish`: a .NET-4.7-shaped tree (partial WinForms form + Designer, generic interface/class, nested
  enum, `#if`, extension method, a Node/Tree cycle, an `Item` name clash, AssemblyInfo, Resources) used
  to assert unit grouping, skipping, SCC cycle reporting, namespace resolution and prerequisite order.
- `tests/csharp-to-cpp-fixtures.ps1` also covers the negative paths (no `.cs` files, missing compiler,
  unsafe/truncated replies, forbidden constructs), the round-2 prompt after a build failure, and that
  `references/example-port.md` itself compiles.

MinGW g++ is the compiler that produced real binaries here. The MSVC branch (environment construction,
`/Fo` `/Zs` `/std:` arguments, `file(line): error Cnnnn:` parsing, `link.exe` with `-LinkArgs`) is
exercised by the fixtures against a fake `cl.exe`/`link.exe` that honours the real contracts; a real
MSVC compile still awaits a machine with the C++ workload. The eval loop's HTTP path is exercised
against a fake OpenAI-compatible endpoint (UTF-8 without charset, `<think>` blocks, heading-shaped replies).

## Limits

Regex inventory (not Roslyn), parity only for deterministic console output, no UI-framework rows by
default, `async` ported synchronously. See the "Limitations" section of `SKILL.md`.
