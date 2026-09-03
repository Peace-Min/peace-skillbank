## UI mapping: WinForms -> MFC (chosen by the human; copied to port-work\mapping-extra.md)

Requires the MFC component of the C++ workload (MinGW cannot build MFC). Each form becomes a
`CDialogEx` created without a resource script: controls are created in `OnInitDialog` with explicit
rectangles taken from the Designer file. `PortSupport.h` is still used for strings/numbers; `CString`
converts through `std::wstring(cstr.GetString())` / `CString(ws.c_str())` at the boundary only.

| C# (WinForms) | C++ (MFC) |
|---|---|
| `class MainForm : Form` | `class MainForm : public CDialogEx` with `DECLARE_MESSAGE_MAP()`; `BOOL OnInitDialog() override` |
| `InitializeComponent()` | body of `OnInitDialog`: `control_.Create(...)` per control with `CRect` from the Designer |
| `Application.Run(new MainForm())` | `CWinApp::InitInstance` sets `m_pMainWnd` and calls `DoModal()` |
| `Button` / `Label` / `TextBox` / `CheckBox` / `RadioButton` | `CButton` / `CStatic` / `CEdit` / `CButton (BS_AUTOCHECKBOX)` / `CButton (BS_AUTORADIOBUTTON)` members |
| `ComboBox` / `ListBox` / `ListView` / `DataGridView` | `CComboBox` / `CListBox` / `CListCtrl (LVS_REPORT)` / `CListCtrl` + `// TODO(port): DataGridView editing` |
| `MenuStrip` | `CMenu` built in code (`CreateMenu`, `AppendMenuW`), `SetMenu` |
| `Timer` | `SetTimer(id, ms, nullptr)` + `ON_WM_TIMER()` / `OnTimer(UINT_PTR)` |
| `button.Click += Handler` | `ON_BN_CLICKED(Id::Button, &MainForm::OnButtonClick)` in the message map |
| `textBox.TextChanged` | `ON_EN_CHANGE(Id::TextBox, ...)` |
| `Form.Load` / `FormClosing` / `Resize` | `OnInitDialog` / `OnClose` (`ON_WM_CLOSE`) / `OnSize` (`ON_WM_SIZE`) |
| `control.Text` | `SetWindowTextW` / `GetWindowTextW` (through `CString`) |
| `MessageBox.Show(...)` | `AfxMessageBox(text.c_str(), MB_OK / MB_YESNO)` |
| `OpenFileDialog` / `SaveFileDialog` | `CFileDialog(TRUE / FALSE, ...)`; `DoModal() == IDOK`, `GetPathName()` |
| `new SubForm().ShowDialog()` | `SubForm dlg; dlg.DoModal();` |
| `this.Invoke(...)` | `PostMessageW(WM_APP + n)` handled with `ON_MESSAGE` |
| Resources | string literals inline; images `// TODO(port): resource <name>` |

Rules: control identifiers in a per-form `enum class Id : int` (start at 1000); no resource files;
`#include "PortSupport.h"` after the MFC headers (it defines `WIN32_LEAN_AND_MEAN`, which MFC must not
see first: include `<afxwin.h>` before it).
