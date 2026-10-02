# Subagent model selection (`ff.ps1 pick-model`)

The master runs `pick-model` before every dispatch and passes the printed `MODEL` as the Agent
call's `model`. A per-call model overrides the agent file's `model:` (Claude Code resolution order:
call parameter > agent file > `CLAUDE_CODE_SUBAGENT_MODEL` > main model;
`CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1` overrides everything).

Tiers, weakest to strongest: `haiku < sonnet < opus < fable`. Aliases always resolve to the newest
model of that family, so nothing needs editing when a new model ships.

| Role | Base | Risk `high` (spec `## Risk`) |
|---|---|---|
| planner | opus | fable |
| developer | sonnet if 1-3 D items, else opus (also when 02-todo.md does not exist yet) | opus |
| qa | sonnet | opus |
| wiki | sonnet | sonnet |
| reviewer | sonnet | opus |

Escalation:

- Workers: one tier up after 2 FAILs in their stage (since the stage START or the last user RESUME).
- Developer: one more tier up after a QA `sendback=IMPL` since the last user RESUME.
- Reviewer: never weaker than the model the worker of that stage gets (so the plan reviewer is at
  least opus, and an escalated developer gets an equally strong reviewer). Reviewers are not raised
  by FAIL counts themselves; they produced those FAILs.
- Everything is capped at `MAX_MODEL`. `REASON` says `escalated from <base>` only when the result
  is above the base, and `capped at <MAX_MODEL>` whenever the cap lowered it.

Effort is not chosen here: each agent file fixes it (`effort:` planner/developer/reviewer high, qa
medium, wiki low). Subagents do not inherit the session's effort, so a session at medium still
plans and develops at high.

`MAX_MODEL = inherit` turns selection off: `pick-model` prints `MODEL inherit` and the master
passes no model, so subagents use the agent file's `model:` (or the session model for `inherit`).
