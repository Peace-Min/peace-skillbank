# QA methods and rules

**The method is the model's choice; the rules are fixed.** Projects differ too much for one test
procedure: one has a test suite, one only builds on a field PC, one is a GUI, one is about speed.
The planner picks a method per Q item from what the project actually allows, the QA tester may
switch to a better one, and the reviewer judges whether the method really proves the item. What
never changes is what counts as proof, where it is kept, who judges it, and how a manual item closes.

## 1. Fixed rules (gates and reviewer enforce them)

1. **Every Q item names its method.** In `02-todo.md`, under the item:
   `  - method: <auto|ui|measure|review|manual> - <why this method proves it here>`.
   `ff.ps1 check-todo -FormatOnly` rejects a Q item without a known method or without a reason.
2. **Run something real when the item is runtime behavior.** `review` (reading code, comparing
   compile output) is only for what cannot be run in this environment, and says why.
3. **Proof is kept in the work folder** (`<work folder>/evidence/qa/`): the exact command, its real
   output and exit code, and every file the method produced (screenshots, traces, measurement
   exports, before/after tables). Raw data, not only a summary, so another model can re-judge it.
4. **No simulated proof.** A state set up in memory to look fixed, an image or number from an older
   build, an edited file, a summary without the raw data behind it: all are `CAUSE: QA`.
5. **At least one `[regression]` Q item**: existing behavior next to the change still works (the
   things a user would notice breaking). Plan gate enforces it.
6. **A bug fix proves its test.** A D item tagged `[fix]` needs `evidence/dev/revert-<n>.log`: the
   new or changed test run with the fix reverted, failing, ending with `EXIT <non-zero>`. The dev
   gate checks the log and its exit line; the reviewer checks it is the right test failing.
7. **Judged by someone else.** The worker never grades itself; the reviewer (another model, fresh
   context) reads the raw evidence, including measurement interpretations.
8. **Manual is last.** A `manual` item first tries automation and records it in
   `evidence/qa/manual-checklist.md` (`- automation tried: <method> - <why it failed>`, checked by
   `ff.ps1 manual-check`), and closes only with the user's report `evidence/qa/Q<n>-manual.log`
   (section 4).

## 2. Method menu (examples, not a procedure)

| method | Use when | Typical proof |
|---|---|---|
| `auto` | The behavior can be driven by code: unit/integration tests, a CLI run, an API call, a stress or concurrency loop (N producers, fault injection, counts that must balance) | test output with the test names, exit code; for stress: run count, seed, invariants checked |
| `ui` | The item is what a window shows or does | harness/driver output and the screenshot that run wrote |
| `measure` | The item is speed, memory, CPU, GC, latency | the raw trace/export (or the exporter's files), before and after under the same conditions, the run repeated at least twice, the numbers compared |
| `review` | Nothing can run here (no build environment, field-only hardware); a compile-only check or reading code is the best available | the exact files and lines read, the compile commands and their before/after outputs, why running was impossible |
| `manual` | A human must look or touch (real DPI scaling, drag feel, hardware, a field PC) | the checklist entry and the user's report |

UI options, by what the project is (look at the files):

- **Existing UI test, harness or loop runner in the repo:** reuse it and add scenarios.
- **WPF:** an in-process harness. A console exe references the built app assembly, creates the real
  View on an STA thread with a fake store, drives the bound commands / click path
  (`ButtonAutomationPeer` + `IInvokeProvider`), asserts, and renders with `RenderTargetBitmap`.
- **WebView2, Electron, web:** start with a remote-debugging port and drive it with CDP or Playwright.
- **WinForms, Win32, or an app that cannot be referenced:** UI Automation (FlaUI or
  `System.Windows.Automation`) on the real exe.
- **DPI:** never change the user's display scaling. Supporting evidence: render at 144 DPI
  (`VisualTreeHelper.SetRootDpi`, `RenderTargetBitmap` at 1.5x) and assert no text is clipped; real
  scaling stays `manual` unless the spec accepts the render.

A one-off script under `evidence/qa/harness/` is fine for a single check. When the same kind of
check will be needed again (a UI the project keeps changing, a stress loop, a measurement exporter),
prefer a **persistent** runner under the project's test or tools folder; if it runs unattended, put
its command in the spec's `- ui-test:` line so the dev and QA gates run it too.

## 3. If you build a persistent runner

- Committed under the project's test/tools folder, built by the spec's build command.
- `<command> --scenario <name> --out <folder>`; the spec's `- ui-test:` runs all scenarios with
  `--out "%FF_EVIDENCE_DIR%"`. Gates set `FF_EVIDENCE_DIR` to `<work folder>\evidence\<stage>\gate-r<N>`,
  so a gate never overwrites a worker's proof; each gate command is killed after `VerifyTimeoutMin`.
- Exit `0` all assertions passed, `1` an assertion failed, `2` no verdict (could not start, element
  missing, skipped). Gates treat 2 as a failure; never return 0 for a skip.
- One line per assertion: `PASS <name>` / `FAIL <name>: expected <x>, got <y>`.
- Drives the user's path, never private fields. Hidden windows (`ShowActivated=false`,
  `ShowInTaskbar=false`, off-screen) so it does not steal focus. Creates and cleans up its own data.
  Skips production startup (login, network, devices); add the smallest seam as a D item if needed.

## 4. Manual items

`evidence/qa/manual-checklist.md`, one section per item that still needs a human:

```markdown
### Q4 Drag a row to another group
- automation tried: in-process harness - DataGrid drag-drop has no command path; FlaUI - drag pattern not supported by the grid
1. Open Orders, drag row A-001 onto the "Done" group.
2. Expected: the row moves and the count of "Done" goes up by one.
```

When the user reports back, the master writes `evidence/qa/Q<n>-manual.log` with exactly:

```text
checked-by: <who, as the user said>
checked-at: <date/time>
environment: <what the step needed, e.g. display scaling 150%, build or commit>
observed: <the user's words>
result: PASS | FAIL
```

and sets the item's evidence to that file. The reviewer accepts the user's report when the fields are
present and the observation matches the item, and fails it (`CAUSE: ENV`) if it says nobody did it.
