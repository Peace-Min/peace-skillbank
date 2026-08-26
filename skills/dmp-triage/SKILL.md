---
name: dmp-triage
description: Analyze Windows process dumps (.dmp / minidump, e.g. Task Manager or procdump captures) offline with the bundled dmp-triage CLI - pre-triage (standard-or-not, hang vs crash, threads/contexts, modules), cdb native analysis (!analyze -hang, !uniqstack, !locks), and .NET managed stacks WITHOUT PDBs via SOS, with lock contention resolved to thread + method automatically. Requires Windows and PowerShell 5.1+; the debugger binaries are staged once per machine, not shipped in the repo.
when_to_use: Use when the user asks to analyze a .dmp, minidump, hang dump, or crash dump - especially on air-gapped machines or when the dump is too large to inspect by hand. Korean triggers - 덤프 분석, 덤프 분석해줘, 프로세스 덤프, 미니덤프, 행 덤프, 멈춘 프로세스, 크래시 덤프, 폐쇄망 덤프 분석.
---

# DMP Triage

Turn a Windows process dump (`.dmp`) into a compact, LLM-readable report — offline, with no
installation on the analysis machine.

## First action

When the user's message contains a `.dmp` path, your **first tool call** is this CLI. `<SKILL>` is
this skill's own directory (the base directory given to you when this skill was loaded; for a
plugin install, `${CLAUDE_PLUGIN_ROOT}\skills\dmp-triage`):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<SKILL>\scripts\dmp-triage.ps1" check -Dump "<DMP>"
```

This CLI is your only way to reach a dump. What you analyze is not the `.dmp` — it is the **text
report** the CLI writes for you. A `.dmp` is an opaque binary of tens of GB; opening it with
Read/cat/python cannot work and has burned days of effort before. Never write a dump parser, never
scan dump bytes, never read the dump file directly, and never invent stack contents that the report
does not contain.

## Minimum path (follow these 4 steps; a small/offline model should do only these)

1. Run `check` (above). Show the user the `Verdict` line verbatim, then continue.
2. Run `analyze`:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File "<SKILL>\scripts\dmp-triage.ps1" analyze -Dump "<DMP>"
   ```
   Add no other flags. The last lines print the paths of `report.md` and `report-slim.md`.
3. Check the branch table below for the literal strings it names. Then read **`report-slim.md`**
   (~8 KB: what the dump is + lock contention already resolved + the small thread groups). Read
   `report.md` only when the slim report is inconclusive; never read `raw\*.log` wholesale.
4. Report in the user's language: (1) one-line cause — the thread and the method it is stuck in,
   (2) evidence by section, (3) confidence, and what extra input would raise it. Write `모름` /
   "unknown" for anything the report does not state. Never fill a gap by guessing.

### Branch table (match the literal string, no judgment needed)

| If the output contains | Then |
|---|---|
| `cdb.exe not found` | Stop. Only pre-triage ran. Tell the user the debuggers are not staged and point at "Getting cdb" below. Do not attempt any other analysis method. |
| `CLR not present` | Native-only process. Sections 7.x do not exist — do not look for them. Use sections 1 and 5. |
| `DAC/SOS version mismatch` | Report normally, then add: copy `mscordacwks.dll`, `sos.dll`, `clr.dll` from the source machine into a folder and re-run with `-SupportFiles <folder>`. |
| `timed out` | Say that section is incomplete and report from the rest. |
| `PARSE ABORTED` / `NOT a minidump` | The file is truncated or not a dump. Say so; do not try to parse it yourself. |

Exit codes: `0` full success, `1` completed but degraded (the report says which), `2` fatal error.

## Reading the report (only when the slim report is not enough)

- Verdict `HANG` → the question is "what is it waiting for", not "why did it die". `CRASH` → the
  exception code, address and faulting thread are already in section 1 and 3b.
- **Section 7.0 is the answer for managed hangs.** The CLI has already joined lock owners to their
  stacks and printed `CONTENDED SyncBlock …` / `DEADLOCK PATTERN …` lines. Prefer these over
  re-deriving anything from 7.2/7.3 yourself.
- `!syncblk` (7.2) raw rows: `MonitorHeld` = 1 (owned) + 2 per waiter, so **only ≥ 3 means a thread
  is actually blocked**; `1` is a healthy uncontended lock.
- `!runaway` (4): a thread with outsized CPU time is a spin suspect; all-near-zero means blocking,
  not spinning.
- `!uniqstack` (5): `WaitFor*` / `GetMessage` are normal waits. What matters is a stack parked in
  file IO, network, or a third-party module (DRM, security, virtual disk, drivers).
- Managed groups (7.3): large groups are idle thread pools; the 1–3 thread groups carry the signal.
- A `WRONG_SYMBOLS` note means `!analyze` bucketing is noise — sections 5 and 7 hold the real signal.

## Default behavior

- Treat the first `.dmp` path in the prompt as `-Dump`; use the CLI's default output directory.
- Add `-Deep` only if the user asks for heap statistics or all-thread raw stacks.
- `-SupportFiles <dir>` only on a DAC/SOS mismatch or when the user supplies source-machine binaries;
  `-Symbols <dir>` only for a local (never network) symbol store; `-TimeoutSec <n>` (default 3600 per
  pass) only for very large dumps or quick smoke runs; `-NativeOnly` / `-ManagedOnly` to run one
  track; `-CdbPath <cdb.exe>` to pin a debugger.
- Ask a clarifying question only when there is no usable dump path.

## Getting cdb (required once per machine)

The repo does **not** ship the debugger binaries (~135 MB). Without them `analyze` still runs and
produces a pre-triage-only report with exit code 1. cdb is resolved in this order: `bin\debuggers\`
next to the script or at the skill root → installed Windows SDK Debuggers → `cdb` on PATH → the
WinDbg store app.

- Machine with internet: run `tools\get-debuggers.ps1` once (installs WinDbg via winget, then stages
  cdb into `<SKILL>\bin\debuggers\`). Then `tools\build-offline-installer.ps1 -Zip` builds a one-call
  offline installer (~53 MB): the air-gapped user double-clicks `setup.cmd` and it verifies the
  payload, unpacks the debuggers, installs the skill and self-tests — no admin, no network. Add
  `-SplitMB 90` when the package must travel through a 100 MB-per-file limit.
- Air-gapped machine: unzip that package anywhere and run `analyze` from it — no install, no admin,
  no network (`-netsyms:no` blocks symbol-server attempts). Or copy any existing
  `Windows Kits\10\Debuggers\x64` folder from the closed network into `<SKILL>\bin\debuggers\`.

`references/air-gap-deployment.md` has the full transfer procedure and troubleshooting.

## Execution policy

Run the script with the **PowerShell** tool (`powershell`, or `pwsh` when available), passing the
dump path quoted and unchanged. Do not route it through Git Bash, `cmd /c "..."`, or nested shells —
nested quoting corrupts arguments and breaks non-ASCII (for example Korean) paths.

Windows only. On macOS or Linux, say so instead of attempting a run.

## Model-agnostic usage

For any other LLM environment, generate the report first, then hand over
`references/model-agnostic-prompt.md` (prompt A for models that can run the CLI, prompt B for
chat-only models) together with `report-slim.md` and what the user was doing when the process hung.

## Outputs (never commit)

- `report-slim.md` — read this first: what the dump is, contention already resolved, small groups.
- `report.md` — all sections: pre-triage, `!analyze` highlights, CPU time, unique native stacks,
  lock analysis, and the managed 7.0–7.3 breakdown.
- `modules.csv` — full module inventory. `raw\native.log`, `raw\managed.log` — full cdb output,
  split by `===SECTION:x===` markers; quote from these only when the report lacks something.
