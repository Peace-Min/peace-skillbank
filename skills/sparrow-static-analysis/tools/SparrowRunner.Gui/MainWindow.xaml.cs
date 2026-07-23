using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using Microsoft.Win32;
using SparrowXlsExport.Core;

namespace SparrowRunner.Gui
{
    /// <summary>
    /// WPF wrapper for Track A/B PowerShell runners. Rewrite logic stays in the existing CLI scripts.
    /// </summary>
    public partial class MainWindow : Window
    {
        private readonly string _skillRoot;
        private readonly string _toolsDir;
        private readonly Dictionary<string, RuleInfo> _ruleInfos = new Dictionary<string, RuleInfo>(StringComparer.Ordinal);
        private CancellationTokenSource? _cts;
        private CancellationTokenSource? _scopeCts;
        private Process? _currentProcess;
        private string? _lastTrackCOutputDir;
        private RuleManagerWindow? _ruleManager;
        private SourceScope? _currentScope;
        private bool _currentScopeIncludesGenerated;

        public ObservableCollection<SourceScopeNode> ScopeRoots { get; } = new ObservableCollection<SourceScopeNode>();

        public MainWindow()
        {
            InitializeComponent();

            _skillRoot = ResolveSkillRoot();
            _toolsDir = Path.Combine(_skillRoot, "tools");
            TrackCReferencesPathBox.Text = Path.Combine(_skillRoot, "references");
            AppendLog("GUI 준비 완료");
            InitializeRuleInfo();
            ShowRuleInfo(nameof(ASObjectVarSafe));
            Loaded += async (_, _) =>
            {
                UpdateSummary();
                await RefreshScopeAsync(showErrors: false);
            };
        }

        private void RulesTabs_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (!ReferenceEquals(e.OriginalSource, RulesTabs)) return;
            if (RulesTabs.SelectedItem == TrackCTab)
            {
                ShowRuleInfo(nameof(RunTrackCCheck));
            }
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

        private void BrowseTrackCXlsButton_Click(object sender, RoutedEventArgs e)
        {
            var dlg = new OpenFileDialog
            {
                Title = "Sparrow 결과 XLS 선택",
                Filter = "Sparrow 결과 (*.xls;*.xlsx)|*.xls;*.xlsx|모든 파일 (*.*)|*.*",
                CheckFileExists = true
            };
            if (dlg.ShowDialog(this) == true)
            {
                TrackCXlsPathBox.Text = dlg.FileName;
            }
        }

        private void BrowseTrackCOutputButton_Click(object sender, RoutedEventArgs e)
        {
            var dlg = new OpenFolderDialog
            {
                Title = "Track C 출력 폴더 선택"
            };
            string current = TrackCOutputPathBox.Text.Trim();
            if (Directory.Exists(current)) dlg.InitialDirectory = current;
            if (dlg.ShowDialog(this) == true)
            {
                TrackCOutputPathBox.Text = dlg.FolderName;
            }
        }

        private void OpenRuleManagerButton_Click(object sender, RoutedEventArgs e)
        {
            // Guides dir = the same references\checkers Track C prepare uses. Fall back to the skill default
            // when the references box is empty. The store creates the folder on first Add if it is missing.
            string referencesRoot = TrackCReferencesPathBox.Text.Trim().Trim('"');
            if (string.IsNullOrEmpty(referencesRoot))
            {
                referencesRoot = Path.Combine(_skillRoot, "references");
            }
            string guidesDir = Path.Combine(referencesRoot, "checkers");
            string? xls = string.IsNullOrWhiteSpace(TrackCXlsPathBox.Text)
                ? null
                : TrackCXlsPathBox.Text.Trim().Trim('"');

            if (_ruleManager != null)
            {
                // Already open: bring it forward rather than spawning a duplicate.
                _ruleManager.Activate();
                return;
            }

            var window = new RuleManagerWindow(this, guidesDir, xls);
            window.Closed += (_, _) => _ruleManager = null;
            _ruleManager = window;
            window.Show();
        }

        private void BrowseTrackCReferencesButton_Click(object sender, RoutedEventArgs e)
        {
            var dlg = new OpenFolderDialog
            {
                Title = "sparrow-static-analysis references 폴더 선택"
            };
            string current = TrackCReferencesPathBox.Text.Trim();
            if (Directory.Exists(current)) dlg.InitialDirectory = current;
            if (dlg.ShowDialog(this) == true)
            {
                TrackCReferencesPathBox.Text = dlg.FolderName;
            }
        }

        private async void RunButton_Click(object sender, RoutedEventArgs e)
        {
            bool runTrackA = RunTrackASyntaxCheck.IsChecked == true;
            bool runTrackB = RunTrackBCheck.IsChecked == true;
            bool runTrackC = RunTrackCCheck.IsChecked == true;
            if (!runTrackA && !runTrackB && !runTrackC)
            {
                MessageBox.Show(this, "실행할 Track을 하나 이상 선택하세요.", "Track 확인",
                    MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            string target = TargetPathBox.Text.Trim().Trim('"');
            if (string.IsNullOrEmpty(target) || (!File.Exists(target) && !Directory.Exists(target)))
            {
                MessageBox.Show(this, "대상 .sln/.csproj 또는 소스 폴더를 먼저 선택하세요.", "입력 확인",
                    MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            SourceScope scope = await EnsureScopeAsync(target);
            IReadOnlyList<string> selectedFiles = scope.SelectedFiles;
            if (selectedFiles.Count == 0)
            {
                MessageBox.Show(this, "선택된 .cs 파일이 없습니다. 좌측 작업 범위에서 파일을 선택하세요.", "범위 확인",
                    MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            string scopeManifest;
            try
            {
                scopeManifest = ScopeManifestWriter.WriteTemp(selectedFiles);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "범위 manifest 생성 실패: " + ex.Message, "범위 확인",
                    MessageBoxButton.OK, MessageBoxImage.Error);
                return;
            }

            var jobs = BuildJobs(target, scopeManifest);
            if ((runTrackA || runTrackB) && jobs.Count == 0)
            {
                TryDeleteFile(scopeManifest);
                MessageBox.Show(this, "실행할 Track 또는 규칙을 하나 이상 선택하세요.", "규칙 확인",
                    MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            string trackCXls = TrackCXlsPathBox.Text.Trim().Trim('"');
            if (runTrackC && (string.IsNullOrEmpty(trackCXls) || !File.Exists(trackCXls)))
            {
                TryDeleteFile(scopeManifest);
                MessageBox.Show(this, "Track C 결과 XLS 파일을 먼저 선택하세요.", "입력 확인",
                    MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            string referencesRoot = TrackCReferencesPathBox.Text.Trim().Trim('"');
            if (runTrackC && !ValidateTrackCReferences(referencesRoot))
            {
                TryDeleteFile(scopeManifest);
                return;
            }

            _cts = new CancellationTokenSource();
            SetRunning(true);
            _lastTrackCOutputDir = null;
            OpenTrackCOutputButton.IsEnabled = false;
            AppendLog("");
            if (runTrackA || runTrackB) AppendLog("target: " + target);
            AppendLog("scope: " + selectedFiles.Count + " selected / " + scope.TotalFiles + " discovered"
                      + (scope.ExcludedFiles > 0 ? " / " + scope.ExcludedFiles + " excluded" : ""));
            if (runTrackC) AppendLog("track-c xls: " + trackCXls);
            AppendLog("jobs: " + (jobs.Count + (runTrackC ? 1 : 0)));
            AppendLog(new string('-', 72));

            try
            {
                foreach (RunnerJob job in jobs)
                {
                    _cts.Token.ThrowIfCancellationRequested();
                    SummaryModeText.Text = job.Name + " 실행 중";
                    await RunJobAsync(job, _cts.Token);
                }

                if (runTrackC)
                {
                    _cts.Token.ThrowIfCancellationRequested();
                    SummaryModeText.Text = "Track C XLS/LLM 작업 패키지 생성 중";
                    _lastTrackCOutputDir = await RunTrackCAsync(trackCXls, referencesRoot, scope.RootPath, scopeManifest, _cts.Token);
                    OpenTrackCOutputButton.IsEnabled = Directory.Exists(_lastTrackCOutputDir);
                }

                StatusText.Text = "완료";
                SummaryModeText.Text = "실행 완료. 빌드와 Sparrow 재분석으로 결과를 확인하세요.";
                AppendLog(new string('-', 72));
                AppendLog("완료");
            }
            catch (OperationCanceledException)
            {
                StatusText.Text = "중지됨";
                SummaryModeText.Text = "사용자가 실행을 중지했습니다.";
                AppendLog(new string('-', 72));
                AppendLog("사용자 중지");
            }
            catch (Exception ex)
            {
                StatusText.Text = "실패";
                SummaryModeText.Text = "실행 중 오류가 발생했습니다. 로그를 확인하세요.";
                AppendLog(new string('-', 72));
                AppendLog("오류: " + ex.Message);
                MessageBox.Show(this, ex.Message, "실행 실패", MessageBoxButton.OK, MessageBoxImage.Error);
            }
            finally
            {
                _currentProcess = null;
                _cts.Dispose();
                _cts = null;
                TryDeleteFile(scopeManifest);
                SetRunning(false);
                UpdateSummary();
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

        private void OpenTrackCOutputButton_Click(object sender, RoutedEventArgs e)
        {
            if (string.IsNullOrEmpty(_lastTrackCOutputDir) || !Directory.Exists(_lastTrackCOutputDir))
            {
                MessageBox.Show(this, "열 수 있는 Track C 출력 폴더가 없습니다.", "안내",
                    MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            Process.Start(new ProcessStartInfo { FileName = _lastTrackCOutputDir, UseShellExecute = true });
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
            UpdateSummary();
        }

        private void TargetPathBox_TextChanged(object sender, TextChangedEventArgs e)
        {
            UpdateSummary();
            _ = RefreshScopeAsync(showErrors: false);
        }

        private async void RefreshScopeButton_Click(object sender, RoutedEventArgs e)
        {
            await RefreshScopeAsync(showErrors: true);
        }

        private void SelectAllScopeButton_Click(object sender, RoutedEventArgs e)
        {
            foreach (SourceScopeNode root in ScopeRoots) root.SetSubtree(true);
            UpdateSummary();
        }

        private void ClearScopeButton_Click(object sender, RoutedEventArgs e)
        {
            foreach (SourceScopeNode root in ScopeRoots) root.SetSubtree(false);
            UpdateSummary();
        }

        private void ScopeCheckBox_Changed(object sender, RoutedEventArgs e)
        {
            UpdateSummary();
        }

        private async Task RefreshScopeAsync(bool showErrors)
        {
            if (!IsLoaded && !showErrors) return;

            string target = TargetPathBox.Text.Trim().Trim('"');
            if (string.IsNullOrWhiteSpace(target) || (!File.Exists(target) && !Directory.Exists(target)))
            {
                _currentScope = null;
                ScopeRoots.Clear();
                ScopeStatusText.Text = "대상 경로를 선택하세요.";
                UpdateSummary();
                return;
            }

            _scopeCts?.Cancel();
            _scopeCts?.Dispose();
            _scopeCts = new CancellationTokenSource();
            CancellationToken token = _scopeCts.Token;

            try
            {
                ScopeStatusText.Text = "소스 파일을 탐색하는 중...";
                bool includeGenerated = IncludeGeneratedCheck.IsChecked == true;
                SourceScope? previousScope = _currentScope;
                HashSet<string>? previousSelection = null;
                string expectedRoot = ResolveTargetRoot(target);
                if (previousScope != null && SamePath(previousScope.RootPath, expectedRoot))
                {
                    int previousSelectable = previousScope.RootNode.EnumerateFiles()
                        .Distinct(StringComparer.OrdinalIgnoreCase)
                        .Count();
                    IReadOnlyList<string> selected = previousScope.SelectedFiles;
                    if (selected.Count > 0 && selected.Count < previousSelectable)
                    {
                        previousSelection = new HashSet<string>(selected, StringComparer.OrdinalIgnoreCase);
                    }
                }

                SourceScope scope = await SourceScopeDiscovery.DiscoverAsync(target, includeGenerated, token);
                if (token.IsCancellationRequested) return;
                if (previousSelection != null)
                {
                    scope.RootNode.ApplySelection(previousSelection);
                }

                _currentScope = scope;
                _currentScopeIncludesGenerated = includeGenerated;
                ScopeRoots.Clear();
                ScopeRoots.Add(scope.RootNode);
                UpdateSummary();
            }
            catch (OperationCanceledException)
            {
            }
            catch (Exception ex)
            {
                _currentScope = null;
                ScopeRoots.Clear();
                ScopeStatusText.Text = "범위 탐색 실패: " + ex.Message;
                if (showErrors)
                {
                    MessageBox.Show(this, ex.Message, "범위 탐색 실패", MessageBoxButton.OK, MessageBoxImage.Warning);
                }
            }
        }

        private async Task<SourceScope> EnsureScopeAsync(string target)
        {
            string expectedRoot = ResolveTargetRoot(target);
            bool includeGenerated = IncludeGeneratedCheck.IsChecked == true;
            if (_currentScope != null && _currentScopeIncludesGenerated == includeGenerated && SamePath(_currentScope.RootPath, expectedRoot))
            {
                return _currentScope;
            }

            SourceScope scope = await SourceScopeDiscovery.DiscoverAsync(target, includeGenerated, CancellationToken.None);
            _currentScope = scope;
            _currentScopeIncludesGenerated = includeGenerated;
            ScopeRoots.Clear();
            ScopeRoots.Add(scope.RootNode);
            UpdateSummary();
            return scope;
        }

        private static bool SamePath(string left, string right)
        {
            return string.Equals(
                Path.GetFullPath(left).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                Path.GetFullPath(right).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                StringComparison.OrdinalIgnoreCase);
        }

        private List<RunnerJob> BuildJobs(string target, string filesFrom)
        {
            var jobs = new List<RunnerJob>();
            if (RunTrackASyntaxCheck.IsChecked != true && RunTrackBCheck.IsChecked != true)
            {
                return jobs;
            }

            string logDir = ResolveTargetRoot(target);
            Directory.CreateDirectory(logDir);

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
                        "Track A Roslyn",
                        Path.Combine(_toolsDir, "_internal", "SparrowSyntaxFix", "Run-SparrowSyntaxFix.ps1"),
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
                        Path.Combine(_toolsDir, "_internal", "SparrowCommentFix", "Run-SparrowCommentFix.ps1"),
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
                job.Arguments.Add("-FilesFrom");
                job.Arguments.Add(filesFrom);

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

        private async Task<string> RunTrackCAsync(string inputXls, string referencesRoot, string sourceRoot, string filesFrom, CancellationToken cancellationToken)
        {
            string guidesDir = Path.Combine(referencesRoot, "checkers");
            string promptPath = Path.Combine(referencesRoot, "triage", "triage-prompt.md");
            string conventionsPath = Path.Combine(referencesRoot, "project-conventions.md");
            string templatePath = Path.Combine(referencesRoot, "triage", "folder-instruction-template.md");

            string finalOutputRoot = ResolveTrackCOutputRoot(inputXls, TrackCOutputPathBox.Text);
            string tracksValue = BuildTrackCTracksValue();
            string? checkerValue = string.IsNullOrWhiteSpace(TrackCCheckerBox.Text) ? null : TrackCCheckerBox.Text.Trim();
            string? severityValue = BuildTrackCSeverityValue();
            int? maxValue = ParseNullableInt(TrackCMaxBox.Text);
            var log = new DispatcherTextWriter(Dispatcher, AppendLog);

            return await Task.Run(() =>
            {
                string tempRoot = Path.Combine(Path.GetTempPath(), "sparrow-trackc-" + Guid.NewGuid().ToString("N"));
                cancellationToken.ThrowIfCancellationRequested();
                try
                {
                    ExportOptions exportOptions = BuildTrackCExportOptions(inputXls, tempRoot, sourceRoot, filesFrom);

                    log.WriteLine("");
                    log.WriteLine(">>> Track C XLS/LLM requests 생성");
                    log.WriteLine("[1/3] XLS 내부 파싱: GUI 출력에는 중간 산출물을 남기지 않습니다.");
                    ExportResult parse = SparrowExporter.Run(exportOptions, null);

                    // 범위 필터 진단: 선택한 소스가 이 xls의 검출 경로와 하나도 안 맞으면(다른 체크아웃/잘못된 폴더)
                    // 조용한 빈 결과 대신 운영자에게 원인을 로그로 알린다. Tier-2 모호 매칭은 소프트 경고로 남긴다.
                    if (parse.ScopeDiagnostic != null)
                    {
                        log.WriteLine("");
                        log.WriteLine(parse.ScopeDiagnostic);
                    }
                    if (parse.ScopeAmbiguousWarning != null)
                    {
                        log.WriteLine(parse.ScopeAmbiguousWarning);
                    }

                    cancellationToken.ThrowIfCancellationRequested();
                    log.WriteLine("[2/3] LLM 작업 요청 조립: requests만 최종 산출물로 사용합니다.");
                    var prepareOptions = new PrepareOptions
                    {
                        IndexCsvPath = Path.Combine(parse.OutputDir, "index.csv"),
                        ItemsDir = Path.Combine(parse.OutputDir, "items"),
                        GuidesDir = guidesDir,
                        PromptPath = promptPath,
                        ConventionsPath = conventionsPath,
                        TemplatePath = templatePath,
                        OutDir = parse.OutputDir,
                        Checker = checkerValue,
                        Severity = severityValue,
                        Tracks = tracksValue,
                        Max = maxValue
                    };
                    PrepareResult prepare = TriagePreparer.Prepare(prepareOptions, null);

                    cancellationToken.ThrowIfCancellationRequested();
                    log.WriteLine("[3/3] 최종 폴더 정리: requests 폴더만 복사합니다.");
                    string sourceRequestsDir = Path.Combine(parse.OutputDir, "requests");
                    if (!Directory.Exists(sourceRequestsDir))
                    {
                        throw new DirectoryNotFoundException("requests 폴더가 생성되지 않았습니다: " + sourceRequestsDir);
                    }

                    Directory.CreateDirectory(finalOutputRoot);
                    string finalRequestsDir = Path.Combine(finalOutputRoot, "requests");
                    if (Directory.Exists(finalRequestsDir))
                    {
                        Directory.Delete(finalRequestsDir, recursive: true);
                    }

                    CopyDirectory(sourceRequestsDir, finalRequestsDir);
                    log.WriteLine("요청 생성수: " + prepare.RequestCount);
                    log.WriteLine("미해결수    : " + prepare.UnresolvedCount);
                    if (prepare.FallbackCheckers.Count > 0)
                    {
                        // 운영자용 안내: 요청 md에는 룰 등록 경로를 넣지 않는다(작업자가 GUI를 조작할 수 없음).
                        log.WriteLine("미등록 체커 " + prepare.FallbackCheckers.Count
                                      + "종 — GUI '체커 룰 관리'에서 룰 추가 가능: "
                                      + string.Join(", ", prepare.FallbackCheckers));
                    }
                    log.WriteLine("LLM 전달 폴더: " + finalRequestsDir);
                    return finalRequestsDir;
                }
                finally
                {
                    TryDeleteDirectory(tempRoot);
                }
            }, cancellationToken);
        }

        private ExportOptions BuildTrackCExportOptions(string inputXls, string outputDir, string sourceRoot, string filesFrom)
        {
            var severities = new HashSet<string>(StringComparer.Ordinal);
            if (TrackCSevVeryHigh.IsChecked == true) severities.Add("매우위험");
            if (TrackCSevHigh.IsChecked == true) severities.Add("높음");
            if (TrackCSevRisk.IsChecked == true) severities.Add("위험");
            if (TrackCSevMedium.IsChecked == true) severities.Add("보통");
            if (TrackCSevLow.IsChecked == true) severities.Add("낮음");

            var options = new ExportOptions
            {
                InputPath = inputXls,
                OutDir = outputDir,
                RootPath = sourceRoot,
                FilesFrom = filesFrom,
                Severities = severities,
                Max = ParseNullableInt(TrackCMaxBox.Text)
            };

            string checker = TrackCCheckerBox.Text.Trim();
            if (!string.IsNullOrEmpty(checker)) options.Checker = checker;

            return options;
        }

        private static string ResolveTrackCOutputRoot(string inputXls, string configuredOutput)
        {
            string trimmed = configuredOutput.Trim().Trim('"');
            if (!string.IsNullOrEmpty(trimmed))
            {
                return Path.GetFullPath(trimmed);
            }

            string inputFullPath = Path.GetFullPath(inputXls);
            string parent = Path.GetDirectoryName(inputFullPath) ?? Environment.CurrentDirectory;
            string name = Path.GetFileNameWithoutExtension(inputFullPath) + ".requests";
            return Path.Combine(parent, name);
        }

        private static void CopyDirectory(string sourceDir, string destinationDir)
        {
            Directory.CreateDirectory(destinationDir);
            foreach (string file in Directory.GetFiles(sourceDir))
            {
                string destination = Path.Combine(destinationDir, Path.GetFileName(file));
                File.Copy(file, destination, overwrite: true);
            }

            foreach (string directory in Directory.GetDirectories(sourceDir))
            {
                string destination = Path.Combine(destinationDir, Path.GetFileName(directory));
                CopyDirectory(directory, destination);
            }
        }

        private static void TryDeleteDirectory(string path)
        {
            try
            {
                if (Directory.Exists(path))
                {
                    Directory.Delete(path, recursive: true);
                }
            }
            catch
            {
                // Temporary parse output is best-effort cleanup only.
            }
        }

        private static void TryDeleteFile(string? path)
        {
            try
            {
                if (!string.IsNullOrEmpty(path) && File.Exists(path))
                {
                    File.Delete(path);
                }
            }
            catch
            {
                // Temporary scope manifest cleanup is best-effort only.
            }
        }

        private string BuildTrackCTracksValue()
        {
            return "A,B,C";
        }

        private string? BuildTrackCSeverityValue()
        {
            var severities = new List<string>();
            if (TrackCSevVeryHigh.IsChecked == true) severities.Add("매우위험");
            if (TrackCSevHigh.IsChecked == true) severities.Add("높음");
            if (TrackCSevRisk.IsChecked == true) severities.Add("위험");
            if (TrackCSevMedium.IsChecked == true) severities.Add("보통");
            if (TrackCSevLow.IsChecked == true) severities.Add("낮음");
            return severities.Count == 0 ? null : string.Join(",", severities);
        }

        private static int? ParseNullableInt(string value)
        {
            return int.TryParse(value.Trim(), out int parsed) ? parsed : null;
        }

        private bool ValidateTrackCReferences(string referencesRoot)
        {
            if (string.IsNullOrEmpty(referencesRoot) || !Directory.Exists(referencesRoot))
            {
                MessageBox.Show(this, "Track C references 폴더를 찾을 수 없습니다.", "references 확인",
                    MessageBoxButton.OK, MessageBoxImage.Warning);
                return false;
            }

            string guidesDir = Path.Combine(referencesRoot, "checkers");
            string promptPath = Path.Combine(referencesRoot, "triage", "triage-prompt.md");
            string conventionsPath = Path.Combine(referencesRoot, "project-conventions.md");
            string templatePath = Path.Combine(referencesRoot, "triage", "folder-instruction-template.md");
            if (!Directory.Exists(guidesDir) || !File.Exists(promptPath) || !File.Exists(conventionsPath) || !File.Exists(templatePath))
            {
                MessageBox.Show(this,
                    "Track C references 경로가 올바르지 않습니다.\n\n필요 항목:\n- checkers 폴더\n- triage/triage-prompt.md\n- triage/folder-instruction-template.md\n- project-conventions.md",
                    "references 확인", MessageBoxButton.OK, MessageBoxImage.Warning);
                return false;
            }

            return true;
        }

        private void InitializeRuleInfo()
        {
            AddRuleInfo(RunTrackASyntaxCheck, "Track A Roslyn",
                "코드 규칙 자동수정을 실행합니다.",
                "var, object initializer, 배열 초기화, foreach 루프 변수, 괄호, 다중 선언 계열을 처리합니다.",
                "선택된 Track A 규칙만 -Rules로 전달됩니다.");
            AddRuleInfo(ASObjectVarSafe, "객체 생성 명시 타입을 var로 변경",
                "선언 타입과 생성 타입이 같은 지역변수를 var로 바꿉니다.",
                "체커: PRACTICE.OBJECT_INSTANTIATION.NOT_USED_IMPLICIT_TYPING. 정적 타입 축소가 없는 기본 안전 규칙입니다.",
                "Foo item = new Foo();\r\n// ->\r\nvar item = new Foo();");
            AddRuleInfo(ASObviousVar, "명확한 지역변수 타입을 var로 변경",
                "리터럴, 캐스트, 명확한 생성 결과처럼 타입 추론이 분명한 지역변수를 var로 바꿉니다.",
                "체커: PRACTICE.OBVIOUS_VARIABLE_TYPE.NOT_USED_IMPLICIT_TYPING.",
                "string name = \"A\";\r\ndouble ratio = (double)20;\r\n// ->\r\nvar name = \"A\";\r\nvar ratio = (double)20;");
            AddRuleInfo(ASArrayVarSafe, "배열 초기화 문법 간소화",
                "동일 배열 타입의 장황한 초기화 구문만 줄입니다.",
                "체커: PRACTICE.ARRAY_DECLARATION.COMPLICATED_SYNTAX. 선언 타입은 유지합니다.",
                "int[] values = new int[] { 1, 2, 3 };\r\n// ->\r\nint[] values = { 1, 2, 3 };");
            AddRuleInfo(ASParens, "논리식 괄호 명확화",
                "&&와 || 논리식의 모든 피연산자에 괄호를 추가합니다.",
                "체커: MISSING_PARENTHESIS_IN_EXPRESSION. Sparrow 기준상 atom도 감쌉니다.",
                "if (isReady && hasValue || forced)\r\n// ->\r\nif (((isReady) && (hasValue)) || (forced))");
            AddRuleInfo(ASForeachCast, "[검토필요] foreach Cast<T> + var",
                "비제네릭 컬렉션 foreach의 명시 타입을 Cast<T>()와 var 조합으로 바꿉니다.",
                "체커: PRACTICE.LOOP_VARIABLE.NOT_USED_IMPLICIT_TYPING. 검토필요 커밋 대상입니다.",
                "foreach (XmlNode node in nodes)\r\n// ->\r\nforeach (var node in System.Linq.Enumerable.Cast<XmlNode>(nodes))");
            AddRuleInfo(ASObjectInitializer, "연속 대입을 object initializer로 통합",
                "객체 생성 직후 연속된 단순 속성/필드 대입을 initializer로 합칩니다.",
                "체커: PRACTICE.OBJECT_INITIALIZATION.NOT_USED_INITIALIZER. 연속 구간만 처리합니다.",
                "var item = new Foo();\r\nitem.A = 1;\r\nitem.B = text;\r\n// ->\r\nvar item = new Foo { A = 1, B = text };");
            AddRuleInfo(ASNullVar, "[검토필요] typed null var 초기화",
                "초기값이 없거나 null인 명시 지역변수를 typed null var 형태로 바꿉니다.",
                "체커: 명확한 지역변수 var 권장 계열. 검토필요 커밋 대상입니다.",
                "Foo item;\r\n// ->\r\nvar item = (Foo)null;");
            AddRuleInfo(ASObjectVarNarrowing, "[검토필요] 상위 타입 선언을 var로 축소",
                "인터페이스/상위 타입 선언을 실제 생성 타입 var로 바꿉니다.",
                "정적 타입 축소가 발생하므로 검토필요 커밋 대상입니다.",
                "IList<string> names = new List<string>();\r\n// ->\r\nvar names = new List<string>();");
            AddRuleInfo(ASLocalConst, "[검토필요] 지역 const를 var로 변경",
                "지역 const 선언을 일반 var 지역변수로 바꿉니다.",
                "지역 const 의미가 중요한 경우 검토가 필요합니다.",
                "const string Code = \"A\";\r\n// ->\r\nvar Code = \"A\";");
            AddRuleInfo(ASArrayVarNarrowing, "[검토필요] 배열 선언을 var + new[]로 축소",
                "선언 배열 타입을 var와 암시 배열 생성으로 줄입니다.",
                "object[] 등 정적 타입 축소 가능성이 있어 검토필요 커밋 대상입니다.",
                "int[] values = new int[] { 1, 2, 3 };\r\n// ->\r\nvar values = new[] { 1, 2, 3 };");
            AddRuleInfo(ASForVar, "for 루프 초기화 변수를 var로 변경",
                "for 초기화절의 명시 타입을 var로 바꿉니다.",
                "체커: 루프 변수 암시적 타입 사용 권장.",
                "for (int i = 0; i < count; i++)\r\n// ->\r\nfor (var i = 0; i < count; i++)");
            AddRuleInfo(ASFieldSplit, "한 줄 다중 필드 선언 분리",
                "한 줄에 여러 필드를 선언한 구문을 필드별 선언으로 나눕니다.",
                "체커: 한 줄에 하나의 선언문 배치.",
                "private int x, y;\r\n// ->\r\nprivate int x;\r\nprivate int y;");
            AddRuleInfo(ASEmptyStmt, "불필요한 빈 문장 제거",
                "불필요한 빈 문장 세미콜론을 제거합니다.",
                "체커: 한 줄에 하나의 구문/불필요 문장 계열.",
                "DoWork();;\r\n// ->\r\nDoWork();");
            AddRuleInfo(ASForHoist, "[검토필요] for 다중 선언자 분리",
                "for 초기화절의 다중 선언자를 루프 밖 선언으로 분리합니다.",
                "루프 스코프가 바뀌므로 검토필요 커밋 대상입니다.",
                "for (int i = 0, j = 0; i < n; i++)\r\n// ->\r\nvar j = 0;\r\nfor (var i = 0; i < n; i++)");

            AddRuleInfo(RunTrackBCheck, "Track B 주석/레이아웃",
                "주석 문장 규칙과 일부 레이아웃 규칙을 텍스트 기반으로 보정합니다.",
                "COMMENT.*, BETWEEN_MEMBER_DEFINITION, ONE_DECLARATION/STATEMENT, LINQ alignment, continuation indentation 계열.",
                "선택된 Track B 규칙만 -Rules로 전달됩니다.");
            AddRuleInfo(BTrailing, "코드 뒤 주석을 위 줄로 이동",
                "코드 뒤에 붙은 주석을 코드 위의 독립 주석 줄로 이동하고 문장 규칙을 맞춥니다.",
                "체커: 독립된 줄의 주석 작성 권장, 주석 앞 빈 줄 계열.",
                "DoWork(); //done\r\n// ->\r\n// Done.\r\nDoWork();");
            AddRuleInfo(BSpace, "주석 기호 뒤 공백 추가",
                "주석 기호 뒤 공백을 보강합니다.",
                "체커: FORMATTING.COMMENT.MISSING_SPACE_AFTER_DELIMITER.",
                "//done\r\n// ->\r\n// done");
            AddRuleInfo(BPeriod, "주석 끝 마침표 추가",
                "일반 문장 주석 끝에 마침표를 추가합니다.",
                "체커: FORMATTING.COMMENT.MISSING_PERIOD. Doxygen line-form은 보호 대상입니다.",
                "// Done\r\n// ->\r\n// Done.");
            AddRuleInfo(BCapitalize, "주석 첫 영문 대문자화",
                "주석 첫 ASCII 영문자를 대문자로 바꿉니다.",
                "체커: FORMATTING.COMMENT.LOWERCASE_FIRST_LETTER.",
                "// done.\r\n// ->\r\n// Done.");
            AddRuleInfo(BFlatten, "별표/Doxygen 블록 주석 평탄화",
                "별표 블록/Doxygen 주석을 의미 보존이 가능한 한 줄 주석 형태로 평탄화합니다.",
                "체커: FORMATTING.COMMENT.BLOCK_OF_ASTERISK.",
                "/** @brief delta marker */\r\n// ->\r\n// Delta marker.");
            AddRuleInfo(BMemberBlank, "멤버 선언 사이 빈 줄 추가",
                "메서드/프로퍼티/필드 등 멤버 선언 사이에 빈 줄을 추가합니다.",
                "체커: FORMATTING.BETWEEN_MEMBER_DEFINITION.MISSING_BLANK_LINE.",
                "public int A { get; set; }\r\npublic int B { get; set; }\r\n// ->\r\npublic int A { get; set; }\r\n\r\npublic int B { get; set; }");
            AddRuleInfo(BOneDeclaration, "한 줄 다중 선언 분리",
                "한 줄에 여러 지역변수를 선언한 구문을 줄별 선언으로 나눕니다.",
                "체커: 한 줄에 하나의 선언문 배치.",
                "int x = 1, y = 2;\r\n// ->\r\nint x = 1;\r\nint y = 2;");
            AddRuleInfo(BOneStatement, "한 줄 다중 구문 분리",
                "한 줄에 여러 문장이 붙은 구문을 문장별 줄로 나눕니다.",
                "체커: 한 줄에 하나의 구문 배치.",
                "Start(); Stop();\r\n// ->\r\nStart();\r\nStop();");
            AddRuleInfo(BContinuation, "여러 줄 문장 들여쓰기 보정",
                "여러 줄 문장의 continuation line 들여쓰기를 보정합니다.",
                "체커: FORMATTING.CONTINUATION_LINE.BAD_INDENTATION. 변경량이 클 수 있어 DryRun 확인을 권장합니다.",
                "var value = Foo(\r\nx,\r\ny);\r\n// ->\r\nvar value = Foo(\r\n    x,\r\n    y);");
            AddRuleInfo(BLinqAlign, "LINQ 쿼리 절 정렬",
                "LINQ query expression의 from/where/select 절 정렬을 맞춥니다.",
                "체커: FORMATTING.LINQ.QUERY_CLAUSE_ALIGNMENT.",
                "var q = from x in xs\r\nwhere x.Enabled\r\nselect x;\r\n// ->\r\nvar q = from x in xs\r\n        where x.Enabled\r\n        select x;");
            AddRuleInfo(BBlockPromote, "[검토필요] inline block 주석 이동",
                "코드 뒤 inline block comment를 코드 위 독립 주석으로 승격합니다.",
                "체커: 독립된 줄의 주석 작성 권장/별표 블록 제한. 검토필요 커밋 대상입니다.",
                "DoWork(); /* done */\r\n// ->\r\n// Done.\r\nDoWork();");

            AddRuleInfo(RunTrackCCheck, "Track C XLS 작업 패키지 생성",
                "Sparrow 결과 XLS를 읽고 폐쇄망 LLM에게 넘길 self-contained requests 폴더만 생성합니다.",
                "Track C는 소스 자동수정이 아니라 폐쇄망 LLM이 바로 수정 방향을 잡도록 입력을 정리하는 결정론 패키징 단계입니다. GUI 출력에는 items/index/checkers/worklist 같은 내부 산출물을 남기지 않습니다.",
                "issues.xls\r\n// ->\r\nrequests/\r\n  FORWARD_NULL/\r\n    5001_FORWARD_NULL.md");
            AddRuleInfo(CommitCheck, "규칙별 커밋 생성",
                "각 규칙 실행 후 변경된 .cs 파일을 규칙별 커밋으로 남깁니다.",
                "검토필요 규칙은 커밋 메시지에 '! 검토필요'가 포함되도록 CLI가 처리합니다.",
                "체크: 규칙별 자동 커밋\r\n해제: 파일만 수정하고 커밋하지 않음");
            AddRuleInfo(DryRunCheck, "DryRun",
                "실제 파일 변경 없이 변경 후보와 로그만 확인합니다.",
                "DryRun 상태에서는 커밋 옵션이 자동으로 꺼집니다.",
                "체크: -DryRun 전달\r\n해제: 선택한 커밋 옵션에 따라 실제 수정");
            AddRuleInfo(IncludeGeneratedCheck, "Track B 생성 파일 포함",
                "Track B가 generated 파일로 판단한 파일까지 수정 대상에 포함합니다.",
                "기본은 제외입니다. 생성 코드까지 Sparrow 대상이면 켜고, 아니면 꺼두는 편이 안전합니다.",
                "체크: -IncludeGenerated 전달\r\n해제: 생성 파일 제외");
        }

        private void AddRuleInfo(CheckBox checkBox, string title, string summary, string checker, string example)
        {
            var (before, after) = SplitExample(example);
            var info = new RuleInfo(title, summary, checker, before, after);
            _ruleInfos[checkBox.Name] = info;
            checkBox.ToolTip = title + Environment.NewLine + checker;
            checkBox.MouseEnter += RuleControl_MouseEnter;
            checkBox.GotKeyboardFocus += RuleControl_FocusOrClick;
            checkBox.Click += RuleControl_FocusOrClick;
            checkBox.Checked += RuleControl_CheckedChanged;
            checkBox.Unchecked += RuleControl_CheckedChanged;
        }

        private void RuleControl_MouseEnter(object sender, MouseEventArgs e)
        {
            if (sender is CheckBox checkBox) ShowRuleInfo(checkBox.Name);
        }

        private void RuleControl_FocusOrClick(object sender, RoutedEventArgs e)
        {
            if (sender is CheckBox checkBox) ShowRuleInfo(checkBox.Name);
            UpdateSummary();
        }

        private void RuleControl_CheckedChanged(object sender, RoutedEventArgs e)
        {
            if (ReferenceEquals(sender, IncludeGeneratedCheck))
            {
                _ = RefreshScopeAsync(showErrors: false);
            }
            UpdateSummary();
        }

        private void ShowRuleInfo(string key)
        {
            if (!_ruleInfos.TryGetValue(key, out RuleInfo? info))
            {
                RuleInfoTitle.Text = "규칙 설명";
                RuleInfoBody.Text = "규칙을 선택하면 대응 체커와 변경 예시가 표시됩니다.";
                RuleBeforeBox.Text = "";
                RuleAfterBox.Text = "";
                return;
            }

            RuleInfoTitle.Text = info.Title;
            RuleInfoBody.Text = info.Summary + Environment.NewLine + info.Checker;
            RuleBeforeBox.Text = info.Before;
            RuleAfterBox.Text = info.After;
        }

        private static (string Before, string After) SplitExample(string example)
        {
            string normalized = example.Replace("\r\n", "\n");
            const string marker = "\n// ->\n";
            int index = normalized.IndexOf(marker, StringComparison.Ordinal);
            if (index < 0)
            {
                return (example.Trim(), "");
            }

            string before = normalized.Substring(0, index).Trim();
            string after = normalized.Substring(index + marker.Length).Trim();
            return (before, after);
        }

        private void UpdateSummary()
        {
            if (!IsLoaded) return;

            int trackA = RunTrackASyntaxCheck.IsChecked == true
                ? CountChecked(ASObjectVarSafe, ASObviousVar, ASArrayVarSafe, ASParens, ASForeachCast,
                    ASObjectInitializer, ASNullVar, ASObjectVarNarrowing, ASLocalConst, ASArrayVarNarrowing,
                    ASForVar, ASFieldSplit, ASEmptyStmt, ASForHoist)
                : 0;
            int trackB = RunTrackBCheck.IsChecked == true
                ? CountChecked(BTrailing, BSpace, BPeriod, BCapitalize, BFlatten, BMemberBlank,
                    BOneDeclaration, BOneStatement, BContinuation, BLinqAlign, BBlockPromote)
                : 0;
            int reviewNeeded = CountChecked(ASForeachCast, ASNullVar, ASObjectVarNarrowing, ASLocalConst,
                ASArrayVarNarrowing, ASForHoist, BBlockPromote);
            int total = trackA + trackB;
            bool trackC = RunTrackCCheck.IsChecked == true;
            int selectedFiles = _currentScope?.SelectedFiles.Count ?? 0;
            int totalFiles = _currentScope?.TotalFiles ?? 0;
            int excludedFiles = _currentScope?.ExcludedFiles ?? 0;

            if (_currentScope != null)
            {
                ScopeStatusText.Text = $"{selectedFiles}개 선택 / {totalFiles}개 발견"
                    + (excludedFiles > 0 ? $" / {excludedFiles}개 제외" : "");
            }

            string target = TargetPathBox.Text.Trim();
            SummaryTargetText.Text = string.IsNullOrEmpty(target)
                ? "대상 경로가 필요합니다."
                : target;
            SummaryRulesText.Text = trackC
                ? $"선택 규칙 {total}개 · Track C 포함"
                : $"선택 규칙 {total}개";

            string mode = DryRunCheck.IsChecked == true
                ? "DryRun: 파일을 변경하지 않고 후보만 확인"
                : CommitCheck.IsChecked == true
                    ? "규칙별 커밋: 규칙 단위로 변경을 묶음"
                    : "파일만 수정: 커밋은 생성하지 않음";
            SummaryModeText.Text = $"{mode} / A {trackA} · B {trackB} · C {(trackC ? "ON" : "OFF")} · 검토필요 {reviewNeeded} · 선택 파일 {selectedFiles}";
        }
        private static int CountChecked(params CheckBox[] boxes)
        {
            return boxes.Count(b => b.IsChecked == true);
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
                string runner = Path.Combine(dir.FullName, "tools", "Run-SparrowRunnerGui.cmd");
                string syntax = Path.Combine(dir.FullName, "tools", "_internal", "SparrowSyntaxFix", "Run-SparrowSyntaxFix.ps1");
                if (File.Exists(skill) && File.Exists(runner) && File.Exists(syntax)) return dir.FullName;
            }

            string fallback = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", ".."));
            if (File.Exists(Path.Combine(fallback, "SKILL.md")) &&
                File.Exists(Path.Combine(fallback, "tools", "Run-SparrowRunnerGui.cmd")))
            {
                return fallback;
            }

            throw new DirectoryNotFoundException("sparrow-static-analysis skill root를 찾을 수 없습니다.");
        }

        private void SetRunning(bool running)
        {
            RunButton.IsEnabled = !running;
            StopButton.IsEnabled = running;
            BrowseFileButton.IsEnabled = !running;
            BrowseFolderButton.IsEnabled = !running;
            RefreshScopeButton.IsEnabled = !running;
            SelectAllScopeButton.IsEnabled = !running;
            ClearScopeButton.IsEnabled = !running;
            ScopeTree.IsEnabled = !running;
            BrowseTrackCXlsButton.IsEnabled = !running;
            BrowseTrackCOutputButton.IsEnabled = !running;
            BrowseTrackCReferencesButton.IsEnabled = !running;
            RulesTabs.IsEnabled = !running;
            TargetPathBox.IsEnabled = !running;
            TrackCXlsPathBox.IsEnabled = !running;
            TrackCOutputPathBox.IsEnabled = !running;
            TrackCReferencesPathBox.IsEnabled = !running;
            StatusText.Text = running ? "실행 중..." : "대기 중";
        }

        private void AppendLog(string line)
        {
            LogBox.AppendText(line + Environment.NewLine);
            LogBox.ScrollToEnd();
        }

        private sealed class RuleInfo
        {
            public RuleInfo(string title, string summary, string checker, string before, string after)
            {
                Title = title;
                Summary = summary;
                Checker = checker;
                Before = before;
                After = after;
            }

            public string Title { get; }
            public string Summary { get; }
            public string Checker { get; }
            public string Before { get; }
            public string After { get; }
        }

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
