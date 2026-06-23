---
description: Answer a LightningChart Ultimate 7.2 (Arction) API / property / usage question, grounded only in local 7.2 sources.
argument-hint: "<your LightningChart 7.2 question>"
---

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
