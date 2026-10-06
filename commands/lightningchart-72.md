---
description: Answer a LightningChart Ultimate 7.2 (Arction) API / property / usage question, grounded only in local 7.2 sources.
argument-hint: "<your LightningChart 7.2 question>"
---

**Before doing anything else, read the skill's full instructions with the Read tool** (in a plugin
install this command can shadow the skill, so the Skill tool may return only this text):

1. `${CLAUDE_PLUGIN_ROOT}/skills/lightningchart-72/SKILL.md` (plugin install);
2. if that path is not expanded or does not exist, the newest
   `~/.claude/plugins/cache/peace-skillbank/peace-skillbank/<version>/skills/lightningchart-72/SKILL.md`;
3. in a clone of the peace-skillbank repository, `skills/lightningchart-72/SKILL.md`.

The folder that contains that SKILL.md is the skill directory; resolve its `scripts/` and
`references/` from there. Then follow SKILL.md; the steps below only summarize it.

Use the `lightningchart-72` skill to answer the following LightningChart Ultimate 7.2 (Arction) question:

```text
$ARGUMENTS
```

Treat this command as a terse entry point:

1. Answer ONLY from the local 7.2 sources (the DLL API index + the indexed user manual + this project's own usage); never from memory or general knowledge.
2. If no question is present, ask what LightningChart 7.2 API / property / method / enum / usage they need.
3. Cite every fact (manual section/page, API symbol) and run the verify step (`scripts/verify-symbols.py --strict`) yourself on the draft before asserting any symbol -- it is an agent-run script, not an automatic harness hook.
4. If a symbol is not found in the 7.2 sources, say so instead of inventing it; if the corpus is not built, point the user to `scripts/setup-local-corpus.ps1`.

If both this command and the namespaced plugin skill are available, this command is only a short alias for the skill.
