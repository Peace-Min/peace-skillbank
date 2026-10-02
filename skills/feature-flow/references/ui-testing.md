# UI testing (GUI QA without a human)

The skill cannot ship one GUI test tool for every project. It ships the procedure: find out what the
UI is built with, pick the strongest automation that fits, build a small **harness** into the
project once, record its command, and reuse it in every later work item. Only what automation truly
cannot see goes to a human, and only with the attempts written down.

## 1. Choose the method (master, Step 0; planner when it plans the harness)

Look at the project files, not at guesses. First match wins:

| Found | Method | What it drives |
|---|---|---|
| An existing UI test / harness / loop runner in the repo | **Reuse it**; add scenarios | whatever it already drives |
| `UseWPF` in a .csproj | **In-process harness**: a console exe (same target framework and platform) references the built app assembly, creates the real View/Window on an STA thread, sets `DataContext`, drives it, renders it with `RenderTargetBitmap` | real XAML, bindings, commands, view-models |
| WebView2, Electron, CEF, or a web front end | **Debug port / browser driver**: start the app with a remote-debugging port (WebView2 `--remote-debugging-port`, Electron `--remote-debugging-port`) or serve the page, drive it with CDP or Playwright, screenshot via the driver | real DOM, real app JS |
| WinForms, Win32, or a WPF app that cannot be referenced | **UI Automation**: launch the exe and drive it with FlaUI (UIA3) or `System.Windows.Automation`; find controls by AutomationId, then Name; capture the window | the real process, real input path |
| No UI in the change | `ui-test: none` | - |

Record the choice in `00-context.md` (`UI technology:`, `UI test harness command:`).

## 2. The harness contract (developer builds it; it stays in the repo)

- Lives under the project's test folder (e.g. `tests/UiHarness/`), is committed with the change and
  built by the spec's build command. Never under `work/` or a temp folder.
- One command, one scenario per run: `<command> --scenario <name> --out <folder>`. The spec's
  `- ui-test:` line is the command that runs **all** scenarios, e.g.
  `dotnet run --project tests/UiHarness -- --scenario all --out "%FF_EVIDENCE_DIR%"`; the gate sets
  `FF_EVIDENCE_DIR` to `<work folder>\evidence\qa`. QA may run single scenarios while testing.
- Exit codes: `0` every assertion passed, `1` an assertion failed, `2` no verdict (could not start,
  element not found, skipped). The gate treats 2 as a failure; never return 0 for a skip.
- Prints one line per assertion: `PASS <name>` / `FAIL <name>: expected <x>, got <y>`.
- Drives the product through the same path a user's action takes: invoke the bound command or the
  button's click path, set the selection, type into the bound control. Do not set private fields or
  call the view-model's internals to "pretend" an action happened.
- Writes screenshots and any dumps to `--out` (QA passes `<work folder>/evidence/qa/`).
- Hidden by default: WPF windows with `ShowActivated=false`, `ShowInTaskbar=false`, off-screen or
  `Opacity=0`, so a run does not steal the user's mouse or focus. A modal is driven from a
  `DispatcherTimer` with its own timeout. The gate also kills a run after `VerifyTimeoutMin`.
- Creates its own test data and removes it in `finally`; restores any settings or files it touched.
- Skips the app's production startup (login, network, device connections). If a view cannot be built
  without them, add the smallest seam (an interface or factory) as a D item; never fake the result.

In-process WPF harness skeleton (C#):

```csharp
[STAThread] static int Main(string[] args) {
    var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
    app.Resources.MergedDictionaries.Add((ResourceDictionary)Application.LoadComponent(
        new Uri("/MyApp;component/Themes/Styles.xaml", UriKind.Relative)));   // app resources, no App.OnStartup
    var view = new OrdersView { DataContext = new OrdersViewModel(new FakeOrderStore()) };
    var win = new Window { Content = view, Width = 1280, Height = 800,
                           ShowActivated = false, ShowInTaskbar = false, Left = -10000 };
    win.Show(); Pump();
    Find<Button>(view, "SortButton").Command.Execute(null); Pump();   // the user's path
    Check("first row after sort", "A-001", Find<DataGrid>(view, "Grid").Items[0].ToString());
    Save(view, Path.Combine(outDir, "Q1-sorted.png"));                 // RenderTargetBitmap -> PNG
    return failures == 0 ? 0 : 1;
}
static void Pump() => Dispatcher.CurrentDispatcher.Invoke(DispatcherPriority.ApplicationIdle, new Action(() => { }));
```

## 3. Evidence rules (QA tester; the reviewer enforces them)

- A UI proof shows the command line, its real output and exit code, and the screenshot path. The
  screenshot must come from that run of the current build.
- Never present a simulated state as proof: a screenshot made by changing properties in memory to
  look like the fixed behavior, an image from an earlier build, or an edited image. The reviewer
  fails QA with `CAUSE: QA` for any of these.
- An in-process render proves layout, bindings and commands, not real mouse/keyboard input, focus,
  DPI scaling or OS window composition. When a Q item depends on those, drive the real process with
  UI Automation, or send that item (only that one) to the manual checklist.

## 4. Manual checklist (last resort)

`evidence/qa/manual-checklist.md`, one section per item that still needs a human:

```markdown
### Q4 Drag a row to another group
- automation tried: in-process harness - DataGrid drag-drop has no command path; FlaUI - drag pattern not supported by the grid
1. Open Orders, drag row A-001 onto the "Done" group.
2. Expected: the row moves and the count of "Done" goes up by one.
```

`ff.ps1 manual-check` (and the QA gate) fails the checklist if a `### Q<n>` section has no non-empty
`- automation tried:` line or names a Q item that is not in `02-todo.md`.
