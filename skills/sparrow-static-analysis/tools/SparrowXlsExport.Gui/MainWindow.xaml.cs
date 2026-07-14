using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;

namespace SparrowXlsExport.Gui
{
    /// <summary>
    /// Simple launcher for the SparrowXlsExport console tool. The GUI only shells out to the
    /// existing net8.0 exe (zero changes to the console project); it builds the argument list
    /// from the form fields, runs the exe asynchronously, streams stdout/stderr into the log,
    /// and — on success — parses the "output dir:" summary line to enable "출력 폴더 열기".
    /// </summary>
    public partial class MainWindow : Window
    {
        private const string ExeName = "SparrowXlsExport.exe";

        // Remembered for the session if the user browses for the exe manually.
        private string? _userChosenExePath;

        // Resolved after a successful run so "출력 폴더 열기" knows where to point Explorer.
        private string? _lastOutputDir;

        public MainWindow()
        {
            InitializeComponent();
        }

        // ---- File / folder pickers ---------------------------------------------------------

        private void BrowseInputButton_Click(object sender, RoutedEventArgs e)
        {
            var dlg = new OpenFileDialog
            {
                Title = "Sparrow 결과 파일 선택",
                Filter = "Sparrow 결과 (*.xls;*.xlsx)|*.xls;*.xlsx|모든 파일 (*.*)|*.*",
                CheckFileExists = true
            };
            if (dlg.ShowDialog(this) == true)
            {
                InputPathBox.Text = dlg.FileName;
            }
        }

        private void BrowseOutputButton_Click(object sender, RoutedEventArgs e)
        {
            var dlg = new OpenFolderDialog
            {
                Title = "출력 폴더 선택"
            };
            if (!string.IsNullOrWhiteSpace(OutputPathBox.Text) && Directory.Exists(OutputPathBox.Text))
            {
                dlg.InitialDirectory = OutputPathBox.Text;
            }
            if (dlg.ShowDialog(this) == true)
            {
                OutputPathBox.Text = dlg.FolderName;
            }
        }

        // ---- Run -----------------------------------------------------------------------------

        private async void RunButton_Click(object sender, RoutedEventArgs e)
        {
            string input = InputPathBox.Text.Trim();
            if (string.IsNullOrEmpty(input) || !File.Exists(input))
            {
                MessageBox.Show(this, "결과 XLS 파일을 먼저 선택하세요.", "입력 확인",
                    MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            string? exePath = LocateExe();
            if (exePath == null)
            {
                var result = MessageBox.Show(this,
                    "SparrowXlsExport.exe 를 찾을 수 없습니다.\n직접 선택하시겠습니까?",
                    "실행 파일 없음", MessageBoxButton.YesNo, MessageBoxImage.Question);
                if (result != MessageBoxResult.Yes) return;

                var dlg = new OpenFileDialog
                {
                    Title = "SparrowXlsExport.exe 선택",
                    Filter = "SparrowXlsExport.exe|SparrowXlsExport.exe|실행 파일 (*.exe)|*.exe",
                    CheckFileExists = true
                };
                if (dlg.ShowDialog(this) != true) return;
                _userChosenExePath = dlg.FileName;
                exePath = _userChosenExePath;
            }

            List<string> args = BuildArgs(input);

            SetRunning(true);
            _lastOutputDir = null;
            OpenOutputButton.IsEnabled = false;
            LogBox.Clear();
            AppendLog("실행 파일: " + exePath);
            AppendLog("인자: " + string.Join(" ", args));
            AppendLog(new string('-', 60));

            int exitCode;
            string capturedStdout;
            try
            {
                (exitCode, capturedStdout) = await RunProcessAsync(exePath, args);
            }
            catch (Exception ex)
            {
                SetRunning(false);
                AppendLog("예외: " + ex.Message);
                StatusText.Text = "실행 실패";
                MessageBox.Show(this, "실행 중 오류가 발생했습니다.\n\n" + ex.Message,
                    "오류", MessageBoxButton.OK, MessageBoxImage.Error);
                return;
            }

            AppendLog(new string('-', 60));
            AppendLog("종료 코드: " + exitCode);
            SetRunning(false);

            if (exitCode == 0)
            {
                _lastOutputDir = ParseOutputDir(capturedStdout) ?? ComputeDefaultOutputDir(input);
                OpenOutputButton.IsEnabled = _lastOutputDir != null && Directory.Exists(_lastOutputDir);
                StatusText.Text = "완료" + (_lastOutputDir != null ? "  →  " + _lastOutputDir : "");
            }
            else
            {
                StatusText.Text = "실패 (종료 코드 " + exitCode + ")";
                MessageBox.Show(this,
                    "내보내기에 실패했습니다. (종료 코드 " + exitCode + ")\n자세한 내용은 출력 로그를 확인하세요.",
                    "오류", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        private void OpenOutputButton_Click(object sender, RoutedEventArgs e)
        {
            if (string.IsNullOrEmpty(_lastOutputDir) || !Directory.Exists(_lastOutputDir))
            {
                MessageBox.Show(this, "열 수 있는 출력 폴더가 없습니다.", "안내",
                    MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }
            try
            {
                Process.Start(new ProcessStartInfo { FileName = _lastOutputDir, UseShellExecute = true });
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "폴더를 열 수 없습니다.\n\n" + ex.Message, "오류",
                    MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        // ---- Helpers -------------------------------------------------------------------------

        /// <summary>
        /// Locate SparrowXlsExport.exe, first-match wins:
        ///  (a) next to the running GUI exe (AppContext.BaseDirectory);
        ///  (b) dev fallbacks relative to the GUI project output (sibling console bin\Debug|Release);
        ///  (c) the known offline bundle location;
        ///  (d) a path the user picked earlier this session.
        /// </summary>
        private string? LocateExe()
        {
            var candidates = new List<string>();

            if (!string.IsNullOrEmpty(_userChosenExePath))
                candidates.Add(_userChosenExePath!);

            string baseDir = AppContext.BaseDirectory;
            candidates.Add(Path.Combine(baseDir, ExeName));

            // (b) dev fallback: ...\SparrowXlsExport.Gui\bin\Debug\net8.0-windows\  ->  sibling console project
            candidates.Add(Path.GetFullPath(Path.Combine(baseDir,
                "..", "..", "..", "..", "SparrowXlsExport", "bin", "Debug", "net8.0", ExeName)));
            candidates.Add(Path.GetFullPath(Path.Combine(baseDir,
                "..", "..", "..", "..", "SparrowXlsExport", "bin", "Release", "net8.0", ExeName)));

            // (c) offline bundle fallback
            candidates.Add(@"C:\Users\CEO\Desktop\dotnet-gcdump-offline\sparrow-xlsexport\win-x64\" + ExeName);

            foreach (string c in candidates)
            {
                try { if (File.Exists(c)) return c; }
                catch { /* ignore malformed candidate */ }
            }
            return null;
        }

        private List<string> BuildArgs(string input)
        {
            var args = new List<string> { input };

            string outDir = OutputPathBox.Text.Trim();
            if (!string.IsNullOrEmpty(outDir))
            {
                args.Add("--out");
                args.Add(outDir);
            }

            var sevs = new List<string>();
            if (SevVeryHigh.IsChecked == true) sevs.Add("매우위험");
            if (SevHigh.IsChecked == true) sevs.Add("높음");
            if (SevRisk.IsChecked == true) sevs.Add("위험");
            if (SevMedium.IsChecked == true) sevs.Add("보통");
            if (SevLow.IsChecked == true) sevs.Add("낮음");
            if (sevs.Count > 0)
            {
                args.Add("--severity");
                args.Add(string.Join(",", sevs));
            }

            string checker = CheckerBox.Text.Trim();
            if (!string.IsNullOrEmpty(checker))
            {
                args.Add("--checker");
                args.Add(checker);
            }

            string max = MaxBox.Text.Trim();
            if (!string.IsNullOrEmpty(max))
            {
                args.Add("--max");
                args.Add(max);
            }

            return args;
        }

        /// <summary>Run the exe async; stream stdout/stderr into the log; return (exitCode, full stdout).</summary>
        private async Task<(int ExitCode, string Stdout)> RunProcessAsync(string exePath, List<string> args)
        {
            var psi = new ProcessStartInfo
            {
                FileName = exePath,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = new UTF8Encoding(false),
                StandardErrorEncoding = new UTF8Encoding(false),
                WorkingDirectory = Path.GetDirectoryName(exePath) ?? Environment.CurrentDirectory
            };
            foreach (string a in args) psi.ArgumentList.Add(a);

            var stdoutBuilder = new StringBuilder();

            using var process = new Process { StartInfo = psi, EnableRaisingEvents = true };

            process.OutputDataReceived += (s, ev) =>
            {
                if (ev.Data == null) return;
                stdoutBuilder.AppendLine(ev.Data);
                string line = ev.Data;
                Dispatcher.Invoke(() => AppendLog(line));
            };
            process.ErrorDataReceived += (s, ev) =>
            {
                if (ev.Data == null) return;
                string line = ev.Data;
                Dispatcher.Invoke(() => AppendLog(line));
            };

            process.Start();
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();

            await process.WaitForExitAsync();

            return (process.ExitCode, stdoutBuilder.ToString());
        }

        /// <summary>Parse the console summary line: "output dir:&lt;spaces&gt;C:\...\foo.items".</summary>
        private static string? ParseOutputDir(string stdout)
        {
            using var reader = new StringReader(stdout);
            string? line;
            while ((line = reader.ReadLine()) != null)
            {
                const string prefix = "output dir:";
                int idx = line.IndexOf(prefix, StringComparison.Ordinal);
                if (idx >= 0)
                {
                    string dir = line.Substring(idx + prefix.Length).Trim();
                    if (dir.Length > 0) return dir;
                }
            }
            return null;
        }

        /// <summary>Fallback when the summary line is missing: &lt;xls dir&gt;\&lt;name&gt;.items.</summary>
        private static string? ComputeDefaultOutputDir(string input)
        {
            try
            {
                string full = Path.GetFullPath(input);
                string? dir = Path.GetDirectoryName(full);
                if (dir == null) return null;
                return Path.Combine(dir, Path.GetFileNameWithoutExtension(full) + ".items");
            }
            catch
            {
                return null;
            }
        }

        private void AppendLog(string line)
        {
            LogBox.AppendText(line + Environment.NewLine);
            LogBox.ScrollToEnd();
        }

        private void SetRunning(bool running)
        {
            RunButton.IsEnabled = !running;
            BrowseInputButton.IsEnabled = !running;
            BrowseOutputButton.IsEnabled = !running;
            RunButton.Content = running ? "실행 중…" : "확인";
            if (running) StatusText.Text = "실행 중…";
        }
    }
}
