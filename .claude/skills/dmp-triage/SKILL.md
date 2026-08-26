---
name: dmp-triage
description: Clone-time Claude Code entrypoint for offline Windows process dump (.dmp / minidump) triage. Runs the bundled PowerShell CLI to produce a compact report - hang vs crash, threads and modules, native stacks via cdb, and .NET managed stacks without PDBs, with lock contention resolved to thread and method. Requires Windows and PowerShell 5.1+.
when_to_use: Use when the user asks to analyze a .dmp, minidump, hang dump, or crash dump, especially air-gapped. Korean triggers - 덤프 분석, 덤프 분석해줘, 프로세스 덤프, 미니덤프, 행 덤프, 멈춘 프로세스, 크래시 덤프, 폐쇄망 덤프 분석.
---

# DMP Triage Entrypoint

This is the Claude Code project-skill entrypoint that makes `/dmp-triage` available immediately
after cloning this repository and starting Claude Code from the repo root.

Before acting, read and follow the canonical skill contract at:

```text
skills/dmp-triage/SKILL.md
```

Use the bundled CLI from:

```text
skills/dmp-triage/scripts/dmp-triage.ps1
```

Treat any user arguments passed to `/dmp-triage` as the dump path plus context. Never open or parse
the `.dmp` yourself: run `check` then `analyze` per the canonical skill, then read `report-slim.md`.

The debugger binaries (`bin\debuggers\`, ~135 MB) are not committed. Without them `analyze` still
produces a pre-triage-only report and exits 1 — stage them once with
`skills/dmp-triage/tools/get-debuggers.ps1`.
