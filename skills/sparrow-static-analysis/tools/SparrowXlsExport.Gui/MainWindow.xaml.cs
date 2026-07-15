using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;
using Microsoft.Win32;
using SparrowXlsExport.Core;

namespace SparrowXlsExport.Gui
{
    /// <summary>
    /// One-click GUI for the Sparrow XLS Track C prep. On 확인 it runs the WHOLE pipeline in-process on a
    /// background thread: <see cref="SparrowExporter.Run"/> (parse -&gt; items/index.csv/checkers.md) then
    /// <see cref="TriagePreparer.Prepare"/> (index.csv + guides + prompt -&gt; requests/ + worklist.csv +
    /// unresolved.csv + empty verdicts/). Both human summaries stream into the log box. No dependency on any
    /// external exe or script — parsing and prepare both live in the shared Core library.
    /// </summary>
    public partial class MainWindow : Window
    {
        // Resolved after a successful run so "출력 폴더 열기" knows where to point Explorer.
        private string? _lastOutputDir;

        public MainWindow()
        {
            InitializeComponent();
            // Pre-fill the references path with the auto-resolved skill references folder (if found).
            string? refs = ResolveReferencesRoot();
            if (refs != null) ReferencesPathBox.Text = refs;
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

        private void BrowseReferencesButton_Click(object sender, RoutedEventArgs e)
        {
            var dlg = new OpenFolderDialog
            {
                Title = "스킬 references 폴더 선택 (checkers + triage/triage-prompt.md 포함)"
            };
            if (!string.IsNullOrWhiteSpace(ReferencesPathBox.Text) && Directory.Exists(ReferencesPathBox.Text))
            {
                dlg.InitialDirectory = ReferencesPathBox.Text;
            }
            if (dlg.ShowDialog(this) == true)
            {
                ReferencesPathBox.Text = dlg.FolderName;
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

            // Resolve references (guides + prompt) up-front so we fail fast with a Korean hint.
            string referencesRoot = ReferencesPathBox.Text.Trim();
            if (string.IsNullOrEmpty(referencesRoot))
            {
                referencesRoot = ResolveReferencesRoot() ?? "";
            }
            if (string.IsNullOrEmpty(referencesRoot) || !Directory.Exists(referencesRoot))
            {
                MessageBox.Show(this,
                    "스킬 references 폴더를 찾을 수 없습니다.\n\n고급 옵션의 '스킬 references 경로'에 checkers 가이드와 " +
                    "triage/triage-prompt.md 가 들어 있는 references 폴더를 지정하세요.",
                    "references 경로 확인", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }
            string guidesDir = Path.Combine(referencesRoot, "checkers");
            string promptPath = Path.Combine(referencesRoot, "triage", "triage-prompt.md");
            if (!Directory.Exists(guidesDir) || !File.Exists(promptPath))
            {
                MessageBox.Show(this,
                    "references 경로가 올바르지 않습니다.\n\n다음이 모두 있어야 합니다:\n  - " + guidesDir +
                    "\n  - " + promptPath +
                    "\n\n스킬의 references 폴더(checkers, triage/triage-prompt.md 포함)를 지정하세요.",
                    "references 경로 확인", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            ExportOptions opts = BuildOptions(input);

            SetRunning(true);
            _lastOutputDir = null;
            OpenOutputButton.IsEnabled = false;
            LogBox.Clear();
            AppendLog("입력 파일: " + input);
            AppendLog("references: " + referencesRoot);
            AppendLog(new string('-', 60));

            var log = new DispatcherTextWriter(Dispatcher, AppendLog);

            string outputDir;
            try
            {
                outputDir = await Task.Run(() =>
                {
                    // Stage 1: parse the xls into items/ + index.csv + checkers.md.
                    log.WriteLine("[1/2] 파싱 (parse) …");
                    ExportResult parse = SparrowExporter.Run(opts, log);

                    // Stage 2: assemble LLM-ready triage requests from the parsed index + guides + prompt.
                    log.WriteLine("");
                    log.WriteLine(new string('-', 60));
                    log.WriteLine("[2/2] 트리아지 요청 조립 (prepare) …");
                    var prepOpts = new PrepareOptions
                    {
                        IndexCsvPath = Path.Combine(parse.OutputDir, "index.csv"),
                        ItemsDir = Path.Combine(parse.OutputDir, "items"),
                        GuidesDir = guidesDir,
                        PromptPath = promptPath,
                        ConventionsPath = Path.Combine(referencesRoot, "project-conventions.md"),
                        TemplatePath = Path.Combine(referencesRoot, "triage", "folder-instruction-template.md"),
                        OutDir = parse.OutputDir,
                    };
                    TriagePreparer.Prepare(prepOpts, log);
                    return parse.OutputDir;
                });
            }
            catch (Exception ex)
            {
                SetRunning(false);
                AppendLog(new string('-', 60));
                AppendLog("오류: " + ex.Message);
                StatusText.Text = "실행 실패";
                MessageBox.Show(this, "처리에 실패했습니다.\n\n" + ex.Message,
                    "오류", MessageBoxButton.OK, MessageBoxImage.Error);
                return;
            }

            AppendLog(new string('-', 60));
            AppendLog("완료 — items · index.csv · checkers.md · requests · worklist.csv · unresolved.csv · verdicts");
            SetRunning(false);

            _lastOutputDir = outputDir;
            OpenOutputButton.IsEnabled = !string.IsNullOrEmpty(_lastOutputDir) && Directory.Exists(_lastOutputDir);
            StatusText.Text = "완료" + (!string.IsNullOrEmpty(_lastOutputDir) ? "  →  " + _lastOutputDir : "");
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

        /// <summary>Build the export options from the form fields.</summary>
        private ExportOptions BuildOptions(string input)
        {
            var opts = new ExportOptions { InputPath = input };

            string outDir = OutputPathBox.Text.Trim();
            if (!string.IsNullOrEmpty(outDir)) opts.OutDir = outDir;

            var sevs = new HashSet<string>(StringComparer.Ordinal);
            if (SevVeryHigh.IsChecked == true) sevs.Add("매우위험");
            if (SevHigh.IsChecked == true) sevs.Add("높음");
            if (SevRisk.IsChecked == true) sevs.Add("위험");
            if (SevMedium.IsChecked == true) sevs.Add("보통");
            if (SevLow.IsChecked == true) sevs.Add("낮음");
            opts.Severities = sevs;

            string checker = CheckerBox.Text.Trim();
            if (!string.IsNullOrEmpty(checker)) opts.Checker = checker;

            string max = MaxBox.Text.Trim();
            if (!string.IsNullOrEmpty(max) && int.TryParse(max, out int mv)) opts.Max = mv;

            return opts;
        }

        /// <summary>
        /// Walk up from the app base dir looking for a skill root that contains
        /// references\triage\triage-prompt.md; return that references folder, or null if not found.
        /// </summary>
        private static string? ResolveReferencesRoot()
        {
            try
            {
                var dir = new DirectoryInfo(AppContext.BaseDirectory);
                for (int depth = 0; dir != null && depth < 12; depth++, dir = dir.Parent)
                {
                    string candidate = Path.Combine(dir.FullName, "references");
                    string prompt = Path.Combine(candidate, "triage", "triage-prompt.md");
                    if (File.Exists(prompt)) return candidate;
                }
            }
            catch { /* best-effort resolution; fall through to null */ }
            return null;
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
            BrowseReferencesButton.IsEnabled = !running;
            RunButton.Content = running ? "실행 중…" : "확인";
            if (running) StatusText.Text = "실행 중…";
        }

        /// <summary>
        /// TextWriter that marshals each summary line from the background export thread onto the UI thread
        /// via the Dispatcher, so the log box updates live while the pipeline runs.
        /// </summary>
        private sealed class DispatcherTextWriter : TextWriter
        {
            private readonly Dispatcher _dispatcher;
            private readonly Action<string> _append;

            public DispatcherTextWriter(Dispatcher dispatcher, Action<string> append)
            {
                _dispatcher = dispatcher;
                _append = append;
            }

            public override Encoding Encoding => new UTF8Encoding(false);

            public override void WriteLine(string? value)
            {
                string line = value ?? "";
                _dispatcher.BeginInvoke(new Action(() => _append(line)));
            }
        }
    }
}
