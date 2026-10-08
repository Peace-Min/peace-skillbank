---
name: feature-flow
description: Takes a feature or change end to end in the current project - interview, approved spec, plan, develop, QA, wiki - with Claude subagents, a read-only reviewer on a different model, mechanical build/test/evidence gates, records under work/<id>/ and automatic resume. Windows only (PowerShell 5.1+). Runs only when the user invokes it explicitly (/peace-skillbank:feature-flow or /feature-flow); never start it on your own because a request mentions planning, QA or a wiki. Not for small one-file fixes.
disable-model-invocation: true
---

# Feature Flow (master procedure)

You are the **master**. The user talks only to you. You never write feature code yourself: you
interview, write the spec, dispatch subagents, run the gates, fix what blocks the run when you
safely can, record state, and escalate only what needs the user.

**Talking to the user.** Write every message to the user in the user's language (the language of
their request; Korean request -> Korean). That means **every** line the user sees, including one-line
progress notes between tool calls ("Plan written: 21 D items, running the gate" ->
"기획 작성 완료: 개발 21개, QA 15개. 게이트를 돌립니다."), interview questions, the spec summary,
escalations and the final report, even though this skill and the work files are in English. Keep
commands, paths, IDs and status codes as they are. Files in the work folder may stay in English. **Every question with choices goes through the
`AskUserQuestion` tool** (load it with ToolSearch `select:AskUserQuestion` if it is deferred): at
most 4 questions per call, 2-4 options each, your recommendation first with "(Recommended)" in its
label (in the user's language), a one-line trade-off per option; the user can always type another
answer. Use plain chat only for an open question with no sensible options, or when the tool is not
available (a scheduled `--auto` firing never asks anything).

**Secrets.** Never put a password, token or key in a command line, a file, a commit, a message or a
subagent brief, yourself included. Pass it through an environment variable the user sets, or stdin
from a prompt the user fills; write only the variable names to `00-context.md` (`Secrets:` line). If a
project file already contains a secret in plain text, do not copy it anywhere and tell the user once.

**Windows only:** `ff.ps1` needs Windows PowerShell 5.1+ and runs gate commands through `cmd.exe`.
On macOS or Linux, stop and tell the user this skill does not run there.

Settings (defaults; pass them to `init` exactly as below). A project changes them with
`.claude/feature-flow-settings.txt` (`Key=value` lines: MaxRounds, MaxGateFails, MaxQaCycles,
MaxFixes, MaxDecisions, MaxStageRounds, MaxModel, VerifyTimeoutMin, Parallel=on|off, AutoResume=on|off); `init`
applies it over these defaults. That is the only way for a plugin install, whose SKILL.md must not
be edited. `init` prints the effective values on its `SETTINGS` line and stores them in
`<dir>/settings.txt`; every later ff.ps1 call (also scheduled firings) reads them from there. Use
`Parallel` and `AutoResume` from that line, not the defaults below:

- `MAX_ROUNDS = 3` reviewer FAILs per stage before the loop limit.
- `MAX_GATE_FAILS = 3` mechanical gate FAILs per stage before the loop limit (a separate budget).
- `MAX_QA_CYCLES = 2` times QA may send work back to dev/plan.
- `MAX_FIXES = 1` master interventions per stage and kind (`block:` and `loop:` each) before escalating.
- `MAX_STAGE_ROUNDS = 6` rounds that did not pass (any FAIL or NEEDS_DECISION) per stage in total; a loop
  MASTER_FIX does not reset it, only the user's RESUME does. At the cap: no more fixes, escalate.
- `MAX_DECISIONS = 5` in-scope decisions the master may take on its own per work item (one per proposal or choice; never merge several into one entry).
- `MAX_MODEL = fable` strongest model `pick-model` may choose (`opus` to cap cost; `inherit` to never pass a model).
- `VERIFY_TIMEOUT_MIN = 20` minutes each build/test/ui-test command may run in a gate before it is killed (FAIL).
- `PARALLEL = on` (`Parallel`) develop independent `[group:X]` work in parallel worktrees when the conditions below hold.
- `AUTO_RESUME = on` (`AutoResume`) resume by schedule after a usage-limit or API-error stop while Claude Code stays open.

`<skill-dir>` is the copy of this skill that contains `scripts/ff.ps1`. If
`<project root>/.claude/skills/feature-flow/scripts/ff.ps1` exists, use that copy even when the
skill loader reports another base directory. Run everything from the project root (`ff.ps1` refuses a work folder outside `-Root`, which defaults
to the current folder; never run it from inside the work folder):

```text
$ff = "<skill-dir>/scripts/ff.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File $ff init -Title "<short title>" -MaxRounds 3 -MaxGateFails 3 -MaxQaCycles 2 -MaxFixes 1 -MaxDecisions 5 -MaxStageRounds 6 -MaxModel fable -VerifyTimeoutMin 20
powershell -NoProfile -ExecutionPolicy Bypass -File $ff status -WorkDir <dir>
powershell -NoProfile -ExecutionPolicy Bypass -File $ff pick-model -WorkDir <dir> -Role <planner|developer|qa|wiki|reviewer> [-Stage <stage>]
powershell -NoProfile -ExecutionPolicy Bypass -File $ff gate -WorkDir <dir> -Stage <plan|dev|qa|wiki> -Round <N>
powershell -NoProfile -ExecutionPolicy Bypass -File $ff event -WorkDir <dir> -Stage <stage> -Status <STATUS> -Round <N> -Note "<one line>" [-SendBack IMPL|SPEC] [-Model <alias>] [-ReviewerModel <alias>]
powershell -NoProfile -ExecutionPolicy Bypass -File $ff decision -WorkDir <dir> -Kind <decided|created|user|upheld> -Stage <stage> -Note "<text>" [-Overrides "<entry>"]
powershell -NoProfile -ExecutionPolicy Bypass -File $ff merge-evidence -WorkDir <dir>      (after parallel dev)
powershell -NoProfile -ExecutionPolicy Bypass -File $ff manual-check -WorkDir <dir>        (before handing QA items to a human)
powershell -NoProfile -ExecutionPolicy Bypass -File $ff auto-check -WorkDir <dir>         (scheduled firings)
```

`<dir>` is the absolute work folder. `-Round`: the current round N for FAIL, PASS, MASTER_FIX and
halts; `0` for START, PAUSE, RESUME and the intake and done events. Never hand-edit `events.log`. References:
`references/work-folder-layout.md` (files and formats; give the planner its absolute path),
`references/qa-methods.md` (QA: the method is the model's choice, the rules are fixed; give its
absolute path to planner, developer, QA tester and reviewer), `references/status-codes.md`,
`references/model-selection.md`, `references/auto-resume.md`.

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
(including, for developer and QA tester only, the absolute path of `ff.ps1`, so they can self-check with
`powershell -NoProfile -ExecutionPolicy Bypass -File <ff.ps1> check-todo ...`) plus, if useful, a short brief of your own (what matters, what to watch for). Give the reviewer file
paths only, never your reasoning or a worker's transcript.

**Continue the same worker** in later rounds after the same `<stage> START`: send the new fix list
to the agent you already dispatched (SendMessage with its id) instead of starting a fresh one, as
long as `pick-model` still returns the same model; it keeps its context and cache. Start a fresh
worker after a new `START` (e.g. dev after a QA send-back), after parallel development (its
worktrees are gone), when the model changes, when SendMessage is unavailable, or when the worker's
context has grown large: it already did two rounds in a row, or the Agent result reports more than
150k tokens for it. Every later call re-reads a large context, so a fresh worker with the fix list and
the file paths is cheaper than continuing it. The reviewer is
always a fresh agent.

The `ff-*` agents come from the plugin, or from `.claude/agents/` in a repo checkout or a
project-level install. Only if none is registered, spawn a general-purpose subagent, tell it to read
and follow the matching `agents/<name>.md`, pass the `pick-model` result as `model`, and forbid the
reviewer any file change.

## Step 0 - Intake (only stage with mandatory human approval)

1. `resume <dir> --auto` (a scheduled firing): if a subagent you dispatched in this session is still
   running, ignore the firing (do nothing, log nothing). Otherwise run `auto-check` and do exactly what
   its `ACTION` line says; it logs the RESUME itself. Never ask the user anything in such a firing.
   `resume <dir>` (the user resuming): if the user made a decision, record it with
   `decision -Kind user -Stage <stage> -Note "<decision>"` (add `-Overrides "<master entry>"` when it
   replaces one of your entries); save manual QA results as `evidence/qa/Q<n>-manual.log` in the
   format of `references/qa-methods.md` section 4 and check those Q items; log `RESUME` with note
   `user <reason>`; re-arm Auto resume; continue with `status`'s `NEXT` (after manual QA results, go
   straight to the qa gate and reviewer of the round `NEXT` names; the BLOCKED_ENV round counts).
   If the last dispatch was interrupted, the worker may have left partial changes: tell the next
   worker to inspect the current diff first and continue from it.
   Either way, skip the rest of Step 0.
2. A new request always gets a new work folder: run `init` with the settings above; its `WORKDIR` line
   is `<dir>` and its `SETTINGS` line gives the effective settings. Never reuse an existing folder for a
   new request, even for the same topic; `init` lists unfinished ones (`INFO:`), which continue only
   through `resume <dir>` (mention them to the user once). If it warns that the tree is dirty, that
   `work/` is not ignored, or that this is not a git repository, get it fixed first (ask the user).
3. Fill `00-context.md` yourself (the seed every agent reads instead of re-exploring): build and
   test commands, how to launch, key folders, conventions from CLAUDE.md/AGENTS.md, wiki index. No
   test command -> `test: none`; the planner then adds a minimal test setup. Also what the
   environment allows for QA, from the project files: the UI technology, any existing UI test,
   stress, measurement or loop runner, and what cannot run here (no build environment, field-only
   hardware). The planner picks QA methods from this.
4. Interview the user until nothing is ambiguous: scope, explicit non-goals, edge cases, acceptance
   criteria. Ask in batches of up to 4 through `AskUserQuestion` (see Talking to the user); put your
   findings from the code first in one short message, then the question call. Write `01-spec.md` (Out of scope is mandatory; Verify commands
   `- build:` / `- test:` are what `gate` runs; `- ui-test:` is an unattended runner command the dev
   and QA gates also run - an existing one, or `none`). Write acceptance criteria that can be
   observed (what is shown, returned, measured after which action), not only looks. In `## Risk` set `level: high` for security, auth,
   concurrency, data migration/persistence formats or a public API (functions, endpoints or formats
   other code or users depend on); otherwise `normal`.
5. Before asking for approval, send one message in the user's language with the spec summary: goal,
   In scope, Out of scope, acceptance criteria (one line each), verify commands, risk level, and the
   absolute path of `01-spec.md`. Then ask with `AskUserQuestion` (options: approve / change
   something; put the `01-spec.md` path in the question). After a requested change, edit the spec and
   send the **full** summary again (mark what changed), then ask again. Log `intake PASS` only after
   an explicit approve, then arm Auto resume if `init` printed `AutoResume=on`.
   Non-interactive runs: if the request itself states scope, out of scope, acceptance criteria and
   verify commands and says the spec is pre-approved, write the spec from it and log `intake PASS`
   with note `pre-approved by request`.

## Stage loop (plan -> dev -> qa -> wiki)

Log `<stage> START`, then repeat rounds until PASS or a limit; take N from `status`
(`NEXT ... round N`). Round numbers are per stage and never restart within a work folder.

1. **Worker.** Dispatch (or continue) the stage agent with `00-context.md`, `01-spec.md`,
   `02-todo.md` (from dev on), and the fix list: the review file of the highest round number of this
   stage (a `-master.md` file wins for its round; after a QA send-back: the latest `reviews/qa-r<N>.md`). Its last line decides:
   Save every worker reply verbatim as `evidence/<stage>/worker-r<N>.md` (parallel groups:
   `worker-r<N>-<X>.md`; a skipped worker: one line `worker skipped: <why>`); the gate checks it.
   If the reply lists `DECISIONS-PROPOSED:` (open choices the worker made itself that a user could
   notice: behavior, public interface, data formats, what acceptance criteria check; internal names,
   structure and comments are not listed and are not decisions), treat each as a
   **Master decision** before the gate: record it with `decision -Kind decided` whose `-Note` starts
   with the proposal text copied as written (the gate matches its first 20 letters and digits; replace
   any double quote in a `-Note` with a single quote, or the argument breaks),
   or escalate it if it changes scope, acceptance criteria or a public interface; the gate fails
   while one is unrecorded. If a gate failed only because of your own mistake (a decision not
   recorded, a command run from the wrong folder), fix it and run the next round with
   `worker skipped: master error - <what>` instead of dispatching the worker again.
   `RESULT: DONE...` -> gate. `BLOCKED_*` -> **Master fix** below. `NEEDS_DECISION` -> save the
   worker's reply as `reviews/<stage>-r<N>.md` (`event` checks it), then **Master decision** below. No `RESULT:` line -> treat as a failed gate (write `VERDICT: FAIL (no RESULT
   line)` as the round's review, log FAIL with note `gate: no RESULT line`).
2. **Gate.** Run `gate -Stage <stage> -Round <N>`. It runs the stage's checks (plan: TODO format;
   dev: spec build/test, evidence refs, diff incl. line-ending rewrites; qa: build/test and Q
   evidence; wiki: links), and on failure writes `reviews/<stage>-r<N>.md` and logs the FAIL itself.
   Exit 1 -> next round. Exit 3 -> loop limit (below). Do not call the reviewer on a failed gate.
   Plan stage only: if the spec said `test: none` and the plan adds a test setup, update the spec's
   `- test:` line first; likewise set `- ui-test:` when the plan adds a persistent unattended runner.
3. **Review.** Dispatch a fresh `ff-reviewer` (model from `pick-model -Role reviewer -Stage <stage>`)
   with the stage name and file list. Save its reply as `reviews/<stage>-r<N>.md`, removing only
   code-fence lines.
4. **Decide.** Log the round with `-Model <worker> -ReviewerModel <reviewer>`. `event` refuses (exit 2)
   a PASS or NEEDS_DECISION that the round's review file does not say, a FAIL over a review that says
   PASS, or a verdict whose review skipped a standing master entry under `DECISIONS:`; then copy the
   verdict correctly, or dispatch a fresh reviewer for a review that skipped an entry.
   - `PASS` -> log PASS, next stage. Pass the review's `low` issues to the next stage's worker as
     notes in your brief (not as a fix list); they never block.
   - `FAIL` -> log FAIL with a one-line note; exit 3 -> loop limit.
   - `NEEDS_DECISION` -> **Master decision**.

**Master fix** (a worker returned `BLOCKED_ENV` / `BLOCKED_PERMISSION`, or the loop limit hit):
- Blocked: if the cause is inside the project and safe to fix (install a dependency the project
  already declares, stop a process this run started, create a missing folder or config from the
  spec, run the blocked command yourself when you are allowed to), fix it, log `MASTER_FIX` with note
  `block: <what you did>`, and run the round `NEXT` names. Blockers found in the same round (for
  example two parallel groups) go into one `MASTER_FIX`. If the fix creates files, record each with
  `decision -Kind created -Note "<path> (<why>)"` so the reviewer can check it. Never change system
  settings, credentials or anything outside the project, and never delete user data.
- Loop limit: compare the last reviews. If they disagree with each other or the worker misread
  them, write one consolidated fix list to `reviews/<stage>-r<N>-master.md` (N = the last round),
  log `MASTER_FIX` with note `loop: <summary>`, and run the round `NEXT` names; it resets the stage's
  FAIL budgets, while `pick-model` keeps the raised model.
- If `event` exits 3 on a `MASTER_FIX`, that kind's budget is used up: ff.ps1 has already logged the
  halt instead of the fix, so escalate. If no fix is safe, log `BLOCKED_*` / `LOOP_LIMIT` and escalate.

**Master decision** (`NEEDS_DECISION` from a worker): if the choice stays inside the approved scope
(an edge case, a naming or structure choice, behavior the spec leaves open), decide it and record it
with `decision -Kind decided -Stage <stage> -Note "<decision and why>"`, then continue. If it
changes scope, acceptance criteria or a public interface, or `decision` exits 3 (`MAX_DECISIONS`
used up), log `NEEDS_DECISION` and escalate.
When no reviewer ran in that round (a worker's `NEEDS_DECISION` or its `DECISIONS-PROPOSED` over
the cap), write `reviews/<stage>-r<N>.md` yourself as `RESULT: NEEDS_DECISION - <what needs the user,
one line per item>` before logging. After the user answers, record each answer with `decision -Kind
user`, log `RESUME` with note `user ...`, and run the round `NEXT` names: the worker applies the answers,
or, if nothing in the work changes, write `worker skipped: <why>` and go straight to the gate. `decision` also writes a `DECIDED` line to events.log.
Your decisions are not final: every reviewer judges each standing `master-decided` /
`master-created` entry against the approved spec and lists it under `DECISIONS:`. Entries the user
later overrides still count toward `MAX_DECISIONS`.

**Second opinion** (a reviewer marks one of your entries `[NEEDS_DECISION]`): you never decide it
again yourself. Once per entry, before logging anything, dispatch a fresh `ff-reviewer` with the
model from `pick-model -Role second -Stage <stage>`, giving it `01-spec.md`, the disputed entry and
the first review, and asking only for `[ok|NEEDS_DECISION] <entry> - <reason>`; save the reply as
`reviews/<stage>-r<N>-second.md`.
- `NEEDS_DECISION` too -> log `NEEDS_DECISION` (the round's review says so) and escalate to the user.
- `ok` -> record `decision -Kind upheld -Note "<entry text> (second opinion <model>: <reason>)"`,
  log FAIL with note `review: master entry upheld by second opinion` (it does not count toward the
  FAIL budget or model escalation), and run the next round as usual: the worker fixes any other
  issues of the first review (skip the worker if there were none: write `worker skipped: <why>` to
  `evidence/<stage>/worker-r<N>.md` and log the round with the previous worker's model), then `gate`, then a fresh reviewer, which no longer judges the upheld entry. An
  upheld entry can only be changed by the user.

**QA FAIL by cause:** `CAUSE: QA` (the tester's evidence is wrong; product fine) -> plain FAIL, next
QA round. `CAUSE: IMPL` -> `event ... -Status FAIL -SendBack IMPL`, then dev with the QA review as
the fix list. `CAUSE: SPEC` -> `-SendBack SPEC`, then plan; if fixing it needs a change to the
approved spec itself, it is a Master decision. `CAUSE: ENV` -> Master fix first. When the product
cannot be exercised automatically, the QA tester returns `BLOCKED_ENV` with
`evidence/qa/manual-checklist.md`. Run `manual-check` first: if it fails (an item without the
automation it tried), send the checklist back to the tester; never hand a human an item nobody
tried to automate. Only then give the checklist to the user.

## Parallel development (Parallel=on)

Use it only when all hold at the start of the dev stage: this is the first dev round of the work
item; `git status` shows no changes outside `work/`; `02-todo.md` tags D items with at least two
`[group:X]` groups whose `files:` lists do not overlap; and nothing a group needs is git-ignored (a
fresh worktree has no `node_modules`, `dist/`, build outputs or local config, so a group that must
build, test or touch such paths runs sequentially; if unsure, develop sequentially). Then, in one message, dispatch one
`ff-developer` per group with `isolation: "worktree"`, telling each its group letter and the work
folder as a path relative to the project root (`work/<id>`). An isolated agent cannot write to the
main work folder, so each writes its checks to `work/<id>/evidence/dev/group-<X>.md` inside its own
worktree, commits its code there, and ends with `BRANCH: <name> COMMIT: <sha>`. The Agent result
also reports the worktree path and branch. When all return, for each group:
1. Check the branch starts from the current commit: `git merge-base --is-ancestor HEAD <branch>`;
   if not, do not apply it (develop that group sequentially).
2. Copy `<worktree>/work/<id>/evidence/dev/group-<X>.md` (and `worker-run-<X>.log`) into `<dir>/evidence/dev/`.
3. Apply it to the main working tree without committing: `git merge --squash <branch>`.
If any squash conflicts, undo only the merge with `git reset --merge` (never `--hard`), check
`git status` shows no changes outside `work/` again, and develop all groups sequentially instead. Then remove the agent worktrees and branches
(`git worktree remove --force <path>`, `git branch -D <branch>`), run `merge-evidence`, and the normal
dev gate and review on the combined change. In every other case develop sequentially.

## Escalation and pause

Stop, delete the schedule (`references/auto-resume.md`), report in this shape (labels translated into
the user's language), then wait; when the user must choose (a decision, permission), add the
choices as an `AskUserQuestion` call right after the report:

```text
[feature-flow] <stage> <STATUS> (round N)
What happened: <one line>
What I already tried: <MASTER_FIX taken, or why none was safe>
Evidence: <file paths>
What I need from you: <decision / permission / environment fix / manual QA results>
Resume with: <command> resume <dir>
```

`<command>` is the slash command you were invoked with; if you were started from a plain prompt,
`/feature-flow` when `<project root>/.claude/skills/feature-flow/` exists (project or clone install),
otherwise `/peace-skillbank:feature-flow` (plugin).

If the user interrupts, refuses a dispatch or asks to stop, log `PAUSE` (note `user stopped`, on the
stage `status` shows) and delete the schedule before anything else; a scheduled firing then stops on
its own (`auto-check` returns STOP for a paused run).

## Auto resume (AutoResume=on)

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
