# Auto resume

**What it covers:** a turn that ended because of a usage limit or an API error, while Claude Code
stays open. It does not survive closing or crashing Claude Code: `CronCreate` jobs live only in the
session, fire only while the session is idle (never mid-turn), and recurring jobs expire after 7
days. After any of those, the user runs `/feature-flow resume <dir>`, which re-arms the schedule.

## Arm (after `intake PASS`, and on every user `resume`)

1. If `<dir>/schedule.txt` exists, `CronDelete` the id in it (ignore "not found": the job may have
   died with an earlier session) and delete the file.
2. `CronCreate` a recurring job, cron `17,47 * * * *` (about every 30 min, off the :00/:30 marks),
   prompt `/peace-skillbank:feature-flow resume <dir> --auto` for a plugin install, or
   `/feature-flow resume <dir> --auto` for a project-level or clone-time install.
3. Write `<id> <ISO time>` to `<dir>/schedule.txt`. Tell the user once: it runs only while Claude
   Code is open and idle, and expires after 7 days.

No `CronCreate`: suggest `/loop 30m /peace-skillbank:feature-flow resume <dir> --auto`, or a desktop
scheduled task with the same prompt in the project folder (it starts a fresh session; the work
folder carries all state, so that works too).

## Delete

On finish, on any escalation the master reports, on `PAUSE`, and when `auto-check` says so:
`CronDelete` the id in `schedule.txt` (ignore "not found": a one-shot job deletes itself after
firing, and jobs die with their session), then delete `schedule.txt`.

An automatic resume does not re-arm anything: the recurring job armed at intake keeps firing, so
a second interruption is covered too. Only a one-shot job (used in tests) leaves no safety net.

## Each firing: `ff.ps1 auto-check`

| DECISION | When | ACTION it prints |
|---|---|---|
| `STOP` | no events, intake not approved, finished, escalated (`BLOCKED_*`, `NEEDS_DECISION`, `LOOP_LIMIT`, a limit reached) or `PAUSE` | delete the schedule; do nothing else |
| `LIMIT` | 3 or more automatic resumes in the last 24 h (checked before idle time) | delete the schedule; write a short report for the user; stop |
| `WAIT` | events.log or the master's `heartbeat` lock changed less than 45 min ago (still running here or in another session) | do nothing |
| `RESUME` | otherwise | already logged `RESUME ... auto`; continue from `NEXT` without asking; tell the worker the round was interrupted and to inspect the current diff |

Safety properties:

- Only a `RESUME` whose note starts with `user` resets the loop and send-back counters. `auto`, or
  any other note, never does, and counts toward the 24 h limit.
- `NEXT` ignores RESUME markers and is computed from the last real event, so a resume right after
  `intake PASS`, a QA send-back or a stage PASS goes to the right place.
- The master runs `heartbeat` before every dispatch, so a second session (or a firing in this one)
  waits while a round is in progress. A single subagent call longer than 45 min without any
  heartbeat can still look idle; this is the known limit.
- If the user is chatting in the same session when a job fires, the firing runs between their
  messages; its first line `[feature-flow] auto resume of <dir>` makes that visible.
