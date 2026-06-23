# frontier-handoff

Turn "I'm stuck on a weak / offline model" into ONE paste-ready prompt for a frontier model on another
machine. When you hit a wall or a hallucination, this skill packages your current code, the verbatim
problem, what you tried, your environment, and your ask into a single **self-contained** handoff prompt
that a frontier model can act on with zero access to your files.

See `SKILL.md` for the runtime contract and
[docs/frontier-handoff-usage.md](../../docs/frontier-handoff-usage.md) for the human guide.

## How it works

1. You describe the situation (or just say "make me a handoff prompt"); the skill auto-collects the
   relevant code, the error, recent changes (git diff), and the environment -- you don't retype it.
2. It fills a fixed 6-section template: **Goal / Problem (verbatim) / What I tried / Relevant code
   (`file:line`) / Environment & constraints / Ask**.
3. `scripts/finalize-handoff.py` runs deterministically and does two things a model can't be trusted
   to remember every time:
   - **Masks secrets** (keys, tokens, passwords, connection strings, private keys) and flags absolute
     paths / emails / IPs for your review -- because the prompt is leaving the box.
   - **Appends the mandatory response directive** so the frontier model answers as a *small-step,
     explicit, offline-aware plan* a weak local model can apply step by step.

## No setup

Standard-library Python only -- no corpus, no dependencies, no install. It runs fine on a weak local
model (verified end-to-end against `qwen2.5-coder:7b` via Ollama: the weak model fills the template and
the script masks the secrets it leaves in).

## Privacy

The prompt is meant to leave the air-gapped box, so glance at the redaction report before you paste:
secrets are auto-masked, but absolute paths / internal names are only **flagged** -- you decide whether
to keep them. A leaked secret going to an external model is the one irreversible failure here.
