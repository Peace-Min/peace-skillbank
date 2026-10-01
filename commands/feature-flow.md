---
description: Take a request end to end - interview, spec, plan, develop, QA, wiki - with evidence-gated read-only review at every stage.
argument-hint: "<what to build or change>  |  resume <work-dir>"
---

Use the `feature-flow` skill for the following request:

```text
$ARGUMENTS
```

Treat this command as a terse entry point:

1. If the arguments start with `resume`, run `scripts/ff.ps1 status` on the given work folder and continue from the reported stage.
2. Otherwise run `scripts/ff.ps1 init`, write `00-context.md`, interview the user, and get explicit approval of `01-spec.md` before any code is written.
3. Drive the stages plan -> dev -> qa -> wiki with the `ff-*` subagents, the build/test + `check-todo` gate, and the read-only `ff-reviewer`, exactly as the skill describes.
4. Escalate on `BLOCKED_*`, `NEEDS_DECISION` or `LOOP_LIMIT` and wait for the user.
5. If no request is given, ask what to build.

If both this command and the namespaced plugin skill are available, this command is only a short alias for the skill.
