---
description: Take a request end to end - interview, spec, plan, develop, QA, wiki - with evidence-gated read-only review at every stage.
argument-hint: "<what to build or change>  |  resume <work-dir> [--auto]"
---

Use the `feature-flow` skill for the following request:

```text
$ARGUMENTS
```

Follow the skill's SKILL.md exactly; this command is only a short entry point and adds no rules of
its own. In particular, `resume <work-dir> --auto` is a scheduled firing (run `ff.ps1 auto-check`
and do what its `ACTION` line says, asking the user nothing), `resume <work-dir>` is the user
resuming, and anything else is a new request that starts with the interview and an explicitly
approved spec. If no request is given, ask what to build.

If both this command and the namespaced plugin skill are available, this command is only a short alias for the skill.
