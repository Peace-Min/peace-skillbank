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
| `RESUME` | master | work continues after an escalation (resets the stage FAIL counter) | continue from the stage |

Workers never work around a block by guessing (fake data, skipped tests, stubbed checks). A clear
`BLOCKED_*` with the exact error is always better than a fake PASS.
