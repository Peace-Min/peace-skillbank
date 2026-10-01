---
name: feature-flow
description: Clone-time Claude Code entrypoint for the plan -> develop -> QA -> wiki agent workflow. The main session interviews the user into a spec, then drives worker and read-only reviewer subagents with build/test and file-evidence gates, recording everything under work/<id>/. Use when the user wants a change taken end to end or invokes /feature-flow. Korean triggers - 기획부터 위키까지, 워크플로로 개발해줘, 기획 개발 QA 위키, 에이전트 워크플로.
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
