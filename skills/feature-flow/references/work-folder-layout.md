# work/<id>/ layout and file formats

Every hand-off between stages is a file. Any agent (or a human, or another LLM) can pick the work
up from the folder alone.

```text
work/<yyyyMMdd-HHmm>-<slug>/
  00-context.md        project seed: build/test/run commands, key folders, conventions (master)
  01-spec.md           approved spec (master, after the interview)
  02-todo.md           D items (dev) + Q items (qa) (planner; checked by dev/qa)
  reviews/
    plan-r1.md         one file per review round, reviewer reply saved verbatim
    dev-r1.md ...      gate failures are written here too, as VERDICT: FAIL (gate)
    dev-r3-master.md   the master's consolidated fix list after a loop limit (MASTER_FIX loop:)
  evidence/
    dev/verify-r1.log  full build/test output per round (master, gate)
    dev/diff-r1.patch  diff vs base per round, untracked files included (master, ff.ps1 diff)
    dev/worker-run.log the developer's own last build/test run (developer)
    dev/group-A.md     parallel mode: one group's D items with checks and evidence (developer of group A)
    qa/verify-r1.log   test output per QA round (master, gate)
    qa/Q1-<short>.log  proof per Q item: steps, observed, expected (qa tester)
    qa/manual-checklist.md  only when QA could not run automatically (qa tester)
    qa/Q1-manual.log   the user's manual QA result for an item, written by the master on resume
  raw/                 optional: raw transcripts/exports if the user wants full traceability
  base.txt             git commit the round diffs are taken against (ff.ps1 init)
  schedule.txt         "<CronCreate job id> <ISO time>" of the auto-resume schedule (master), if armed
  lock                 last master heartbeat time (ff.ps1 heartbeat), read by auto-check
  settings.txt         MaxRounds / MaxGateFails / MaxQaCycles / MaxFixes / MaxDecisions / MaxModel from init; read by every later ff.ps1 call
  events.log           one line per event, written only by ff.ps1
```

## 01-spec.md

Sections: Goal, In scope, **Out of scope** (mandatory, never empty: write "none beyond In scope"
only if truly none), Constraints / cautions, Acceptance criteria (testable sentences), Verify
commands (build, test), Risk (`- level: high|normal|low`; high for security, auth, concurrency,
data migration/persistence formats, public API; read by `ff.ps1 pick-model`), and, once the user
answers an escalation, `## Decisions`, written only by `ff.ps1 decision`:
`- master-decided (<date>, <stage>): <text>`, `- master-created (<date>, <stage>): <path> (<why>)`,
`- user (<date>, <stage>): <text> [(overrides: <master entry>)]`. Each also adds a `DECIDED` line to
events.log. Agents treat standing decisions as part of the spec; reviewers judge every master entry
no user entry overrides.

## 02-todo.md

```markdown
# TODO

## Dev
- [ ] D1: Add LockoutPolicy with MaxAttempts=5 [group:A]
  - evidence:
- [ ] D2: Unit tests for lockout after 5 failures
  - evidence:

## QA
- [ ] Q1: Five wrong passwords lock the account; sixth attempt shows the lock message
  - evidence:
```

Rules enforced by `ff.ps1 check-todo`:

- IDs are a letter prefix + number (`D1`, `Q3`). Dev items use `D`, QA items use `Q`.
- A checked item (`[x]`) must have an `evidence:` line with at least one **file ref**:
  `path`, `path:line` or `path:start-end`, relative to the project root or the work folder.
- A token is a file ref when it has a folder (`src/x.cs`) or a line (`x.cs:12`); every such ref must
  exist and its line numbers must be inside the file. Absolute paths are accepted only inside the
  project root or the work folder; prefer paths relative to the project root. A bare name like `x.cs` counts only if it
  exists in the project root; otherwise it is treated as prose.
- `evidence/...` refs resolve only inside the work folder; a file under the project root's
  `evidence/` never counts.
- Limit: the gate proves a ref exists and its lines are inside the file, not that the lines are
  the right ones. Whether the code there does what the item says is the reviewer's job.
- Separate several refs with `|`. Free text is allowed next to refs but does not count; paths with
  spaces are not supported.
- Dev gate: every D item checked. QA gate (`-AllowOpen`): a Q item may stay unchecked only if a
  proof file `evidence/qa/Q<n>-*` exists; the reviewer then fails the stage and names the CAUSE.
- Plan gate (`-FormatOnly`): at least one D and one Q item, unique IDs, every item has an evidence line.

Parallel groups: `[group:X]` on D items plus a `  - files:` line per item; groups never share a
file. Parallel developers write their items to `evidence/dev/group-X.md`; `ff.ps1 merge-evidence`
folds them into 02-todo.md (an id in two group files, or one missing from 02-todo.md, fails).

Example of a valid checked item:

```markdown
- [x] D1: Add LockoutPolicy with MaxAttempts=5
  - evidence: src/Auth/LockoutPolicy.cs:12-40 | tests/LockoutPolicyTests.cs:8-30
```

## reviews/<stage>-r<N>.md

```text
VERDICT: PASS | FAIL | NEEDS_DECISION
CAUSE: IMPL | SPEC | QA | ENV       (QA stage FAIL only)
ISSUES:
- [high|med|low] <where: file:line or TODO id> - <problem> - <expected>
DECISIONS:                          (or "DECISIONS: none")
- [ok|NEEDS_DECISION] <master entry> - <reason>
```

## events.log

`<ISO time> | <stage> | <STATUS> | r<N> | <note>`; stages `intake plan dev qa wiki done`.
A note may end with `[model=<alias>]` (from `event -Model`), recording which model ran that round.
`RESUME` notes: `user ...` (the user resumed; resets the loop and send-back counters) or `auto ...`
(written by `auto-check`; resets nothing). Any other note is treated like `auto`. A reviewer model
is recorded as `[reviewer=<alias>]` (from `event -ReviewerModel`).
A QA send-back is a qa FAIL whose note starts with `sendback=IMPL` or `sendback=SPEC`; `ff.ps1`
counts these against MAX_QA_CYCLES; the count survives a session restart and resets only on a `RESUME` noted `user ...` (the user's go-ahead).
