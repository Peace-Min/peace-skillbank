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
  evidence/
    dev/verify-r1.log  full build/test output per round (master)
    dev/diff-r1.patch  git diff per round (master)
    qa/                screenshots, logs, outputs per Q item (qa tester)
  raw/                 optional: raw transcripts/exports if the user wants full traceability
  events.log           one line per event, written only by ff.ps1
```

## 01-spec.md

Sections: Goal, In scope, **Out of scope** (mandatory, never empty: write "none beyond In scope"
only if truly none), Constraints / cautions, Acceptance criteria (testable sentences), Verify
commands (build, test).

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
- Every file ref must exist, and line numbers must be inside the file.
- Separate several refs with `|`. Free text is allowed next to refs but does not count; paths with spaces are not supported.

Example of a valid checked item:

```markdown
- [x] D1: Add LockoutPolicy with MaxAttempts=5
  - evidence: src/Auth/LockoutPolicy.cs:12-40 | evidence/dev/verify-r2.log
```

## reviews/<stage>-r<N>.md

```text
VERDICT: PASS | FAIL | NEEDS_DECISION
CAUSE: IMPL | SPEC | ENV            (QA stage FAIL only)
ISSUES:
- [high|med|low] <where: file:line or TODO id> - <problem> - <expected>
```

## events.log

`<ISO time> | <stage> | <STATUS> | r<N> | <note>`; stages `intake plan dev qa wiki done`.
