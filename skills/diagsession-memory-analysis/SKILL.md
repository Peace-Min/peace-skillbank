---
name: diagsession-memory-analysis
description: Analyze Visual Studio .diagsession and .gcdump snapshots for .NET managed memory leaks. Use when extracting embedded gcdump snapshots from VS profiler diagsession files, generating dotnet-gcdump reports, preparing model-agnostic LLM memory-leak inputs, comparing before/after managed heap snapshots, or deciding when diagsession/native profiler data is needed beyond gcdump.
---

# DiagSession Memory Analysis

Use this skill to turn Visual Studio `.diagsession` or `.gcdump` files into model-readable managed-memory leak evidence and a follow-up handoff summary.

## Default Behavior

When the user provides one or more `.diagsession` or `.gcdump` paths, run the bundled extraction/report script immediately unless an essential input is missing.

Default assumptions:

- Treat paths in the prompt as `-InputPath` in the order given.
- A single `.diagsession` may contain multiple snapshots; extract it first, then inspect `MANIFEST.txt`.
- If the user gives an action count, repeated action, start point, or related files, include them in the analysis context.
- If snapshot order is not explicit, assume archive/input order is chronological and state that assumption.
- Use the script's default output directory unless the user specifies one.
- Do not pass `-IncludeFullPathsInLlmInput` unless the user asks for full local paths.
- Do not pass `-KeepExtractedGcdump` unless the user asks to preserve extracted dumps.
- Use `-ToolPath` only when `dotnet-gcdump` cannot be resolved automatically and the user provides a location.
- Ask a clarifying question only when there is no usable input path, fewer than two snapshots after extraction, or snapshot order cannot be reasonably inferred.

## Workflow

1. Parse the prompt for input paths, repeated action, count, start point, related files, and ordering hints.
2. Run `scripts/extract-gcdump-reports.ps1` with the parsed paths.
3. Read `MANIFEST.txt` and `LLM_MEMORY_INPUT.txt`.
4. Compare snapshots in declared or assumed order.
5. Identify growing app-owned types by both `Size` and `Count`.
6. Map plausible app-owned types and containers to retention hypotheses and source areas.
7. Report assumptions, candidates, evidence, confirmation steps, limitations, and a handoff summary.

## CLI

The script expects `dotnet-gcdump` on `PATH`, at `C:\tools\dotnet-gcdump`, or via `-ToolPath`.

```powershell
$skillDir = "C:\path\to\peace-skillbank\skills\diagsession-memory-analysis"
powershell -NoProfile -ExecutionPolicy Bypass -File "$skillDir\scripts\extract-gcdump-reports.ps1" -InputPath <paths>
```

Read `references/cli-usage.md` only when custom paths, full-path output, preserved extracted dumps, or troubleshooting details are needed.

- `LLM_MEMORY_INPUT.txt`: combined report text for Codex or another LLM.
- `MANIFEST.txt`: source file and extracted snapshot mapping.
- `reports/`: one `.heapstat.txt` per snapshot.

## Execution Policy

Run the script directly in PowerShell (`powershell`, or `pwsh` when available). Do not call it through Git Bash, `cmd /c "..."`, or nested shells — nested quoting corrupts arguments and breaks non-ASCII (for example Korean) paths. Pass each path as-is and quoted; the script reads files via .NET and handles Unicode, so do not copy or rename to an ASCII path, and note that Git Bash `/tmp` is not `C:\tmp`. If `dotnet-gcdump` is not resolved automatically, pass `-ToolPath` rather than guessing.

## Model-Agnostic Usage

This skill is model-independent. For any LLM environment without direct tool access, generate `LLM_MEMORY_INPUT.txt` first, then provide:

- `references/model-agnostic-prompt.md`
- `LLM_MEMORY_INPUT.txt`
- repeated action description
- project structure and relevant code entry point
- before/after ordering of snapshots

If context is limited, provide only:

1. repeated action description
2. top growing app-owned types by size
3. top growing app-owned types by count
4. container clues and retention hypotheses
5. relevant source files

## Analysis Rules

- Treat `.gcdump` as managed heap evidence, not full process memory evidence.
- If a `.diagsession` contains `.heapstate` or `.dmp` entries but no `.gcdump`, report it as unsupported by this gcdump-only parser instead of fabricating heap analysis.
- Do not claim native, COM, GDI, WPF image, unmanaged buffer, or handle leaks from `.gcdump` alone.
- A single snapshot shows retained objects at one point in time; before/after snapshots are needed for leak growth.
- If process memory grows but `.gcdump` growth does not explain it, escalate to full `.diagsession`, native memory tools, handle counters, or Visual Studio allocation stacks.
- Prefer concrete retention hypotheses: event subscription, static cache, timer, long-lived collection, closure capture, dispatcher queue, service lifetime mismatch, or missing `Dispose`.
- Connect growing types back to source code only when names or ownership make that inference plausible.

## Scope Boundary

This skill is analysis-only. Do not modify source code, create commits, or apply fixes as part of this skill unless the user explicitly starts a separate fix task. Produce a handoff summary that another coding session or fix-oriented skill can use.

## Expected Output

Produce a concise report with:

1. assumptions used, including snapshot ordering
2. snapshot mapping from `MANIFEST.txt`
3. likely leak candidates ordered by confidence
4. evidence from `Size`, `Count`, and type names
5. code areas to inspect first
6. what would confirm or falsify each hypothesis
7. limitations of the available evidence
8. handoff summary for a follow-up fix session

Also write this report to `ANALYSIS.md` in the script's output directory (next to `MANIFEST.txt`), so a later fix session can resume from the file alone instead of relying on chat history. Keep the report's structure flexible; for strict loop validation or machine-checkable handoff reports, use the exact headings in `references/standard-report-template.md`.
