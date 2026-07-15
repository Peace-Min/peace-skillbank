using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;

namespace SparrowRunner.Gui
{
    /// <summary>
    /// WPF wrapper for Track A/B PowerShell runners. The GUI only collects paths/options and streams process output;
    /// all rewrite, commit, and git-hardening behavior stays in the existing CLI scripts.
    /// </summary>
    public partial class MainWindow : Window
    {
        private readonly string _skillRoot;
        private readonly string _referencesDir;
        private readonly string _toolsDir;
        private CancellationTokenSource? _cts;
        private Process? _currentProcess;

        public MainWindow()
        {
            InitializeComponent();

            _skillRoot = ResolveSkillRoot();
            _referencesDir = Path.Combine(_skillRoot, "references");
            _toolsDir = Path.Combine(_skillRoot, "tools");
            AppendLog("skill root: " + _skillRoot);
        }

        private void BrowseFileButton_Click(object sender, RoutedEventArgs e)
        {
            var dlg = new OpenFileDialog
            {
                Title = "솔루션 또는 프로젝트 선택",
                Filter = "Solution/Project (*.sln;*.csproj)|*.sln;*.csproj|모든 파일 (*.*)|*.*",
                CheckFileExists = true
            };
            if (dlg.ShowDialog(this) == true)
            {
                TargetPathBox.Text = dlg.FileName;
            }
        }

        private void BrowseFolderButton_Click(object sender, RoutedEventArgs e)
        {
            var dlg = new OpenFolderDialog
            {
                Title = "소스 폴더 선택"
            };
            string current = TargetPathBox.Text.Trim();
            if (Directory.Exists(current)) dlg.InitialDirectory = current;
            if (dlg.ShowDialog(this) == true)
            {
                TargetPathBox.Text = dlg.FolderName;
            }
        }

        private async void RunButton_Click(object sender, RoutedEventArgs e)
        {
            string target = TargetPathBox.Text.Trim().Trim('"');
            if (string.IsNullOrEmpty(target) || (!File.Exists(target) && !Directory.Exists(target)))
            {
                MessageBox.Show(this, "대상 .sln/.csproj 또는 소스 폴더를 먼저 선택하세요.", "입력 확인",
                    MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            var jobs = BuildJobs(target);
            if (jobs.Count == 0)
            {
                MessageBox.Show(this, "실행할 Track 또는 규칙을 하나 이상 선택하세요.", "규칙 확인",
                    MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            _cts = new CancellationTokenSource();
            SetRunning(true);
            AppendLog("");
            AppendLog("target: " + target);
            AppendLog("jobs: " + jobs.Count);
            AppendLog(new string('-', 72));

            try
            {
                foreach (RunnerJob job in jobs)
                {
                    _cts.Token.ThrowIfCancellationRequested();
                    await RunJobAsync(job, _cts.Token);
                }

                StatusText.Text = "완료";
                AppendLog(new string('-', 72));
                AppendLog("완료");
            }
            catch (OperationCanceledException)
            {
                StatusText.Text = "중지됨";
                AppendLog(new string('-', 72));
                AppendLog("사용자 중지");
            }
            catch (Exception ex)
            {
                StatusText.Text = "실패";
                AppendLog(new string('-', 72));
                AppendLog("오류: " + ex.Message);
                MessageBox.Show(this, ex.Message, "실행 실패", MessageBoxButton.OK, MessageBoxImage.Error);
            }
            finally
            {
                _currentProcess = null;
                _cts.Dispose();
                _cts = null;
                SetRunning(false);
            }
        }

        private void StopButton_Click(object sender, RoutedEventArgs e)
        {
            _cts?.Cancel();
            try
            {
                if (_currentProcess != null && !_currentProcess.HasExited)
                {
                    _currentProcess.Kill(entireProcessTree: true);
                }
            }
            catch (Exception ex)
            {
                AppendLog("중지 실패: " + ex.Message);
            }
        }

        private void OpenTargetButton_Click(object sender, RoutedEventArgs e)
        {
            string target = TargetPathBox.Text.Trim().Trim('"');
            string? dir = null;
            if (Directory.Exists(target)) dir = target;
            else if (File.Exists(target)) dir = Path.GetDirectoryName(target);

            if (string.IsNullOrEmpty(dir) || !Directory.Exists(dir))
            {
                MessageBox.Show(this, "열 수 있는 대상 폴더가 없습니다.", "안내",
                    MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            Process.Start(new ProcessStartInfo { FileName = dir, UseShellExecute = true });
        }

        private void ClearLogButton_Click(object sender, RoutedEventArgs e)
        {
            LogBox.Clear();
        }

        private void DryRunCheck_Changed(object sender, RoutedEventArgs e)
        {
            bool dryRun = DryRunCheck.IsChecked == true;
            CommitCheck.IsEnabled = !dryRun;
            if (dryRun) CommitCheck.IsChecked = false;
        }

        private List<RunnerJob> BuildJobs(string target)
        {
            var jobs = new List<RunnerJob>();
            string logDir = ResolveTargetRoot(target);
            Directory.CreateDirectory(logDir);

            if (RunTrackAFormatCheck.IsChecked == true)
            {
                var rules = CollectRules(
                    (A1Var, "var"),
                    (A1Parens, "parens"),
                    (A1Initializer, "initializer"));
                if (rules.Count > 0)
                {
                    jobs.Add(new RunnerJob(
                        "Track A 1차 dotnet format",
                        Path.Combine(_referencesDir, "Run-TrackA.ps1"),
                        rules,
                        logDir,
                        includeGenerated: false));
                }
            }

            if (RunTrackASyntaxCheck.IsChecked == true)
            {
                var rules = CollectRules(
                    (ASObjectVarSafe, "objectvar-safe"),
                    (ASObviousVar, "obviousvar"),
                    (ASArrayVarSafe, "arrayvar-safe"),
                    (ASParens, "parens"),
                    (ASForeachCast, "foreachcast"),
                    (ASObjectInitializer, "objectinitializer"),
                    (ASNullVar, "nullvar"),
                    (ASObjectVarNarrowing, "objectvar-narrowing"),
                    (ASLocalConst, "localconst"),
                    (ASArrayVarNarrowing, "arrayvar-narrowing"),
                    (ASForVar, "forvar"),
                    (ASFieldSplit, "fieldsplit"),
                    (ASEmptyStmt, "emptystmt"),
                    (ASForHoist, "forhoist"));
                if (rules.Count > 0)
                {
                    jobs.Add(new RunnerJob(
                        "Track A 2차 Roslyn",
                        Path.Combine(_toolsDir, "SparrowSyntaxFix", "Run-SparrowSyntaxFix.ps1"),
                        rules,
                        logDir,
                        includeGenerated: false));
                }
            }

            if (RunTrackBCheck.IsChecked == true)
            {
                var rules = CollectRules(
                    (BTrailing, "trailing"),
                    (BSpace, "space"),
                    (BPeriod, "period"),
                    (BCapitalize, "capitalize"),
                    (BFlatten, "flatten"),
                    (BMemberBlank, "memberblank"),
                    (BOneDeclaration, "onedeclaration"),
                    (BOneStatement, "onestatement"),
                    (BContinuation, "continuation"),
                    (BLinqAlign, "linqalign"),
                    (BBlockPromote, "blockpromote"));
                if (rules.Count > 0)
                {
                    jobs.Add(new RunnerJob(
                        "Track B 주석/레이아웃",
                        Path.Combine(_toolsDir, "SparrowCommentFix", "Run-SparrowCommentFix.ps1"),
                        rules,
                        logDir,
                        includeGenerated: IncludeGeneratedCheck.IsChecked == true));
                }
            }

            foreach (RunnerJob job in jobs)
            {
                job.Arguments.Add("-Solution");
                job.Arguments.Add(target);
                job.Arguments.Add("-Rules");
                job.Arguments.Add(string.Join(",", job.Rules));
                job.Arguments.Add("-LogDir");
                job.Arguments.Add(job.LogDir);

                if (DryRunCheck.IsChecked == true) job.Arguments.Add("-DryRun");
                else if (CommitCheck.IsChecked == true) job.Arguments.Add("-Commit");
                else job.Arguments.Add("-NoCommit");

                if (job.IncludeGenerated) job.Arguments.Add("-IncludeGenerated");
            }

            return jobs;
        }

        private async Task RunJobAsync(RunnerJob job, CancellationToken cancellationToken)
        {
            if (!File.Exists(job.ScriptPath))
            {
                throw new FileNotFoundException("러너 스크립트를 찾을 수 없습니다.", job.ScriptPath);
            }

            AppendLog("");
            AppendLog(">>> " + job.Name);
            AppendLog("rules: " + string.Join(",", job.Rules));

            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                RedirectStandardInput = false,
                CreateNoWindow = true,
                WorkingDirectory = Path.GetDirectoryName(job.ScriptPath) ?? _skillRoot,
                StandardOutputEncoding = new UTF8Encoding(false),
                StandardErrorEncoding = new UTF8Encoding(false)
            };

            psi.ArgumentList.Add("-NoLogo");
            psi.ArgumentList.Add("-NoProfile");
            psi.ArgumentList.Add("-ExecutionPolicy");
            psi.ArgumentList.Add("Bypass");
            psi.ArgumentList.Add("-File");
            psi.ArgumentList.Add(job.ScriptPath);
            foreach (string arg in job.Arguments)
            {
                psi.ArgumentList.Add(arg);
            }

            using var process = new Process { StartInfo = psi, EnableRaisingEvents = true };
            _currentProcess = process;

            process.OutputDataReceived += (_, e) =>
            {
                if (e.Data != null) Dispatcher.BeginInvoke(new Action(() => AppendLog(e.Data)));
            };
            process.ErrorDataReceived += (_, e) =>
            {
                if (e.Data != null) Dispatcher.BeginInvoke(new Action(() => AppendLog(e.Data)));
            };

            if (!process.Start()) throw new InvalidOperationException("PowerShell 프로세스를 시작하지 못했습니다.");
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();

            await process.WaitForExitAsync(cancellationToken);
            if (process.ExitCode != 0)
            {
                throw new InvalidOperationException(job.Name + " 실패(exit=" + process.ExitCode + ")");
            }
        }

        private static List<string> CollectRules(params (CheckBox CheckBox, string Rule)[] pairs)
        {
            return pairs
                .Where(p => p.CheckBox.IsChecked == true)
                .Select(p => p.Rule)
                .ToList();
        }

        private static string ResolveTargetRoot(string target)
        {
            if (Directory.Exists(target)) return target;
            string? dir = Path.GetDirectoryName(target);
            return string.IsNullOrEmpty(dir) ? Environment.CurrentDirectory : dir;
        }

        private static string ResolveSkillRoot()
        {
            var dir = new DirectoryInfo(AppContext.BaseDirectory);
            for (int i = 0; dir != null && i < 12; i++, dir = dir.Parent)
            {
                string skill = Path.Combine(dir.FullName, "SKILL.md");
                string syntax = Path.Combine(dir.FullName, "tools", "SparrowSyntaxFix", "Run-SparrowSyntaxFix.ps1");
                if (File.Exists(skill) && File.Exists(syntax)) return dir.FullName;
            }

            string fallback = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", ".."));
            if (File.Exists(Path.Combine(fallback, "SKILL.md"))) return fallback;
            throw new DirectoryNotFoundException("sparrow-static-analysis skill root를 찾을 수 없습니다.");
        }

        private void SetRunning(bool running)
        {
            RunButton.IsEnabled = !running;
            StopButton.IsEnabled = running;
            BrowseFileButton.IsEnabled = !running;
            BrowseFolderButton.IsEnabled = !running;
            RulesTabs.IsEnabled = !running;
            TargetPathBox.IsEnabled = !running;
            StatusText.Text = running ? "실행 중..." : "대기 중";
        }

        private void AppendLog(string line)
        {
            LogBox.AppendText(line + Environment.NewLine);
            LogBox.ScrollToEnd();
        }

        private sealed class RunnerJob
        {
            public RunnerJob(string name, string scriptPath, IReadOnlyList<string> rules, string logDir, bool includeGenerated)
            {
                Name = name;
                ScriptPath = scriptPath;
                Rules = rules;
                LogDir = logDir;
                IncludeGenerated = includeGenerated;
            }

            public string Name { get; }
            public string ScriptPath { get; }
            public IReadOnlyList<string> Rules { get; }
            public string LogDir { get; }
            public bool IncludeGenerated { get; }
            public List<string> Arguments { get; } = new List<string>();
        }
    }
}
