# Using feature-flow without Claude Code subagents

The workflow is tool-agnostic: every hand-off is a file under `work/<id>/` and the deterministic
parts are in `<skill-dir>/scripts/ff.ps1` (`<skill-dir>` = `skills/feature-flow`). Any LLM (Codex, a local model, a chat UI) can play the roles.

1. The human (or the orchestrating model) runs `ff.ps1 init -Title "<title>"` and fills
   `00-context.md` and `01-spec.md` after the interview.
2. For each role, start a **fresh** conversation, paste the role file from the plugin's `agents/`
   folder (`ff-planner.md`, `ff-developer.md`, `ff-qa-tester.md`, `ff-wiki-writer.md`,
   `ff-reviewer.md`, body only) as the system instruction, then paste the files it lists.
3. Gate between worker and reviewer with real commands, not model judgement:

```powershell
# build/test output for the round
<build/test command> 2>&1 | Out-File -Encoding utf8 work\<id>\evidence\dev\verify-r1.log
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\ff.ps1 diff -WorkDir work\<id> -Round 1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\ff.ps1 check-todo -WorkDir work\<id> -Prefix D
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\ff.ps1 event -WorkDir work\<id> -Stage dev -Status FAIL -Round 1 -Note "gate: D3 no evidence"
```

4. Save each reviewer reply verbatim as `reviews/<stage>-r<N>.md`. Stop when `ff.ps1 event`
   exits 3 (loop limit) or a role returns `BLOCKED_*` / `NEEDS_DECISION`.

Weak/local models: use `-MaxRounds 2` on every `event` call, keep one stage per conversation, and never paste a
worker's transcript into the reviewer conversation (files only).
