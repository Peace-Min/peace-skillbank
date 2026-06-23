---
description: Package the current stuck situation (code, problem, what was tried, environment, ask) into ONE self-contained prompt for a frontier model on another machine.
argument-hint: "<what you're stuck on / what to ask the frontier model>"
---

Use the `frontier-handoff` skill to package the following stuck situation into ONE clean, self-contained prompt that a stronger frontier model on a different machine can act on with zero access to these files:

```text
$ARGUMENTS
```

Treat this command as a terse entry point:

1. Auto-collect the context yourself -- the code in play (minimal relevant span, each tagged `path:line`), the exact error / wrong output / hallucinated claim quoted verbatim, what was already tried (recent diff), and the environment + the **exact library/framework versions**. Do not make the user retype what you can read.
2. Assemble the Goal / Problem / What I already tried / Relevant code / Environment & constraints / Ask sections, and stop at `## Ask`.
3. Write the assembled draft to a temp file (e.g. `handoff-draft.md`) and run `python scripts/finalize-handoff.py handoff-draft.md` -- it deterministically appends the mandatory response directive (answer as a small-step, explicit, offline-aware plan). Emit the script's output as ONE copy-ready block.
4. If no situation is provided, ask what they are stuck on and which frontier model they want to hand it off to.

If both this command and the namespaced plugin skill are available, this command is only a short alias for the skill.
