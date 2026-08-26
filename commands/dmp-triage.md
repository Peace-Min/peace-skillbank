---
description: Analyze a Windows process dump (.dmp) offline and produce an LLM-ready triage report.
argument-hint: "<dmp-path> [hang/crash context, e.g. what the app was doing]"
---

Use the `dmp-triage` skill to analyze the following input:

```text
$ARGUMENTS
```

Treat this command as a terse entry point:

1. Parse the arguments for a `.dmp` path plus any context (what the app was doing, hang vs crash,
   source machine details).
2. If no usable dump path is present, ask for it.
3. Run the skill's `check` then `analyze` flow (`scripts/dmp-triage.ps1`). NEVER parse the dump
   bytes directly.
4. Interpret `report.md` per the skill's guide and report: one-line cause, evidence by section,
   confidence, and what extra input would raise it.
5. Do not edit source code or apply fixes in this command.

If both this command and the namespaced plugin skill are available, this command is only a short
alias for the skill.
