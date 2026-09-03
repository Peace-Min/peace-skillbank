## UI mapping: WinForms -> plain Win32 (chosen by the human; copied to port-work\mapping-extra.md)

The Designer file (`InitializeComponent`) becomes the window-creation code; the form class becomes a
window class with a static `WndProc` that dispatches to member functions. Layout coordinates and
sizes from the Designer are kept as pixels. Every control is a child `HWND` created with
`CreateWindowExW`; the control identifier is a per-form `enum class Id : int` (start at 1000).

| C# (WinForms) | C++ (Win32) |
|---|---|
| `class MainForm : Form` | `class MainForm` holding `HWND hwnd_` + `HINSTANCE`; `static LRESULT CALLBACK WndProc(HWND, UINT, WPARAM, LPARAM)` forwards to `LRESULT HandleMessage(UINT, WPARAM, LPARAM)` via `GWLP_USERDATA` |
| `InitializeComponent()` | `void CreateControls()` called from `WM_CREATE`; one `CreateWindowExW` per control, in Designer order |
| `Application.Run(new MainForm())` | `RegisterClassExW` + `CreateWindowExW` + `ShowWindow` + message loop (`GetMessageW` / `TranslateMessage` / `DispatchMessageW`) |
| `Button` | `CreateWindowExW(0, L"BUTTON", text, WS_CHILD \| WS_VISIBLE \| BS_PUSHBUTTON, x, y, w, h, hwnd_, (HMENU)Id::Xxx, ...)` |
| `Label` | `L"STATIC"` with `SS_LEFT` |
| `TextBox` | `L"EDIT"` with `WS_BORDER \| ES_AUTOHSCROLL` (`ES_MULTILINE \| ES_AUTOVSCROLL` when `Multiline`); read with `GetWindowTextLengthW` + `GetWindowTextW` into `std::wstring` |
| `CheckBox` / `RadioButton` | `L"BUTTON"` with `BS_AUTOCHECKBOX` / `BS_AUTORADIOBUTTON`; state via `BM_GETCHECK` == `BST_CHECKED` |
| `ComboBox` | `L"COMBOBOX"` with `CBS_DROPDOWNLIST`; items via `CB_ADDSTRING`, selection via `CB_GETCURSEL` |
| `ListBox` | `L"LISTBOX"` with `LBS_NOTIFY`; `LB_ADDSTRING` / `LB_GETCURSEL` |
| `ListView` (details) | `WC_LISTVIEWW` (`<commctrl.h>`, `InitCommonControlsEx`), `LVS_REPORT`; columns `LVM_INSERTCOLUMNW`, rows `LVM_INSERTITEMW` + `LVM_SETITEMTEXTW` |
| `DataGridView` | `WC_LISTVIEWW` in report mode with `// TODO(port): DataGridView editing` |
| `MenuStrip` / `ToolStripMenuItem` | `CreateMenu` / `AppendMenuW` with `Id::` values; handled in `WM_COMMAND` |
| `StatusStrip` | `STATUSCLASSNAMEW` + `SB_SETTEXTW` |
| `Timer` (`System.Windows.Forms.Timer`) | `SetTimer(hwnd_, id, intervalMs, nullptr)` + `WM_TIMER` case; `KillTimer` in the destructor |
| `button.Click += Handler` | `case WM_COMMAND: if (LOWORD(wParam) == (int)Id::Button && HIWORD(wParam) == BN_CLICKED) OnButtonClick();` |
| `textBox.TextChanged` | `WM_COMMAND` with `HIWORD(wParam) == EN_CHANGE` |
| `Form.Load` | `WM_CREATE` (after `CreateControls`) |
| `Form.FormClosing` / `FormClosed` | `WM_CLOSE` (return without `DestroyWindow` to cancel) / `WM_DESTROY` (+ `PostQuitMessage(0)` for the main form) |
| `Form.Resize` | `WM_SIZE`; reposition children with `MoveWindow` |
| `control.Text = s` / `control.Text` | `SetWindowTextW(h, s.c_str())` / `GetWindowTextW` |
| `control.Enabled = b` / `Visible = b` | `EnableWindow(h, b)` / `ShowWindow(h, b ? SW_SHOW : SW_HIDE)` |
| `MessageBox.Show(text, caption, buttons)` | `MessageBoxW(hwnd_, text.c_str(), caption.c_str(), MB_OK / MB_YESNO / MB_ICONERROR)`; `DialogResult.Yes` -> `IDYES` |
| `OpenFileDialog` / `SaveFileDialog` | `GetOpenFileNameW` / `GetSaveFileNameW` (`<commdlg.h>`) with a `wchar_t` buffer |
| `new SubForm().ShowDialog()` | modal loop: `EnableWindow(parent, FALSE)`, create the window, run a nested message loop until it closes, `EnableWindow(parent, TRUE)`; or `DialogBoxParamW` with a resource-free `WS_POPUP` window and `// TODO(port): modal` |
| `this.Invoke(...)` / `BeginInvoke` | `SendMessageW` / `PostMessageW` with a custom `WM_APP + n` message; no threads are introduced |
| `Control.Font` / colours | keep defaults; `// TODO(port): font/colour` |
| `Anchor` / `Dock` | fixed positions; `// TODO(port): layout` |
| Resources (`Resources.Designer.cs`) | string literals inline; images `// TODO(port): resource <name>` |

Rules: one window class per form; `Id` enum lives in the form's header; no global HWNDs; all text
through `std::wstring` and the `W` API family; the message loop lives only in the unit holding `Main`.
