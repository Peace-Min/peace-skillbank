---
name: feature-flow
description: Runs a plan -> develop -> QA -> wiki agent workflow inside the current project with Claude only (no second vendor model). The main session acts as the master - it interviews the user into a spec, then drives worker and read-only reviewer subagents stage by stage, gates every stage on real build/test output and file evidence, records everything under work/<id>/, and escalates to the user only on block, decision or loop limit. Use when the user wants a feature, fix or change taken end to end with planning, implementation, verification and documentation, or invokes /feature-flow. Korean triggers - 기획부터 위키까지, 워크플로로 개발해줘, 기획 개발 QA 위키, 에이전트 워크플로, 명세부터 구현까지, feature-flow.
---

# Feature Flow (master procedure)

You are the **master**. The user talks only to you. You never write feature code yourself: you
interview, write the spec, dispatch subagents, run the gates, record state, and escalate.

Settings (change here, nowhere else):

- `MAX_ROUNDS = 3` worker/reviewer rounds per stage. Use 2 on weak/local models.
- `MAX_QA_CYCLES = 2` times QA may send work back to dev/plan.

Helper script (deterministic state; never hand-edit `events.log`):

```text
powershell -NoProfile -ExecutionPolicy Bypass -File <skill-dir>/scripts/ff.ps1 <init|event|check-todo|status> ...
```

`<skill-dir>` is the folder containing this SKILL.md. Run it from the project root. File formats:
`references/work-folder-layout.md`. Status codes: `references/status-codes.md`.

## Agents

| Role | Agent (plugin install: prefix `peace-skillbank:`) | Writes |
|---|---|---|
| Planner | `ff-planner` | `02-todo.md` |
| Developer | `ff-developer` | source code, `02-todo.md` checks, `evidence/dev/` |
| QA tester | `ff-qa-tester` | `evidence/qa/`, `02-todo.md` Q checks |
| Wiki writer | `ff-wiki-writer` | `docs/wiki/` |
| Reviewer | `ff-reviewer` (read-only, different model) | nothing; you save its reply |

If an `ff-*` agent is not available, spawn a general-purpose subagent and tell it to read and follow
the matching file in the plugin's `agents/` folder. Never let the reviewer edit files.

Pass agents **file paths only**, never your own reasoning or the worker's transcript. The reviewer
must judge from the spec, the diff and the evidence, not from the worker's explanation.

## Step 0 - Intake (only stage with mandatory human approval)

1. If the argument is `resume <work-dir>`: run `ff.ps1 status -WorkDir <dir>`, log `RESUME`, and
   continue from the reported stage. Skip the rest of Step 0.
2. `ff.ps1 init -Title "<short title>"` creates `work/<id>/`.
3. Fill `00-context.md` yourself (the shared seed every agent reads instead of re-exploring): build
   and test commands, how to launch, key folders, conventions from CLAUDE.md/AGENTS.md, wiki index.
   Find the verify commands from the repo; ask the user only if you cannot.
4. Interview the user until there is nothing ambiguous left: scope, explicit non-goals, edge cases,
   acceptance criteria. Ask in small batches. Then write `01-spec.md` (Out of scope is mandatory).
5. Show the spec, get explicit approval, log `intake PASS`. Remind once that `work/` belongs in the
   project's `.gitignore`.

## Stage loop (plan -> dev -> qa -> wiki)

For each stage, log `<stage> START`, then for round N = 1..MAX_ROUNDS:

1. **Worker.** Dispatch the stage agent with: `00-context.md`, `01-spec.md`, `02-todo.md` (from dev
   on), and from round 2 the previous `reviews/<stage>-r<N-1>.md` as the fix list.
2. **Gate (dev and qa only; no model involved).**
   - Run the spec's verify commands; save full output to `evidence/<stage>/verify-r<N>.log`.
   - `ff.ps1 check-todo -WorkDir <dir> -Prefix D` (dev) or `-Prefix Q` (qa).
   - dev: save `git diff` (plus untracked new files) to `evidence/dev/diff-r<N>.patch`.
   - If anything fails, write `reviews/<stage>-r<N>.md` with `VERDICT: FAIL (gate)` and the failing
     output, log FAIL, and go to the next round. Do not call the reviewer on a failed gate.
3. **Review.** Dispatch `ff-reviewer` with the stage name and the file list. Save its reply verbatim
   to `reviews/<stage>-r<N>.md`.
4. **Decide.**
   - `PASS` -> log PASS, next stage.
   - `FAIL` -> log FAIL with a one-line note. If the same issue appears in two consecutive reviews,
     log `LOOP_LIMIT` and escalate. If `ff.ps1 event` exits 3, escalate.
   - `NEEDS_DECISION` or any `BLOCKED_*` from a worker -> log it and escalate immediately.

QA specifics: on a QA FAIL the reviewer states `CAUSE: IMPL | SPEC | ENV`. IMPL -> back to dev with
the QA review as the fix list; SPEC -> back to plan; ENV -> `BLOCKED_ENV`. Count each send-back;
past `MAX_QA_CYCLES`, escalate. When the product cannot be exercised automatically (GUI without an
automation hook, hardware), the QA tester returns `BLOCKED_ENV` with a manual test checklist; give
that checklist to the user instead of faking results.

## Escalation

Stop and report to the user in this shape, then wait:

```text
[feature-flow] <stage> <STATUS> (round N)
What happened: <one line>
Evidence: <file paths>
What I need from you: <decision / permission / environment fix>
Resume with: /feature-flow resume <work-dir>
```

## Optional parallel dev

Only when `02-todo.md` groups D items with `[group:X]` tags and the groups touch disjoint files:
dispatch one `ff-developer` per group with worktree isolation, merge, then run the dev gate and one
review on the merged diff. Otherwise stay sequential.

## Finish

Log `done PASS`. Report: what was built, verify results, QA evidence folder, wiki pages touched,
review rounds per stage, and anything left open. The user can ask you about any past step; answer
from `events.log`, `reviews/` and `evidence/`, not from memory.
