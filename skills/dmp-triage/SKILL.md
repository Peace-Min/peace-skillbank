---
name: dmp-triage
description: Analyze Windows process dumps (.dmp / minidump, e.g. Task Manager or procdump captures) offline with the bundled dmp-triage CLI - instant pre-triage (standard-or-not, hang vs crash, threads/contexts, module inventory), cdb native analysis (!analyze -hang, !uniqstack, !locks), and .NET managed stacks WITHOUT PDBs via SOS. Use when the user asks to analyze a .dmp, minidump, hang dump, or crash dump - especially on air-gapped machines or when the dump is too large to inspect by hand. Korean triggers - 덤프 분석, 프로세스 덤프, 미니덤프, 행 덤프, 크래시 덤프, 폐쇄망 덤프 분석.
---

# DMP Triage

Turn a Windows process dump (`.dmp`) into a compact, LLM-readable `report.md` -- offline, with no installation on the target machine.

## ⛔ Do NOT parse the dump yourself

A `.dmp` is an **opaque binary** (minidump format, often tens of GB). Hand-written byte parsing --
in Python or any language -- is a **proven failure path**: a real 21.9GB dump was manually parsed
for 5 hours by an LLM, which then misidentified a standard minidump as a "custom variant" and
wrongly concluded thread contexts were absent (they are located via per-thread record fields, not
signature scanning). Never write a parser, never scan the dump bytes, never read the dump file
directly.

Your ONLY job is to **run the bundled CLI** and interpret its TEXT output:

1. `scripts/dmp-triage.ps1 check -Dump <dmp>` -- 1-second dependency-free pre-triage
2. `scripts/dmp-triage.ps1 analyze -Dump <dmp>` -- full pipeline producing `report.md`

If cdb.exe cannot be resolved, `analyze` still produces the pre-triage report and prints how to
obtain the debuggers. **Report exactly what is missing** -- never substitute a parser or fabricate
stack contents. Do not read `raw\*.log` wholesale; pull specific `===SECTION:x===` excerpts only
when `report.md` lacks something.

## Default Behavior

When the user provides a `.dmp` path, run `check` then `analyze` immediately unless an essential
input is missing.

Default assumptions:

- Treat the first `.dmp` path in the prompt as `-Dump`.
- Use the CLI's default output directory (`.\dmp-triage-out\<name>-<stamp>\`) unless told otherwise.
- Do not pass `-Deep` unless the user asks for heap statistics or all-thread raw stacks.
- Pass `-SupportFiles <dir>` only when the report shows a DAC/SOS mismatch warning or the user
  provides source-machine binaries (matching exe/pdb, `mscordacwks.dll`, `sos.dll`, `clr.dll`).
- Pass `-Symbols <dir>` only when a local (never network) symbol store exists.
- `-TimeoutSec <n>` (default 3600 per debugger pass) only for very large dumps or quick smoke runs;
  `-NativeOnly` / `-ManagedOnly` to run a single track; `-CdbPath <cdb.exe>` to pin a debugger.
- Exit codes: 0 full success, 1 completed-but-degraded (non-standard dump, cdb missing, pass
  failed/timed out - report.md says which), 2 fatal error. Treat 1 as "read the report caveats".
- Ask a clarifying question only when there is no usable dump path.

## Workflow

1. `check -Dump <dmp>`: confirm standard minidump, hang vs crash, source OS, thread/context
   counts, main module. Report this verdict to the user first.
2. `analyze -Dump <dmp>`: produces `report.md`, `modules.csv`, `raw\native.log`, `raw\managed.log`.
3. Read `report.md` and interpret:
   - Verdict HANG -> the question is "what is it waiting for", not "why did it die".
   - `!runaway` (sec.4): a thread with outsized CPU time = spin/loop suspect; all-zero = blocking.
   - `!uniqstack` (sec.5): ignore normal waits (`WaitFor*`/`GetMessage`); flag odd stacks stuck in
     file IO, network, DRM/security/virtual-disk modules, or drivers.
   - `!syncblk` (sec.7.2): `MonitorHeld > 0` = real managed lock contention; trace the owner
     thread in sec.7.3 to draw the blocking chain.
   - Managed stack groups (sec.7.3): large groups are normal idle pools; the 1-2 thread groups and
     the UI thread (DBG 0) location are the key evidence.
   - If a WRONG_SYMBOLS note is present, ignore `!analyze` bucketing; sections 5 and 7 carry the
     real signal.
4. Conclude in this order: (1) one-line cause thread+stack, (2) evidence by report section/line,
   (3) confidence and what extra input would raise it (specific raw-log section or source-machine
   file).

## CLI

```powershell
$skillDir = "C:\path\to\peace-skillbank\skills\dmp-triage"
powershell -NoProfile -ExecutionPolicy Bypass -File "$skillDir\scripts\dmp-triage.ps1" check   -Dump C:\dumps\app.dmp
powershell -NoProfile -ExecutionPolicy Bypass -File "$skillDir\scripts\dmp-triage.ps1" analyze -Dump C:\dumps\app.dmp
```

## cdb acquisition and air-gap deployment

cdb is resolved in order: `bin\debuggers\` next to the script or at the skill root -> installed
Windows SDK Debuggers -> `cdb` on PATH -> the WinDbg store app. Nothing needs to be installed on
the analysis machine if `bin\debuggers\` is populated (Debugging Tools are xcopy-portable).

- Internet machine, one time: `tools\get-debuggers.ps1` (winget WinDbg -> stages ~135MB into
  `bin\debuggers\`), then `dmp-triage.ps1 package` -> single USB zip (~57MB).
- Air-gapped machine: unzip, run `analyze`. No install, no admin, no network
  (`-netsyms:no` blocks symbol-server attempts).
- `bin\debuggers\` and package zips are never committed (gitignored).

Read `references/air-gap-deployment.md` for the full transfer procedure and troubleshooting
(DAC mismatch, native PDB limits, .NET Core SOS note).

## Execution Policy

Run the script directly in PowerShell (`powershell`, or `pwsh` when available). Do not call it
through Git Bash, `cmd /c "..."`, or nested shells; nested quoting corrupts arguments and breaks
non-ASCII (for example Korean) paths. Pass the dump path as-is and quoted; the script reads files
via .NET and handles Unicode.

## Model-Agnostic Usage

This skill is model-independent. For any LLM environment, generate `report.md` first, then provide:

- `references/model-agnostic-prompt.md` (prompt A for agentic LLMs that can run the CLI,
  prompt B for chat-only LLMs that receive `report.md` as pasted text)
- `report.md`
- what the user was doing when the process hung/crashed

## Outputs (never commit)

- `report.md`: the LLM input -- pre-triage + !analyze highlights + unique native stacks +
  lock analysis + deduplicated managed stack groups.
- `modules.csv`: full module inventory (base, size, timestamp, path).
- `raw\native.log`, `raw\managed.log`: full cdb output, split by `===SECTION:x===` markers.
