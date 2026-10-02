---
name: feature-flow
description: Runs a plan -> develop -> QA -> wiki agent workflow inside the current project with Claude only (no second vendor model). The main session acts as the master - it interviews the user into a spec, then drives worker and read-only reviewer subagents stage by stage, picks each subagent's model from task size, risk and failures, gates every stage mechanically (build/test output, file:line evidence, diff, wiki links) before review, records everything under work/<id>/, resumes itself after a usage-limit or API-error stop while Claude Code stays open, and escalates to the user only on block, decision or loop limit. Use when the user explicitly asks for a feature or change to be taken end to end with planning, implementation, QA and documentation - e.g. "take this ticket through spec, tests and docs", "build this end to end with review", "run the full workflow" - or invokes /feature-flow. Not for small one-file fixes. Korean triggers - 기획부터 위키까지, 워크플로로 개발해줘, 기획 개발 QA 위키, 에이전트 워크플로, feature-flow.
---

# Feature Flow (master procedure)

You are the **master**. The user talks only to you. You never write feature code yourself: you
interview, write the spec, dispatch subagents, run the gates, record state, and escalate.

Settings (change here, nowhere else). They are passed once to `init`, stored in
`<dir>/settings.txt`, and every later ff.ps1 call (also scheduled firings) reads them from there:

- `MAX_ROUNDS = 3` worker/reviewer rounds per stage. Use 2 on weak/local models.
- `MAX_QA_CYCLES = 2` times QA may send work back to dev/plan.
- `MAX_MODEL = fable` strongest model `pick-model` may choose (`opus` to cap cost; `inherit` to never pass a model, e.g. a gateway that does not map every alias).
- `AUTO_RESUME = on` resume by schedule after a usage-limit or API-error stop while Claude Code stays open. `off` to disable.

`<skill-dir>` is the copy of this skill that contains `scripts/ff.ps1`. If
`<project root>/.claude/skills/feature-flow/scripts/ff.ps1` exists, use that copy even when the
skill loader reports another base directory (in a worktree it may point at the main checkout).
Run everything from the project root. Standard helper calls (`<dir>` is the work folder, absolute):

```text
$ff = "<skill-dir>/scripts/ff.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File $ff init -Title "<short title>" -MaxRounds 3 -MaxQaCycles 2 -MaxModel fable
powershell -NoProfile -ExecutionPolicy Bypass -File $ff event -WorkDir <dir> -Stage <stage> -Status <STATUS> -Round <N> -Note "<one line>" [-SendBack IMPL|SPEC] [-Model <alias>] [-ReviewerModel <alias>]
powershell -NoProfile -ExecutionPolicy Bypass -File $ff status -WorkDir <dir>
powershell -NoProfile -ExecutionPolicy Bypass -File $ff pick-model -WorkDir <dir> -Role <planner|developer|qa|wiki|reviewer> [-Stage <stage>]
powershell -NoProfile -ExecutionPolicy Bypass -File $ff heartbeat -WorkDir <dir>
powershell -NoProfile -ExecutionPolicy Bypass -File $ff verify -WorkDir <dir> -Stage <dev|qa> -Round <N> -Build "<build cmd>" -Test "<test cmd>"
powershell -NoProfile -ExecutionPolicy Bypass -File $ff check-todo -WorkDir <dir> -FormatOnly        (plan gate)
powershell -NoProfile -ExecutionPolicy Bypass -File $ff check-todo -WorkDir <dir> -Prefix D          (dev gate)
powershell -NoProfile -ExecutionPolicy Bypass -File $ff check-todo -WorkDir <dir> -Prefix Q -AllowOpen  (qa gate)
powershell -NoProfile -ExecutionPolicy Bypass -File $ff diff -WorkDir <dir> -Round <N>               (dev gate)
powershell -NoProfile -ExecutionPolicy Bypass -File $ff wiki-check                                   (wiki gate)
powershell -NoProfile -ExecutionPolicy Bypass -File $ff auto-check -WorkDir <dir>
```

`-Round`: the current round N for FAIL, PASS and halts (BLOCKED_*, NEEDS_DECISION, LOOP_LIMIT);
`0` for START, PAUSE and RESUME. Never hand-edit
`events.log`. References: `references/work-folder-layout.md` (files and formats; pass its absolute
path to the planner), `references/status-codes.md`, `references/model-selection.md`,
`references/auto-resume.md`.

## Agents

| Role | Agent (plugin install: prefix `peace-skillbank:`) | Writes |
|---|---|---|
| Planner | `ff-planner` | `02-todo.md` |
| Developer | `ff-developer` | source code, D checks, `evidence/dev/worker-run.log` |
| QA tester | `ff-qa-tester` | `evidence/qa/`, Q checks |
| Wiki writer | `ff-wiki-writer` | `docs/wiki/` |
| Reviewer | `ff-reviewer` (read-only, fresh context) | nothing; you save its reply |

**Every dispatch:** run `heartbeat`, run `pick-model` for the role (reviewer: `-Stage <stage>`), and
pass the printed `MODEL` as the Agent call's `model` (it overrides the agent file); `MODEL inherit`
means pass no model. Effort is fixed in each agent file. Pass agents **absolute file paths only**,
never your reasoning or a worker's transcript.

If an `ff-*` agent is not registered (clone-time use), spawn a general-purpose subagent, tell it
to read and follow `<skill-dir>/../../agents/<name>.md` (repo checkout) or the project's
`.claude/agents/<name>.md`, pass the `pick-model` result as `model`, and forbid the reviewer any
file change.

## Step 0 - Intake (only stage with mandatory human approval)

1. Arguments `resume <dir> --auto` (a scheduled firing): run `auto-check` and do exactly what its
   `ACTION` line says. It logs the RESUME itself. Never ask the user anything in such a firing.
   Arguments `resume <dir>` (the user resuming), in this order:
   - Record what the user decided: append it to `01-spec.md` under `## Decisions` (dated). If they
     ran a manual QA checklist, save their result per item as `evidence/qa/Q<n>-manual.log` (their
     words, date) and check those Q items with that file as evidence.
   - Log `RESUME` with note `user <reason>` (resets the loop and send-back counters).
   - Re-arm Auto resume if `AUTO_RESUME = on` (`references/auto-resume.md`).
   - Continue with the `NEXT` line of `status`. Exception: after a manual QA result, skip the QA
     tester for that round and go straight to the qa gate and reviewer.
   Either way, skip the rest of Step 0.
2. Run `init` with the settings above; its `WORKDIR` line is `<dir>`. If it warns that the tree is
   dirty, that `work/` is not ignored, or that this is not a git repository, get it fixed first
   (commit/stash, add `work/` to `.gitignore`, `git init`); round diffs depend on it.
3. Fill `00-context.md` yourself (the seed every agent reads instead of re-exploring): build and
   test commands, how to launch, key folders, conventions from CLAUDE.md/AGENTS.md, wiki index. If
   the project has no test command, write `test: none`; the planner then adds a minimal test setup.
4. Interview the user until nothing is ambiguous: scope, explicit non-goals, edge cases, acceptance
   criteria. Ask in small batches. Write `01-spec.md` (Out of scope is mandatory). In `## Risk` set
   `level: high` for security, auth, concurrency, data migration/persistence formats or a public
   API; otherwise leave `normal`.
5. Show the spec, get explicit approval, log `intake PASS`, then arm Auto resume if `AUTO_RESUME = on`.
   Non-interactive runs: if the request itself states scope, out of scope, acceptance criteria and
   verify commands and says the spec is pre-approved, skip the interview, write the spec from it,
   and log `intake PASS` with note `pre-approved by request`.

## Stage loop (plan -> dev -> qa -> wiki)

For each stage, log `<stage> START`, then repeat rounds until PASS or a limit. Take the round
number N from `status` (`NEXT ... round N`); numbers are per stage and never restart within a
work folder (also after a QA send-back), so no round file is ever overwritten.

1. **Worker.** Dispatch the stage agent with `00-context.md`, `01-spec.md`, `02-todo.md` (from dev
   on), and the latest review for this stage, or after a QA send-back the latest
   `reviews/qa-r*.md`, as the fix list. Its last line decides:
   `RESULT: DONE...` -> gate. `BLOCKED_ENV`, `BLOCKED_PERMISSION`, `NEEDS_DECISION` -> save the
   worker's reply as `reviews/<stage>-r<N>.md`, log the status with round N, and escalate now. No
   `RESULT:` line at all -> treat as a failed gate (`VERDICT: FAIL (no RESULT line)`).
2. **Gate (no model involved).**
   - plan: `check-todo -FormatOnly`. If `01-spec.md` said `test: none` and the plan adds a test
     setup, update the spec's Verify `test:` line to the command the plan names.
   - dev: `verify -Stage dev` with the spec's build and test commands; `check-todo -Prefix D`;
     `diff -Round <N>` (exit 1 when a file's line endings were rewritten).
   - qa: `verify -Stage qa`; `check-todo -Prefix Q -AllowOpen`.
   - wiki: `wiki-check`.
   - Any non-zero exit: write `reviews/<stage>-r<N>.md` as `VERDICT: FAIL (gate)` plus the failing
     output, log FAIL, next round. Do not call the reviewer on a failed gate.
3. **Review.** Dispatch `ff-reviewer` (model from `pick-model -Role reviewer -Stage <stage>`) with
   the stage name and file list. Save its reply verbatim to `reviews/<stage>-r<N>.md`, removing
   only code-fence lines, so the file starts with the `VERDICT:` line.
4. **Decide.** Log the round with `-Model <worker model> -ReviewerModel <reviewer model>`.
   - `PASS` -> log PASS, next stage.
   - `FAIL` -> log FAIL with a one-line note. If two consecutive **reviewer** FAILs report the same
     issue, log `LOOP_LIMIT` and escalate (gate FAILs only count toward `MAX_ROUNDS`; `pick-model`
     already raises the model after 2 FAILs). If `event` exits 3, escalate.
   - `NEEDS_DECISION` -> log it and escalate.

QA FAIL by cause:
- `CAUSE: QA` (the tester's own evidence is wrong or misplaced; product fine) -> plain FAIL, next QA round.
- `CAUSE: IMPL` -> `event ... -Status FAIL -SendBack IMPL`, then dev with the QA review as the fix list.
- `CAUSE: SPEC` -> `-SendBack SPEC`, then plan. If fixing it needs a change to the approved spec
  itself (the planner may not edit `01-spec.md`), log `NEEDS_DECISION` and escalate instead.
- `CAUSE: ENV` (could not be exercised) -> log `BLOCKED_ENV` and escalate. When the product cannot be
  exercised automatically (GUI without automation, hardware) the QA tester returns `BLOCKED_ENV`
  with `evidence/qa/manual-checklist.md`; give that checklist to the user, never fake it.
- If `event` exits 3, escalate.

Development is sequential: one developer at a time on the main working tree.

## Escalation and pause

Stop, delete the schedule (`references/auto-resume.md`), report in this shape, then wait:

```text
[feature-flow] <stage> <STATUS> (round N)
What happened: <one line>
Evidence: <file paths>
What I need from you: <decision / permission / environment fix / manual QA results>
Resume with: /feature-flow resume <dir>
```

If the user interrupts or asks to stop, log `PAUSE` (note `user stopped`, on the stage `status`
shows) and delete the schedule, so no automatic resume restarts the work.

## Auto resume (AUTO_RESUME = on)

A usage limit ends the turn and a stopped turn cannot schedule anything, so the schedule is armed
right after `intake PASS` and re-armed on every user resume. How to arm, delete and what each
`auto-check` decision means: `references/auto-resume.md`. In short, `auto-check` resumes only an
idle (45 min), non-escalated, non-paused run, at most 3 times per 24 h, and its `ACTION` line says
what to do. Automatic resumes never reset counters.

## Finish

When `NEXT` says `done PASS`: log `done PASS`, delete the schedule, and report what was built,
verify results, QA evidence folder, wiki pages touched, review rounds and models per stage (from
`events.log`), and anything left open. Offer to commit the change (code, tests, `docs/wiki/`;
never `work/`) and commit only if the user agrees; an uncommitted change makes the next `init` warn. Answer later questions from `events.log`, `reviews/` and
`evidence/`, not from memory.
