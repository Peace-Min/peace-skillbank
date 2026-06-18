---
name: diagsession-memory-analysis
description: Clone-time Claude Code entrypoint for analyzing Visual Studio .diagsession and .gcdump snapshots for .NET managed memory leaks. Use when extracting embedded gcdump snapshots from VS profiler diagsession files, generating dotnet-gcdump reports, preparing model-agnostic LLM memory-leak inputs, comparing before/after managed heap snapshots, or deciding when diagsession/native profiler data is needed beyond gcdump.
---

# DiagSession Memory Analysis Entrypoint

This is the Claude Code project-skill entrypoint that makes `/diagsession-memory-analysis`
available immediately after cloning this repository and starting Claude Code from the repo root.

Before acting, read and follow the canonical skill contract at:

```text
skills/diagsession-memory-analysis/SKILL.md
```

Use bundled scripts and references from:

```text
skills/diagsession-memory-analysis/
```

Treat any user arguments passed to `/diagsession-memory-analysis` as the input paths and context for
the canonical skill.
