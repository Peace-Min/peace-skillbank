---
name: feature-flow
description: Takes a feature or change end to end in the current project - interview, approved spec, plan, develop, QA, wiki - with Claude subagents, a read-only reviewer on a different model, mechanical build/test/evidence gates, records under work/<id>/ and automatic resume. Windows only (PowerShell 5.1+). Use when the user asks to build something end to end with planning, review, tests and docs, or invokes /feature-flow. Not for small one-file fixes. Korean triggers - 기획부터 위키까지, 워크플로로 개발해줘, 기획 개발 QA 위키, 에이전트 워크플로.
---

# Feature Flow Entrypoint

This is the Claude Code project-skill entrypoint that makes `/feature-flow` available after cloning
this repository and starting Claude Code from the repo root. The workflow is meant to run inside a
target project, so the normal install is the plugin (`/peace-skillbank:feature-flow`).

Before acting, read and follow the canonical skill contract at:

```text
skills/feature-flow/SKILL.md
```

Use the bundled state helper from:

```text
skills/feature-flow/scripts/ff.ps1
```

The role definitions live in `agents/ff-*.md` at the repo root. When they are not registered as
subagents (clone-time use), spawn general-purpose subagents and tell each to follow its role file.
Treat any arguments passed to `/feature-flow` as the user's request, or `resume <work-dir>`.
