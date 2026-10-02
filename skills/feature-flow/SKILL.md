---
name: feature-flow
description: Takes a feature or change end to end in the current project - interview, approved spec, plan, develop, QA, wiki - with Claude subagents, a read-only reviewer on a different model, mechanical build/test/evidence gates, records under work/<id>/ and automatic resume. Use when the user asks to build something end to end with planning, review, tests and docs, or invokes /feature-flow. Not for small one-file fixes. Korean triggers - 기획부터 위키까지, 워크플로로 개발해줘, 기획 개발 QA 위키, 에이전트 워크플로.
---

# Feature Flow (master procedure)

You are the **master**. The user talks only to you. You never write feature code yourself: you
interview, write the spec, dispatch subagents, run the gates, fix what blocks the run when you
safely can, record state, and escalate only what needs the user.

Settings (change here, nowhere else). They are passed once to `init`, stored in
`<dir>/settings.txt`, and every later ff.ps1 call (also scheduled firings) reads them from there:

- `MAX_ROUNDS = 3` reviewer FAILs per stage before the loop limit.
- `MAX_GATE_FAILS = 3` mechanical gate FAILs per stage before the loop limit (a separate budget).
- `MAX_QA_CYCLES = 2` times QA may send work back to dev/plan.
- `MAX_FIXES = 1` master interventions per stage and kind (`block:` and `loop:` each) before escalating.
- `MAX_MODEL = fable` strongest model `pick-model` may choose (`opus` to cap cost; `inherit` to never pass a model).
- `PARALLEL = on` develop independent `[group:X]` work in parallel worktrees when the conditions below hold.
- `AUTO_RESUME = on` resume by schedule after a usage-limit or API-error stop while Claude Code stays open.

`<skill-dir>` is the copy of this skill that contains `scripts/ff.ps1`. If
`<project root>/.claude/skills/feature-flow/scripts/ff.ps1` exists, use that copy even when the
skill loader reports another base directory. Run everything from the project root:

```text
$ff = "<skill-dir>/scripts/ff.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File $ff init -Title "<short title>" -MaxRounds 3 -MaxGateFails 3 -MaxQaCycles 2 -MaxFixes 1 -MaxModel fable
powershell -NoProfile -ExecutionPolicy Bypass -File $ff status -WorkDir <dir>
powershell -NoProfile -ExecutionPolicy Bypass -File $ff pick-model -WorkDir <dir> -Role <planner|developer|qa|wiki|reviewer> [-Stage <stage>]
powershell -NoProfile -ExecutionPolicy Bypass -File $ff gate -WorkDir <dir> -Stage <plan|dev|qa|wiki> -Round <N>
powershell -NoProfile -ExecutionPolicy Bypass -File $ff event -WorkDir <dir> -Stage <stage> -Status <STATUS> -Round <N> -Note "<one line>" [-SendBack IMPL|SPEC] [-Model <alias>] [-ReviewerModel <alias>]
powershell -NoProfile -ExecutionPolicy Bypass -File $ff merge-evidence -WorkDir <dir>      (after parallel dev)
powershell -NoProfile -ExecutionPolicy Bypass -File $ff auto-check -WorkDir <dir>         (scheduled firings)
```

`<dir>` is the absolute work folder. `-Round`: the current round N for FAIL, PASS, MASTER_FIX and
halts; `0` for START, PAUSE, RESUME and the intake and done events. Never hand-edit `events.log`. References:
`references/work-folder-layout.md` (files and formats; give the planner its absolute path),
`references/status-codes.md`, `references/model-selection.md`, `references/auto-resume.md`.

## Agents

| Role | Agent (plugin install: prefix `peace-skillbank:`) | Writes |
|---|---|---|
| Planner | `ff-planner` | `02-todo.md` |
| Developer | `ff-developer` | source code, D checks, `evidence/dev/` |
| QA tester | `ff-qa-tester` | `evidence/qa/`, Q checks |
| Wiki writer | `ff-wiki-writer` | `docs/wiki/` |
| Reviewer | `ff-reviewer` (read-only, fresh context, a different model than the worker) | nothing; you save its reply |

**Every dispatch:** run `pick-model` for the role (reviewer: `-Stage <stage>`) and pass the printed
`MODEL` as the Agent call's `model` (`MODEL inherit` = pass none). Give workers absolute file paths
plus, if useful, a short brief of your own (what matters, what to watch for). Give the reviewer file
paths only, never your reasoning or a worker's transcript.

**Continue the same worker** in later rounds after the same `<stage> START`: send the new fix list
to the agent you already dispatched (SendMessage with its id) instead of starting a fresh one, as
long as `pick-model` still returns the same model; it keeps its context and cache. Start a fresh
worker after a new `START` (e.g. dev after a QA send-back), after parallel development (its
worktrees are gone), when the model changes, or when SendMessage is unavailable. The reviewer is
always a fresh agent.

The `ff-*` agents come from the plugin, or from `.claude/agents/` in a repo checkout or a
project-level install. Only if none is registered, spawn a general-purpose subagent, tell it to read
and follow the matching `agents/<name>.md`, pass the `pick-model` result as `model`, and forbid the
reviewer any file change.

## Step 0 - Intake (only stage with mandatory human approval)

1. `resume <dir> --auto` (a scheduled firing): run `auto-check` and do exactly what its `ACTION`
   line says; it logs the RESUME itself. Never ask the user anything in such a firing.
   `resume <dir>` (the user resuming): append the user's decision to `01-spec.md` under
   `## Decisions` (dated); save manual QA results as `evidence/qa/Q<n>-manual.log` and check those Q
   items; log `RESUME` with note `user <reason>`; re-arm Auto resume; continue with `status`'s
   `NEXT` (after manual QA results, go straight to the qa gate and reviewer).
   Either way, skip the rest of Step 0.
2. Run `init` with the settings above; its `WORKDIR` line is `<dir>`. If it warns that the tree is
   dirty, that `work/` is not ignored, or that this is not a git repository, get it fixed first.
3. Fill `00-context.md` yourself (the seed every agent reads instead of re-exploring): build and
   test commands, how to launch, key folders, conventions from CLAUDE.md/AGENTS.md, wiki index. No
   test command -> `test: none`; the planner then adds a minimal test setup.
4. Interview the user until nothing is ambiguous: scope, explicit non-goals, edge cases, acceptance
   criteria. Ask in small batches. Write `01-spec.md` (Out of scope is mandatory; Verify commands
   `- build:` / `- test:` are what `gate` runs). In `## Risk` set `level: high` for security, auth,
   concurrency, data migration/persistence formats or a public API; otherwise `normal`.
5. Show the spec, get explicit approval, log `intake PASS`, then arm Auto resume if `AUTO_RESUME = on`.
   Non-interactive runs: if the request itself states scope, out of scope, acceptance criteria and
   verify commands and says the spec is pre-approved, write the spec from it and log `intake PASS`
   with note `pre-approved by request`.

## Stage loop (plan -> dev -> qa -> wiki)

Log `<stage> START`, then repeat rounds until PASS or a limit; take N from `status`
(`NEXT ... round N`). Round numbers are per stage and never restart within a work folder.

1. **Worker.** Dispatch (or continue) the stage agent with `00-context.md`, `01-spec.md`,
   `02-todo.md` (from dev on), and the fix list: the review file of the highest round number of this
   stage (a `-master.md` file wins for its round; after a QA send-back: the latest `reviews/qa-r<N>.md`). Its last line decides:
   `RESULT: DONE...` -> gate. `BLOCKED_*` -> **Master fix** below. `NEEDS_DECISION` -> **Master
   decision** below. No `RESULT:` line -> treat as a failed gate (write `VERDICT: FAIL (no RESULT
   line)` as the round's review, log FAIL with note `gate: no RESULT line`).
2. **Gate.** Run `gate -Stage <stage> -Round <N>`. It runs the stage's checks (plan: TODO format;
   dev: spec build/test, evidence refs, diff incl. line-ending rewrites; qa: build/test and Q
   evidence; wiki: links), and on failure writes `reviews/<stage>-r<N>.md` and logs the FAIL itself.
   Exit 1 -> next round. Exit 3 -> loop limit (below). Do not call the reviewer on a failed gate.
   Plan stage only: if the spec said `test: none` and the plan adds a test setup, update the spec's
   `- test:` line first.
3. **Review.** Dispatch a fresh `ff-reviewer` (model from `pick-model -Role reviewer -Stage <stage>`)
   with the stage name and file list. Save its reply as `reviews/<stage>-r<N>.md`, removing only
   code-fence lines.
4. **Decide.** Log the round with `-Model <worker> -ReviewerModel <reviewer>`.
   - `PASS` -> log PASS, next stage.
   - `FAIL` -> log FAIL with a one-line note; exit 3 -> loop limit.
   - `NEEDS_DECISION` -> **Master decision**.

**Master fix** (a worker returned `BLOCKED_ENV` / `BLOCKED_PERMISSION`, or the loop limit hit):
- Blocked: if the cause is inside the project and safe to fix (install a dependency the project
  already declares, stop a process this run started, create a missing folder or config from the
  spec, run the blocked command yourself when you are allowed to), fix it, log `MASTER_FIX` with note
  `block: <what you did>`, and run the round `NEXT` names. Blockers found in the same round (for
  example two parallel groups) go into one `MASTER_FIX`. If the fix creates files, note them under
  `## Decisions` as `master-created: <path> (<why>)` so the reviewer treats them as in scope. Never
  change system settings, credentials or anything outside the project, and never delete user data.
- Loop limit: compare the last reviews. If they disagree with each other or the worker misread
  them, write one consolidated fix list to `reviews/<stage>-r<N>-master.md` (N = the last round),
  log `MASTER_FIX` with note `loop: <summary>`, and run the round `NEXT` names; it resets the stage's
  FAIL budgets, while `pick-model` keeps the raised model.
- If `event` exits 3 on a `MASTER_FIX`, that kind's budget is used up: ff.ps1 has already logged the
  halt instead of the fix, so escalate. If no fix is safe, log `BLOCKED_*` / `LOOP_LIMIT` and escalate.

**Master decision** (`NEEDS_DECISION`): if the choice stays inside the approved scope (an edge case,
a naming or structure choice, behavior the spec leaves open), decide it yourself, append it to
`01-spec.md` under `## Decisions` as `master-decided: ...`, and continue. If it changes scope,
acceptance criteria or a public interface, log `NEEDS_DECISION` and escalate.

**QA FAIL by cause:** `CAUSE: QA` (the tester's evidence is wrong; product fine) -> plain FAIL, next
QA round. `CAUSE: IMPL` -> `event ... -Status FAIL -SendBack IMPL`, then dev with the QA review as
the fix list. `CAUSE: SPEC` -> `-SendBack SPEC`, then plan; if fixing it needs a change to the
approved spec itself, it is a Master decision. `CAUSE: ENV` -> Master fix first. When the product
cannot be exercised automatically, the QA tester returns `BLOCKED_ENV` with
`evidence/qa/manual-checklist.md`; if you cannot provide automation, give the checklist to the user.

## Parallel development (PARALLEL = on)

Use it only when all hold at the start of the dev stage: this is the first dev round of the work
item; `git status` shows no changes outside `work/`; `02-todo.md` tags D items with at least two
`[group:X]` groups whose `files:` lists do not overlap. Then, in one message, dispatch one
`ff-developer` per group with `isolation: "worktree"`, telling each its group letter and the work
folder as a path relative to the project root (`work/<id>`). An isolated agent cannot write to the
main work folder, so each writes its checks to `work/<id>/evidence/dev/group-<X>.md` inside its own
worktree, commits its code there, and ends with `BRANCH: <name> COMMIT: <sha>`. The Agent result
also reports the worktree path and branch. When all return, for each group:
1. Check the branch starts from the current commit: `git merge-base --is-ancestor HEAD <branch>`;
   if not, do not apply it (develop that group sequentially).
2. Copy `<worktree>/work/<id>/evidence/dev/group-<X>.md` (and `worker-run-<X>.log`) into `<dir>/evidence/dev/`.
3. Apply it to the main working tree without committing: `git merge --squash <branch>`.
If any squash conflicts, run `git reset --hard HEAD` (the tree was clean before, and `work/` is
ignored) and develop all groups sequentially instead. Then remove the agent worktrees and branches
(`git worktree remove --force <path>`, `git branch -D <branch>`), run `merge-evidence`, and the normal
dev gate and review on the combined change. In every other case develop sequentially.

## Escalation and pause

Stop, delete the schedule (`references/auto-resume.md`), report in this shape, then wait:

```text
[feature-flow] <stage> <STATUS> (round N)
What happened: <one line>
What I already tried: <MASTER_FIX taken, or why none was safe>
Evidence: <file paths>
What I need from you: <decision / permission / environment fix / manual QA results>
Resume with: /feature-flow resume <dir>
```

If the user interrupts or asks to stop, log `PAUSE` (note `user stopped`, on the stage `status`
shows) and delete the schedule.

## Auto resume (AUTO_RESUME = on)

A usage limit ends the turn and a stopped turn cannot schedule anything, so the schedule is armed
right after `intake PASS` and re-armed on every user resume; `references/auto-resume.md` has the
details. `auto-check` resumes only an idle (45 min), non-escalated, non-paused run, at most 3 times
per 24 h, and never resets counters. Every ff.ps1 call refreshes the run's heartbeat.

## Finish

When `NEXT` says `done PASS`: log `done PASS`, delete the schedule, and report what was built,
verify results, QA evidence, wiki pages touched, rounds and models per stage (from `events.log`),
every `master-decided` entry and `MASTER_FIX`, and anything left open. Offer to commit the change
(code, tests, `docs/wiki/`; never `work/`) and commit only if the user agrees. Answer later
questions from `events.log`, `reviews/` and `evidence/`, not from memory.
