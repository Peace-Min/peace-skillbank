# Status codes

| Code | Who emits | Meaning | Master action |
|---|---|---|---|
| `START` | master | stage begins (resets the stage FAIL counter) | dispatch worker |
| `PASS` | reviewer / master | stage accepted | next stage |
| `FAIL` | gate / reviewer | defects found | next round with the review as fix list |
| `BLOCKED_ENV` | worker | environment missing: tool not installed, port in use, no GUI automation, hardware absent | escalate with what is missing |
| `BLOCKED_PERMISSION` | worker | an action needs approval the worker does not have | escalate, ask for the permission, resume |
| `NEEDS_DECISION` | worker / reviewer | spec is ambiguous or two valid options conflict | escalate with the options |
| `LOOP_LIMIT` | master / ff.ps1 | MAX_ROUNDS reached, or the same issue repeated in two consecutive reviews | escalate with the last two reviews |
| `FAIL` + note `sendback=IMPL` or `sendback=SPEC` | master | QA sends work back to dev or plan | counted by ff.ps1 against MAX_QA_CYCLES |
| `PAUSE` | master | the user interrupted or asked to stop | delete the schedule; no automatic resume |
| `RESUME` + note `user ...` | master | the user resumes; lifts a halt and resets the loop and send-back counters | continue from `NEXT` |
| `RESUME` + note `auto ...` | ff.ps1 auto-check | unattended resume after a usage-limit or API-error stop (Claude Code still open); resets nothing; max 3 per 24 h | continue from `NEXT`, ask nothing |

Workers never work around a block by guessing (fake data, skipped tests, stubbed checks). A clear
`BLOCKED_*` with the exact error is always better than a fake PASS.
