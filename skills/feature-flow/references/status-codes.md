# Status codes

| Code | Who emits | Meaning | Master action |
|---|---|---|---|
| `START` | master | stage begins (resets the stage FAIL counter) | dispatch worker |
| `PASS` | reviewer / master | stage accepted | next stage |
| `FAIL` (note `gate: ...`) | ff.ps1 gate | a mechanical check failed | next round; counts toward MAX_GATE_FAILS |
| `FAIL` (other note) | master, after the reviewer | defects found | next round; counts toward MAX_ROUNDS |
| `MASTER_FIX` + note `block: ...` | master | the master fixed a blocker inside the project | run the next round; FAIL budgets unchanged; at most MAX_FIXES per stage |
| `MASTER_FIX` + note `loop: ...` | master | the master consolidated conflicting reviews at the loop limit (`reviews/<stage>-r<N>-master.md`) | run the next round; resets the stage's FAIL budgets; at most MAX_FIXES per stage |
| `BLOCKED_ENV` | worker | environment missing: tool not installed, port in use, no GUI automation, hardware absent | escalate with what is missing |
| `BLOCKED_PERMISSION` | worker | an action needs approval the worker does not have | escalate, ask for the permission, resume |
| `NEEDS_DECISION` | worker / reviewer | spec is ambiguous or two valid options conflict | escalate with the options |
| `LOOP_LIMIT` | master | a FAIL budget is used up and no MASTER_FIX is left or safe | escalate with the last two reviews |
| `FAIL` + note `sendback=IMPL` or `sendback=SPEC` | master | QA sends work back to dev or plan | counted by ff.ps1 against MAX_QA_CYCLES |
| `FAIL` after `CAUSE: QA` | master | the QA tester's evidence was wrong; the product is fine | next QA round, no send-back |
| `PAUSE` | master | the user interrupted or asked to stop | delete the schedule; no automatic resume |
| `RESUME` + note `user ...` | master | the user resumes; lifts a halt and resets the loop and send-back counters | continue from `NEXT` |
| `RESUME` + note `auto ...` | ff.ps1 auto-check | unattended resume after a usage-limit or API-error stop (Claude Code still open); resets nothing; max 3 per 24 h | continue from `NEXT`, ask nothing |

Workers never work around a block by guessing (fake data, skipped tests, stubbed checks). A clear
`BLOCKED_*` with the exact error is always better than a fake PASS.
