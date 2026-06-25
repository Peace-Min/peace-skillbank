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
- Ask a clarifying question only when there is no usable input path, or when before/after comparison is requested but snapshot order cannot be reasonably inferred.
- If there is only one snapshot, continue with inventory analysis and clearly state that growth comparison is unavailable.

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

Run the script directly in PowerShell (`powershell`, or `pwsh` when available). Do not call it through Git Bash, `cmd /c "..."`, or nested shells; nested quoting corrupts arguments and breaks non-ASCII (for example Korean) paths. Pass each path as-is and quoted; the script reads files via .NET and handles Unicode, so do not copy or rename to an ASCII path, and note that Git Bash `/tmp` is not `C:\tmp`. If `dotnet-gcdump` is not resolved automatically, pass `-ToolPath` rather than guessing.

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

`.gcdump` captures only the managed heap at a single point in time. Because of that boundary:

- It cannot evidence native, COM, GDI, WPF-image, unmanaged-buffer, or handle leaks; surface those as escalation candidates, not findings.
- A single snapshot is only an inventory; leak *growth* needs before/after snapshots.
- A `.diagsession` with `.heapstate`/`.dmp` but no `.gcdump` is unsupported by this gcdump-only parser; report that rather than fabricating heap analysis.
- If process memory grows but managed-heap growth does not explain it, escalate to full `.diagsession`, native memory tools, handle counters, or Visual Studio allocation stacks.

The Size/Count comparison, container clues, and retention-hypothesis taxonomy live in `references/model-agnostic-prompt.md`; use them there rather than restating them here. Connect growing types back to source only when names or ownership make the inference plausible.

## Root-cause evidence (optional enrichment)

`LLM_MEMORY_INPUT.txt` may carry extra root-cause evidence. Get it in the **default run** by passing
`-AfterDumpPath <after.dmp> [-RootChainToolExe <exe>]` to `extract-gcdump-reports.ps1` (it folds the
evidence in automatically), or run `scripts/enrich-root-chains.ps1` separately. Either way it degrades
gracefully -- no `.dmp` / tool, or <2 snapshots, just means HeapStat-only with a clear note.

- **`## Heap growth summary`** -- candidates ranked by Delta Size + Delta Count; both-increased
  app-owned types are highest priority, retention containers are clues (not conclusions), and the
  native boundary line tells you when to escalate.
- **`## Reference-chain evidence`** -- managed paths-to-root per candidate (from `after.dmp` via ClrMD),
  grouped with coverage. A `Stack` root means the object is currently **in use, not leaked**. Every other
  root kind is retained, but the *reason differs by kind* -- read the report's `rootInterpretation` and do
  NOT lump all non-Stack roots together as one "static leak":
    - **StrongHandle** -- likely a static / long-lived cache (a leaked **static field** appears as
      `StrongHandle -> Object[] -> holder`, not a "Static" kind).
    - **PinnedHandle / AsyncPinnedHandle** -- pinning / interop / native pressure, not a plain managed cache.
    - **FinalizerQueue** -- a Dispose / finalizer-backlog delay, not a permanent root.
    - **RefCountedHandle** -- a COM / interop ref-counted lifetime to check.
  Treat **unresolved** instances (which may lie beyond the max-depth / node-budget caps, or be unrooted)
  and a **sampled** (uniform reservoir) coverage as incomplete evidence, never a confirmed root cause.

When this evidence is present, ground retention claims in it instead of guessing the container. When it
is absent or says "root-chain unavailable", fall back to HeapStat candidates + the native escalation
boundary above.

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
