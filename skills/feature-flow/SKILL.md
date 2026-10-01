---
name: feature-flow
description: Runs a plan -> develop -> QA -> wiki agent workflow inside the current project with Claude only (no second vendor model). The main session acts as the master - it interviews the user into a spec, then drives worker and read-only reviewer subagents stage by stage, gates every stage mechanically (build/test output, file:line evidence, diff, wiki links) before review, records everything under work/<id>/, and escalates to the user only on block, decision or loop limit. Use when the user explicitly asks for a feature or change to be taken end to end with planning, implementation, QA and documentation, or invokes /feature-flow. Not for small one-file fixes. Korean triggers - 기획부터 위키까지, 워크플로로 개발해줘, 기획 개발 QA 위키, 에이전트 워크플로, feature-flow.
disable-model-invocation: true
---

# Feature Flow (master procedure)

You are the **master**. The user talks only to you. You never write feature code yourself: you
interview, write the spec, dispatch subagents, run the gates, record state, and escalate.

Settings (change here, nowhere else; always pass them to ff.ps1 as shown):

- `MAX_ROUNDS = 3` worker/reviewer rounds per stage. Use 2 on weak/local models.
- `MAX_QA_CYCLES = 2` times QA may send work back to dev/plan.

`<skill-dir>` is the folder containing this SKILL.md. Run everything from the project root.
Standard helper calls (copy them; `<dir>` is the work folder):

```text
$ff = "<skill-dir>/scripts/ff.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File $ff init -Title "<short title>"
powershell -NoProfile -ExecutionPolicy Bypass -File $ff event -WorkDir <dir> -Stage <stage> -Status <STATUS> -Round <N> -Note "<one line>" -MaxRounds 3 -MaxQaCycles 2
powershell -NoProfile -ExecutionPolicy Bypass -File $ff status -WorkDir <dir> -MaxRounds 3 -MaxQaCycles 2
powershell -NoProfile -ExecutionPolicy Bypass -File $ff check-todo -WorkDir <dir> -FormatOnly        (plan gate)
powershell -NoProfile -ExecutionPolicy Bypass -File $ff check-todo -WorkDir <dir> -Prefix D          (dev gate)
powershell -NoProfile -ExecutionPolicy Bypass -File $ff check-todo -WorkDir <dir> -Prefix Q -AllowOpen  (qa gate)
powershell -NoProfile -ExecutionPolicy Bypass -File $ff diff -WorkDir <dir> -Round <N>               (dev gate)
powershell -NoProfile -ExecutionPolicy Bypass -File $ff wiki-check                                   (wiki gate)
```

Never hand-edit `events.log`. File formats: `references/work-folder-layout.md`. Status codes:
`references/status-codes.md`.

## Agents

| Role | Agent (plugin install: prefix `peace-skillbank:`) | Writes |
|---|---|---|
| Planner | `ff-planner` | `02-todo.md` |
| Developer | `ff-developer` | source code, D checks, `evidence/dev/worker-run.log` |
| QA tester | `ff-qa-tester` | `evidence/qa/`, Q checks |
| Wiki writer | `ff-wiki-writer` | `docs/wiki/` |
| Reviewer | `ff-reviewer` (read-only, fresh context, Sonnet) | nothing; you save its reply |

If an `ff-*` agent is not registered (clone-time use), spawn a general-purpose subagent, tell it
to read and follow `<skill-dir>/../../agents/<name>.md`, pass the `model` from that file's
frontmatter, and for the reviewer forbid any file change.

Pass agents **file paths only**, never your own reasoning or the worker's transcript. The reviewer
must judge from the spec, the diff and the evidence, not from the worker's explanation.

## Step 0 - Intake (only stage with mandatory human approval)

1. If the argument is `resume <dir>`: run `status`, log `RESUME` for the stage it reports, and
   continue with its `NEXT` line. Skip the rest of Step 0.
2. Run `init`. If it warns that the tree is dirty, that `work/` is not ignored, or that this is not
   a git repository, tell the user and get it fixed (commit/stash, add `work/` to `.gitignore`,
   `git init`) before continuing; round diffs depend on it.
3. Fill `00-context.md` yourself (the shared seed every agent reads instead of re-exploring): build
   and test commands, how to launch, key folders, conventions from CLAUDE.md/AGENTS.md, wiki index.
   Find the verify commands in the repo; ask the user only if you cannot. If the project has no
   test command, write `test: none` and say so in the spec; the planner then adds a minimal test
   setup as the first D item.
4. Interview the user until nothing is ambiguous: scope, explicit non-goals, edge cases, acceptance
   criteria. Ask in small batches. Write `01-spec.md` (Out of scope is mandatory).
5. Show the spec, get explicit approval, log `intake PASS`.
   Non-interactive runs: if the request itself states scope, out of scope, acceptance criteria and
   verify commands and says the spec is pre-approved, skip the interview, write the spec from it,
   and log `intake PASS` with note `pre-approved by request`.

## Stage loop (plan -> dev -> qa -> wiki)

For each stage, log `<stage> START`, then for round N = 1..MAX_ROUNDS:

1. **Worker.** Dispatch the stage agent with: `00-context.md`, `01-spec.md`, `02-todo.md` (from dev
   on), and from round 2 the previous `reviews/<stage>-r<N-1>.md` as the fix list.
   If its last line is not `RESULT: DONE...`, log the reported status (`BLOCKED_ENV`,
   `BLOCKED_PERMISSION`, `NEEDS_DECISION`) and escalate now. Do not run the gate or the reviewer.
2. **Gate (no model involved).**
   - plan: `check-todo -FormatOnly`.
   - dev: run the spec's build and test commands, save full output to
     `evidence/dev/verify-r<N>.log`; `check-todo -Prefix D`; `diff -Round <N>`.
   - qa: run the test command again into `evidence/qa/verify-r<N>.log`; `check-todo -Prefix Q -AllowOpen`
     (open items are allowed only with a proof file, so the reviewer can judge the cause).
   - wiki: `wiki-check`.
   - If anything fails, write `reviews/<stage>-r<N>.md` as `VERDICT: FAIL (gate)` plus the failing
     output, log FAIL, and go to the next round. Do not call the reviewer on a failed gate.
3. **Review.** Dispatch `ff-reviewer` with the stage name and the file list. Save its reply verbatim
   to `reviews/<stage>-r<N>.md`.
4. **Decide.**
   - `PASS` -> log PASS, next stage.
   - `FAIL` -> log FAIL with a one-line note. If the same issue appears in two consecutive reviews,
     log `LOOP_LIMIT` and escalate. If `event` exits 3, escalate.
   - `NEEDS_DECISION` -> log it and escalate.

QA send-back: on a qa FAIL whose review says `CAUSE: IMPL` or `CAUSE: SPEC`, log the FAIL with note
`sendback=IMPL` or `sendback=SPEC` (this is how the send-back count survives a resume), then go to
dev (IMPL, with the QA review as the fix list) or plan (SPEC). If `event` exits 3, escalate.
`CAUSE: ENV` -> log `BLOCKED_ENV` and escalate. When the product cannot be exercised automatically
(GUI without automation, hardware), the QA tester returns `BLOCKED_ENV` with
`evidence/qa/manual-checklist.md`; give that checklist to the user instead of faking results.

## Escalation

Stop and report to the user in this shape, then wait:

```text
[feature-flow] <stage> <STATUS> (round N)
What happened: <one line>
Evidence: <file paths>
What I need from you: <decision / permission / environment fix>
Resume with: /feature-flow resume <dir>
```

Development is sequential in this version: one developer at a time on the main working tree.

## Finish

Log `done PASS`. Report: what was built, verify results, QA evidence folder, wiki pages touched,
review rounds per stage (from `events.log`), and anything left open. The user can ask about any
past step; answer from `events.log`, `reviews/` and `evidence/`, not from memory.
