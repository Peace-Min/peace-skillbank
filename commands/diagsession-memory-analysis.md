---
description: Analyze a VS diagsession or gcdump for managed memory leak candidates.
argument-hint: "<diagsession-or-gcdump-path> [action/count/start-point context]"
---

**Before doing anything else, read the skill's full instructions with the Read tool** (in a plugin
install this command can shadow the skill, so the Skill tool may return only this text):

1. `${CLAUDE_PLUGIN_ROOT}/skills/diagsession-memory-analysis/SKILL.md` (plugin install);
2. if that path is not expanded or does not exist, the newest
   `~/.claude/plugins/cache/peace-skillbank/peace-skillbank/<version>/skills/diagsession-memory-analysis/SKILL.md`;
3. in a clone of the peace-skillbank repository, `skills/diagsession-memory-analysis/SKILL.md`.

The folder that contains that SKILL.md is the skill directory; resolve its `scripts/` and
`references/` from there. Then follow SKILL.md; the steps below only summarize it.

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

