---
name: lightningchart-72
description: Clone-time Claude Code entrypoint for answering LightningChart Ultimate SDK v7.2 (Arction) API, property, method, enum, and usage questions grounded ONLY in local 7.2 sources, with source citations and API-existence verification. Use whenever the user works with LightningChart / Arction 7.2, especially offline or air-gapped.
---

# LightningChart 7.2 Entrypoint

This is the Claude Code project-skill entrypoint that makes `/lightningchart-72` available
immediately after cloning this repository and starting Claude Code from the repo root.

Before acting, read and follow the canonical skill contract at:

```text
skills/lightningchart-72/SKILL.md
```

Use bundled scripts and references from:

```text
skills/lightningchart-72/
```

Treat any user arguments passed to `/lightningchart-72` as the LightningChart 7.2 question for the
canonical skill. If the local corpus is missing, point the user to
`skills/lightningchart-72/scripts/setup-local-corpus.ps1`.
