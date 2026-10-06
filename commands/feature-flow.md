---
description: Take a request end to end - interview, spec, plan, develop, QA, wiki - with evidence-gated read-only review at every stage.
argument-hint: "<만들거나 바꿀 내용>  |  resume <작업 폴더> [--auto]"
---

Run the feature-flow workflow for the following request:

```text
$ARGUMENTS
```

This command is only an entry point and adds no rules of its own. **Before doing anything else,
read the skill's full procedure with the Read tool** (in a plugin install this command can shadow the
skill, so the Skill tool may return only this text):

1. `${CLAUDE_PLUGIN_ROOT}/skills/feature-flow/SKILL.md` (plugin install);
2. if that path is not expanded or does not exist, the newest
   `~/.claude/plugins/cache/peace-skillbank/peace-skillbank/<version>/skills/feature-flow/SKILL.md`;
3. in a clone of the peace-skillbank repository, `skills/feature-flow/SKILL.md`.

The folder that contains that SKILL.md is the skill directory (`<skill-dir>`, with
`scripts/ff.ps1` and `references/`). Then follow SKILL.md exactly. In particular,
`resume <work-dir> --auto` is a scheduled firing (run `ff.ps1 auto-check` and do what its `ACTION`
line says, asking the user nothing), `resume <work-dir>` is the user resuming, and anything else is
a new request that starts with the interview and an explicitly approved spec. If no request is given,
ask what to build.
