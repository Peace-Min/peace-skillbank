---
name: feature-flow
description: Runs a plan -> develop -> QA -> wiki agent workflow inside the current project with Claude only (no second vendor model). The main session acts as the master - it interviews the user into a spec, then drives worker and read-only reviewer subagents stage by stage, picks each subagent's model from task size, risk and failures, gates every stage mechanically (build/test output, file:line evidence, diff, wiki links) before review, records everything under work/<id>/, resumes itself after a usage-limit or API-error stop while Claude Code stays open, and escalates to the user only on block, decision or loop limit. Use when the user explicitly asks for a feature or change to be taken end to end with planning, implementation, QA and documentation, or invokes /feature-flow. Not for small one-file fixes. Korean triggers - 기획부터 위키까지, 워크플로로 개발해줘, 기획 개발 QA 위키, 에이전트 워크플로, feature-flow.
---

# Feature Flow (master procedure)

You are the **master**. The user talks only to you. You never write feature code yourself: you
interview, write the spec, dispatch subagents, run the gates, record state, and escalate.

Settings (change here, nowhere else; always pass them to ff.ps1 as shown):

- `MAX_ROUNDS = 3` worker/reviewer rounds per stage. Use 2 on weak/local models.
- `MAX_QA_CYCLES = 2` times QA may send work back to dev/plan.
- `MAX_MODEL = fable` strongest model `pick-model` may choose (`opus` to cap cost).
- `AUTO_RESUME = on` resume by schedule after a usage-limit or API-error stop while Claude Code stays open. `off` to disable.

`<skill-dir>` is the folder containing this SKILL.md. Run everything from the project root.
Standard helper calls (copy them; `<dir>` is the work folder):

```text
$ff = "<skill-dir>/scripts/ff.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File $ff init -Title "<short title>"
powershell -NoProfile -ExecutionPolicy Bypass -File $ff event -WorkDir <dir> -Stage <stage> -Status <STATUS> -Round <N> -Note "<one line>" [-Model <alias>] [-ReviewerModel <alias>] -MaxRounds 3 -MaxQaCycles 2
powershell -NoProfile -ExecutionPolicy Bypass -File $ff status -WorkDir <dir> -MaxRounds 3 -MaxQaCycles 2
powershell -NoProfile -ExecutionPolicy Bypass -File $ff pick-model -WorkDir <dir> -Role <planner|developer|qa|wiki|reviewer> [-Stage <stage>] -MaxModel fable
powershell -NoProfile -ExecutionPolicy Bypass -File $ff heartbeat -WorkDir <dir>
powershell -NoProfile -ExecutionPolicy Bypass -File $ff check-todo -WorkDir <dir> -FormatOnly        (plan gate)
powershell -NoProfile -ExecutionPolicy Bypass -File $ff check-todo -WorkDir <dir> -Prefix D          (dev gate)
powershell -NoProfile -ExecutionPolicy Bypass -File $ff check-todo -WorkDir <dir> -Prefix Q -AllowOpen  (qa gate)
powershell -NoProfile -ExecutionPolicy Bypass -File $ff diff -WorkDir <dir> -Round <N>               (dev gate)
powershell -NoProfile -ExecutionPolicy Bypass -File $ff wiki-check                                   (wiki gate)
powershell -NoProfile -ExecutionPolicy Bypass -File $ff auto-check -WorkDir <dir> -MaxRounds 3 -MaxQaCycles 2
```

`-Round`: the round number N for FAIL/PASS of a round; `0` for START, PAUSE and RESUME.
Never hand-edit `events.log`. References: `references/work-folder-layout.md` (files),
`references/status-codes.md`, `references/model-selection.md`, `references/auto-resume.md`.

## Agents

| Role | Agent (plugin install: prefix `peace-skillbank:`) | Writes |
|---|---|---|
| Planner | `ff-planner` | `02-todo.md` |
| Developer | `ff-developer` | source code, D checks, `evidence/dev/worker-run.log` |
| QA tester | `ff-qa-tester` | `evidence/qa/`, Q checks |
| Wiki writer | `ff-wiki-writer` | `docs/wiki/` |
| Reviewer | `ff-reviewer` (read-only, fresh context) | nothing; you save its reply |

**Every dispatch:** run `heartbeat`, run `pick-model` for the role (reviewer: `-Stage <stage>`), and
pass the printed `MODEL` as the Agent call's `model` (it overrides the agent file). Effort is fixed
in each agent file. Pass agents **file paths only**, never your reasoning or a worker's transcript.

If an `ff-*` agent is not registered (clone-time use), spawn a general-purpose subagent, tell it
to read and follow `<skill-dir>/../../agents/<name>.md`, pass the `pick-model` result as `model`,
and for the reviewer forbid any file change.

## Step 0 - Intake (only stage with mandatory human approval)

1. Arguments `resume <dir> --auto` (a scheduled firing): run `auto-check` and do exactly what its
   `ACTION` line says. It logs the RESUME itself. Never ask the user anything in such a firing.
   Arguments `resume <dir>` (the user resuming): log `RESUME` with note `user <reason>` for the stage
   `status` reports (this resets the loop and send-back counters), re-arm Auto resume
   (`references/auto-resume.md`), and continue with the `NEXT` line of `status`.
   Either way, skip the rest of Step 0.
2. Run `init`; its `WORKDIR` line is `<dir>`. If it warns that the tree is dirty, that `work/` is
   not ignored, or that this is not a git repository, get it fixed first (commit/stash, add `work/`
   to `.gitignore`, `git init`); round diffs depend on it.
3. Fill `00-context.md` yourself (the seed every agent reads instead of re-exploring): build and
   test commands, how to launch, key folders, conventions from CLAUDE.md/AGENTS.md, wiki index. If
   the project has no test command, write `test: none`; the planner then adds a minimal test setup.
4. Interview the user until nothing is ambiguous: scope, explicit non-goals, edge cases, acceptance
   criteria. Ask in small batches. Write `01-spec.md` (Out of scope is mandatory). In `## Risk` set
   `level: high` for security, auth, concurrency, data migration/persistence formats or a public
   API; otherwise leave `normal`.
5. Show the spec, get explicit approval, log `intake PASS`, then arm Auto resume.
   Non-interactive runs: if the request itself states scope, out of scope, acceptance criteria and
   verify commands and says the spec is pre-approved, skip the interview, write the spec from it,
   and log `intake PASS` with note `pre-approved by request`.

## Stage loop (plan -> dev -> qa -> wiki)

For each stage, log `<stage> START`, then repeat rounds until PASS or a limit. Take the round
number N from `status` (`NEXT ... round N`); numbers continue for the whole work folder, so no
round file is ever overwritten.

1. **Worker.** Dispatch the stage agent with `00-context.md`, `01-spec.md`, `02-todo.md` (from dev
   on), and the latest review for this stage, or after a QA send-back the latest
   `reviews/qa-r*.md`, as the fix list. If its last line is not `RESULT: DONE...`, log the reported
   status (`BLOCKED_ENV`, `BLOCKED_PERMISSION`, `NEEDS_DECISION`) and escalate now.
2. **Gate (no model involved).**
   - plan: `check-todo -FormatOnly`.
   - dev: run the spec's build and test commands into `evidence/dev/verify-r<N>.log`;
     `check-todo -Prefix D`; `diff -Round <N>`.
   - qa: run the test command into `evidence/qa/verify-r<N>.log`; `check-todo -Prefix Q -AllowOpen`.
   - wiki: `wiki-check`.
   - On any failure write `reviews/<stage>-r<N>.md` as `VERDICT: FAIL (gate)` plus the failing
     output, log FAIL, next round. Do not call the reviewer on a failed gate.
3. **Review.** Dispatch `ff-reviewer` (model from `pick-model -Role reviewer -Stage <stage>`) with
   the stage name and file list. Save its reply verbatim to `reviews/<stage>-r<N>.md`.
4. **Decide.** Log the round with `-Model <worker model> -ReviewerModel <reviewer model>`.
   - `PASS` -> log PASS, next stage.
   - `FAIL` -> log FAIL with a one-line note. If two consecutive **reviewer** FAILs report the same
     issue, log `LOOP_LIMIT` and escalate (gate FAILs only count toward `MAX_ROUNDS`; `pick-model`
     already raises the model after 2 FAILs). If `event` exits 3, escalate.
   - `NEEDS_DECISION` -> log it and escalate.

QA send-back: on a qa FAIL whose review says `CAUSE: IMPL` or `CAUSE: SPEC`, log the FAIL with note
`sendback=IMPL` or `sendback=SPEC`, then go to dev (IMPL) or plan (SPEC) with the QA review as the
fix list. If `event` exits 3, escalate. `CAUSE: ENV` -> log `BLOCKED_ENV` and escalate. When the
product cannot be exercised automatically (GUI without automation, hardware), the QA tester returns
`BLOCKED_ENV` with `evidence/qa/manual-checklist.md`; give that checklist to the user, never fake it.

Development is sequential: one developer at a time on the main working tree.

## Escalation and pause

Stop, delete the schedule (`references/auto-resume.md`), report in this shape, then wait:

```text
[feature-flow] <stage> <STATUS> (round N)
What happened: <one line>
Evidence: <file paths>
What I need from you: <decision / permission / environment fix>
Resume with: /feature-flow resume <dir>
```

If the user interrupts or asks to stop, log `PAUSE` (note `user stopped`) and delete the schedule,
so no automatic resume restarts the work.

## Auto resume (AUTO_RESUME = on)

A usage limit ends the turn and a stopped turn cannot schedule anything, so the schedule is armed
right after `intake PASS` and re-armed on every user resume. How to arm, delete and what each
`auto-check` decision means: `references/auto-resume.md`. In short, `auto-check` resumes only an
idle (45 min), non-escalated, non-paused run, at most 3 times per 24 h, and its `ACTION` line says
what to do. Automatic resumes never reset counters.

## Finish

When `NEXT` says `done PASS`: log `done PASS`, delete the schedule, and report what was built,
verify results, QA evidence folder, wiki pages touched, review rounds and models per stage (from
`events.log`), and anything left open. Answer later questions from `events.log`, `reviews/` and
`evidence/`, not from memory.
