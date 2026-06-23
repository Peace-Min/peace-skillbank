---
name: frontier-handoff
description: Clone-time Claude Code entrypoint for packaging a stuck situation on a weak/offline model into ONE self-contained prompt for a frontier model on another machine. Use whenever the user is on a weak, local, offline, or air-gapped model and is stuck, hitting hallucinations, or asks for a prompt to send to a stronger / frontier / 상위 / better model -- including phrases like "프론티어 모델한테 물어볼 프롬프트 만들어줘", "상위 모델용 프롬프트", "hand this off", even without the word "handoff".
---

# Frontier Handoff Entrypoint

This is the Claude Code project-skill entrypoint that makes `/frontier-handoff` available immediately
after cloning this repository and starting Claude Code from the repo root.

Before acting, read and follow the canonical skill contract at:

```text
skills/frontier-handoff/SKILL.md
```

Use the bundled script from:

```text
skills/frontier-handoff/scripts/finalize-handoff.py
```

Treat any user arguments passed to `/frontier-handoff` as the stuck situation to package. Assemble the
draft per the canonical skill, then run `finalize-handoff.py` to append the mandatory response directive
before emitting the final copy-ready handoff prompt.
