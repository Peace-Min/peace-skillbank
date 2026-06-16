---
name: diagsession-memory-analysis
description: Analyze Visual Studio .diagsession and .gcdump snapshots for .NET managed memory leaks. Use when extracting embedded gcdump snapshots from VS profiler diagsession files, generating dotnet-gcdump reports, preparing LLM or local LLM memory-leak inputs, comparing before/after managed heap snapshots, or deciding when diagsession/native profiler data is needed beyond gcdump.
---

# DiagSession Memory Analysis

Use this skill to turn Visual Studio `.diagsession` or `.gcdump` files into model-readable memory leak evidence, then analyze before/after managed heap growth.

## Core Workflow

1. Confirm the user has a repeated action and at least one before/after snapshot.
2. Prefer `.gcdump` analysis first when the suspected leak is .NET managed memory.
3. Run `scripts/extract-gcdump-reports.ps1` to extract embedded `.gcdump` files from `.diagsession` archives and generate `dotnet-gcdump report` output.
4. Use the generated `LLM_MEMORY_INPUT.txt` as the primary model input.
5. Ask for or inspect the relevant code path: UI action entry point, command handler, service flow, subscriptions, caches, timers, static state, and collection ownership.
6. Prioritize types that grow by both `Size` and `Count`, especially app-owned types and containers that retain app-owned objects.

## CLI Usage

The bundled script expects `dotnet-gcdump.exe` to already be installed.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\extract-gcdump-reports.ps1 -InputPath C:\dumps\before.diagsession,C:\dumps\after.diagsession -ToolPath C:\tools\dotnet-gcdump
```

For direct `.gcdump` files:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\extract-gcdump-reports.ps1 -InputPath C:\dumps\before.gcdump,C:\dumps\after.gcdump -ToolPath C:\tools\dotnet-gcdump
```

The output directory contains:

- `LLM_MEMORY_INPUT.txt`: combined report text for Codex or a local LLM.
- `MANIFEST.txt`: source file and extracted snapshot mapping.
- `reports/`: one `.heapstat.txt` per snapshot.

Use `-KeepExtractedGcdump` only when the user wants extracted `.gcdump` files preserved.

## Local LLM Usage

This skill is model-independent. For local LLMs, do not assume tool access. Generate `LLM_MEMORY_INPUT.txt` first, then provide:

- `references/local-llm-prompt.md`
- `LLM_MEMORY_INPUT.txt`
- repeated action description
- project structure and relevant code entry point
- before/after ordering of snapshots

If context is limited, provide only:

1. repeated action description
2. top growing app-owned types by size
3. top growing app-owned types by count
4. suspicious containers and roots
5. relevant source files

## Analysis Rules

- Treat `.gcdump` as managed heap evidence, not full process memory evidence.
- Do not claim native, COM, GDI, WPF image, unmanaged buffer, or handle leaks from `.gcdump` alone.
- A single snapshot shows retained objects at one point in time; before/after snapshots are needed for leak growth.
- If process memory grows but `.gcdump` growth does not explain it, escalate to full `.diagsession`, native memory tools, handle counters, or Visual Studio allocation stacks.
- Prefer concrete retention hypotheses: event subscription, static cache, timer, long-lived collection, closure capture, dispatcher queue, service lifetime mismatch, or missing `Dispose`.
- Connect growing types back to source code only when names or ownership make that inference plausible.

## Expected Output

Produce a concise report with:

1. likely leak candidates ordered by confidence
2. evidence from `Size`, `Count`, and type names
3. code areas to inspect first
4. what would confirm or falsify each hypothesis
5. limitations of the available evidence

