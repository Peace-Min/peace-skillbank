---
description: Analyze a VS diagsession or gcdump for managed memory leak candidates.
argument-hint: "<diagsession-or-gcdump-path> [action/count/start-point context]"
---

Use the `diagsession-memory-analysis` skill to analyze the following input:

```text
$ARGUMENTS
```

Treat this command as a terse entry point:

1. Parse the arguments for `.diagsession` or `.gcdump` paths plus any repeated action, count, start point, or related file/class hints.
2. If no usable input path is present, ask for the dump/session path.
3. Run the bundled extraction/report flow from the skill.
4. Analyze managed memory growth only.
5. Do not edit source code or apply fixes in this command.
6. Produce the standard analysis report and follow-up fix-session handoff summary.

If both this command and the namespaced plugin skill are available, this command is only a short alias for the skill.

