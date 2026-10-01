---
description: Take a request end to end - interview, spec, plan, develop, QA, wiki - with evidence-gated read-only review at every stage.
argument-hint: "<what to build or change>  |  resume <work-dir> [--auto]"
---

Use the `feature-flow` skill for the following request:

```text
$ARGUMENTS
```

Treat this command as a terse entry point:

1. If the arguments are `resume <work-dir> --auto` (a scheduled firing), run `<skill-dir>/scripts/ff.ps1 auto-check` and continue only on `DECISION RESUME`, asking the user nothing.
   If the arguments start with `resume`, run `<skill-dir>/scripts/ff.ps1 status` (`<skill-dir>` = the feature-flow skill folder) on the given work folder and continue from the reported stage.
2. Otherwise run `<skill-dir>/scripts/ff.ps1 init`, write `00-context.md`, interview the user, and get explicit approval of `01-spec.md` before any code is written (unless the request itself is a complete, explicitly pre-approved spec; see the skill's Step 0).
3. Drive the stages plan -> dev -> qa -> wiki with the `ff-*` subagents (model per call from `ff.ps1 pick-model`), the mechanical gates (build/test, `check-todo`, `diff`, `wiki-check`), and the read-only `ff-reviewer`, exactly as the skill describes.
4. Escalate on `BLOCKED_*`, `NEEDS_DECISION` or `LOOP_LIMIT` and wait for the user.
5. If no request is given, ask what to build.

If both this command and the namespaced plugin skill are available, this command is only a short alias for the skill.
