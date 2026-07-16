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
using System.Windows.Input;
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
        private readonly Dictionary<string, RuleInfo> _ruleInfos = new Dictionary<string, RuleInfo>(StringComparer.Ordinal);
        private CancellationTokenSource? _cts;
        private Process? _currentProcess;

        public MainWindow()
        {
            InitializeComponent();

            _skillRoot = ResolveSkillRoot();
            _referencesDir = Path.Combine(_skillRoot, "references");
            _toolsDir = Path.Combine(_skillRoot, "tools");
            AppendLog("skill root: " + _skillRoot);
            InitializeRuleInfo();
            ShowRuleInfo(nameof(RunTrackASyntaxCheck));
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

        private void InitializeRuleInfo()
        {
            AddRuleInfo(RunTrackAFormatCheck, "Track A 1차 dotnet format",
                "기존 Run-TrackA.ps1을 실행합니다. IDE/dotnet format 규칙 기반으로 var, 괄호, object initializer 일부를 처리합니다.",
                "보완 체커: Track A 코드 규칙 일부. 최근 보완된 Roslyn 2차 규칙보다 범위가 거칠 수 있어 기본값은 꺼져 있습니다.",
                "선택 시: 아래 1차 dotnet format 규칙 중 체크된 항목만 -Rules로 전달합니다.");
            AddRuleInfo(A1Var, "1차 var",
                "dotnet format 기반 var 선호 규칙입니다.",
                "보완 체커: 명확한 타입/인스턴스 생성/루프 변수 var 권장 계열.",
                "int count = 0;\r\n// ->\r\nvar count = 0;");
            AddRuleInfo(A1Parens, "1차 parens",
                "논리식의 의미를 명확히 하기 위해 괄호를 보강합니다.",
                "보완 체커: 복합 논리식 괄호 명확화 계열.",
                "if (a && b || c)\r\n// ->\r\nif ((a && b) || c)");
            AddRuleInfo(A1Initializer, "1차 initializer",
                "객체 생성 직후 이어지는 속성 대입을 object initializer로 합칩니다.",
                "보완 체커: PRACTICE.OBJECT_INITIALIZATION.NOT_USED_INITIALIZER.",
                "var item = new Foo();\r\nitem.Name = name;\r\n// ->\r\nvar item = new Foo { Name = name };");

            AddRuleInfo(RunTrackASyntaxCheck, "Track A 2차 Roslyn",
                "Run-SparrowSyntaxFix.ps1을 실행합니다. 현재 Track A의 주력 자동수정이며 Roslyn 구문 트리 기준으로 C# 파일을 수정합니다.",
                "보완 체커: var, object initializer, 배열 초기화, foreach 루프 변수, 괄호, 다중 선언 등 코드 규칙 계열.",
                "선택 시: 아래 Roslyn 규칙 중 체크된 항목만 -Rules로 전달합니다.");
            AddRuleInfo(ASObjectVarSafe, "objectvar-safe",
                "선언 타입과 생성 타입이 같은 지역변수를 var로 바꿉니다.",
                "보완 체커: PRACTICE.OBJECT_INSTANTIATION.NOT_USED_IMPLICIT_TYPING. 정적 타입 축소가 없는 기본 안전 규칙입니다.",
                "Foo item = new Foo();\r\n// ->\r\nvar item = new Foo();");
            AddRuleInfo(ASObviousVar, "obviousvar",
                "리터럴, 캐스트, 명확한 생성/호출 결과처럼 타입 추론이 분명한 지역변수를 var로 바꿉니다.",
                "보완 체커: PRACTICE.OBVIOUS_VARIABLE_TYPE.NOT_USED_IMPLICIT_TYPING.",
                "string name = \"A\";\r\ndouble ratio = (double)20;\r\n// ->\r\nvar name = \"A\";\r\nvar ratio = (double)20;");
            AddRuleInfo(ASArrayVarSafe, "arrayvar-safe",
                "동일 배열 타입의 장황한 초기화 구문만 줄입니다.",
                "보완 체커: PRACTICE.ARRAY_DECLARATION.COMPLICATED_SYNTAX. 선언 타입은 유지합니다.",
                "int[] values = new int[] { 1, 2, 3 };\r\n// ->\r\nint[] values = { 1, 2, 3 };");
            AddRuleInfo(ASParens, "parens",
                "&&와 ||가 섞인 조건식의 피연산자에 괄호를 추가합니다.",
                "보완 체커: 복합 논리식 괄호 명확화 계열.",
                "if (isReady && hasValue || forced)\r\n// ->\r\nif ((isReady && hasValue) || forced)");
            AddRuleInfo(ASForeachCast, "foreachcast",
                "비제네릭 컬렉션 foreach의 명시 타입을 Cast<T>()와 var 조합으로 바꿉니다.",
                "보완 체커: PRACTICE.LOOP_VARIABLE.NOT_USED_IMPLICIT_TYPING. 검토필요 커밋 대상입니다.",
                "foreach (XmlNode node in nodes)\r\n// ->\r\nforeach (var node in System.Linq.Enumerable.Cast<XmlNode>(nodes))");
            AddRuleInfo(ASObjectInitializer, "objectinitializer",
                "객체 생성 직후 연속된 단순 속성/필드 대입을 initializer로 합칩니다.",
                "보완 체커: PRACTICE.OBJECT_INITIALIZATION.NOT_USED_INITIALIZER. 연속 구간만 처리합니다.",
                "var item = new Foo();\r\nitem.A = 1;\r\nitem.B = text;\r\n// ->\r\nvar item = new Foo { A = 1, B = text };");
            AddRuleInfo(ASNullVar, "nullvar",
                "초기값이 없거나 null인 명시 지역변수를 typed null var 형태로 바꿉니다.",
                "보완 체커: 명확한 지역변수 var 권장 계열. 검토필요 커밋 대상입니다.",
                "Foo item;\r\n// ->\r\nvar item = (Foo)null;");
            AddRuleInfo(ASObjectVarNarrowing, "objectvar-narrowing",
                "인터페이스/상위 타입 선언을 실제 생성 타입 var로 바꿉니다.",
                "보완 체커: 인스턴스 생성 시 var 권장. 정적 타입 축소가 발생하므로 검토필요 커밋 대상입니다.",
                "IList<string> names = new List<string>();\r\n// ->\r\nvar names = new List<string>();");
            AddRuleInfo(ASLocalConst, "localconst",
                "지역 const 선언을 일반 var 지역변수로 바꿉니다.",
                "보완 체커: 명확한 지역변수 var 권장 계열. 지역 const 의미가 중요한 경우 검토가 필요합니다.",
                "const string Code = \"A\";\r\n// ->\r\nvar Code = \"A\";");
            AddRuleInfo(ASArrayVarNarrowing, "arrayvar-narrowing",
                "선언 배열 타입을 var와 암시 배열 생성으로 줄입니다.",
                "보완 체커: 배열 초기화 간소화/var 권장 계열. object[] 등 정적 타입 축소 가능성이 있어 검토필요 커밋 대상입니다.",
                "int[] values = new int[] { 1, 2, 3 };\r\n// ->\r\nvar values = new[] { 1, 2, 3 };");
            AddRuleInfo(ASForVar, "forvar",
                "for 초기화절의 명시 타입을 var로 바꿉니다.",
                "보완 체커: 루프 변수 암시적 타입 사용 권장.",
                "for (int i = 0; i < count; i++)\r\n// ->\r\nfor (var i = 0; i < count; i++)");
            AddRuleInfo(ASFieldSplit, "fieldsplit",
                "한 줄에 여러 필드를 선언한 구문을 필드별 선언으로 나눕니다.",
                "보완 체커: 한 줄에 하나의 선언문 배치.",
                "private int x, y;\r\n// ->\r\nprivate int x;\r\nprivate int y;");
            AddRuleInfo(ASEmptyStmt, "emptystmt",
                "불필요한 빈 문장 세미콜론을 제거합니다.",
                "보완 체커: 한 줄에 하나의 구문/불필요 문장 계열.",
                "DoWork();;\r\n// ->\r\nDoWork();");
            AddRuleInfo(ASForHoist, "forhoist",
                "for 초기화절의 다중 선언자를 루프 밖 선언으로 분리합니다.",
                "보완 체커: 한 줄에 하나의 선언문 배치. 루프 스코프가 바뀌므로 검토필요 커밋 대상입니다.",
                "for (int i = 0, j = 0; i < n; i++)\r\n// ->\r\nvar j = 0;\r\nfor (var i = 0; i < n; i++)");

            AddRuleInfo(RunTrackBCheck, "Track B 주석/레이아웃",
                "Run-SparrowCommentFix.ps1을 실행합니다. 주석 문장 규칙과 일부 레이아웃 규칙을 텍스트 기반으로 보정합니다.",
                "보완 체커: COMMENT.*, BETWEEN_MEMBER_DEFINITION, ONE_DECLARATION/STATEMENT, LINQ alignment, continuation indentation 계열.",
                "선택 시: 아래 Track B 규칙 중 체크된 항목만 -Rules로 전달합니다.");
            AddRuleInfo(BTrailing, "trailing",
                "코드 뒤에 붙은 주석을 코드 위의 독립 주석 줄로 이동하고 기본 문장 규칙을 맞춥니다.",
                "보완 체커: 독립된 줄의 주석 작성 권장, 주석 앞 빈 줄 계열.",
                "DoWork(); //done\r\n// ->\r\n// Done.\r\nDoWork();");
            AddRuleInfo(BSpace, "space",
                "주석 기호 뒤 공백을 보강합니다.",
                "보완 체커: 주석 구분자 뒤 공백 누락.",
                "//done\r\n// ->\r\n// done");
            AddRuleInfo(BPeriod, "period",
                "일반 문장 주석 끝에 마침표를 추가합니다.",
                "보완 체커: FORMATTING.COMMENT.MISSING_PERIOD. Doxygen line-form은 보호 대상입니다.",
                "// Done\r\n// ->\r\n// Done.");
            AddRuleInfo(BCapitalize, "capitalize",
                "주석 첫 ASCII 영문자를 대문자로 바꿉니다.",
                "보완 체커: FORMATTING.COMMENT.LOWERCASE_FIRST_LETTER.",
                "// done.\r\n// ->\r\n// Done.");
            AddRuleInfo(BFlatten, "flatten",
                "별표 블록/Doxygen 주석을 의미 보존이 가능한 한 줄 주석 형태로 평탄화합니다.",
                "보완 체커: FORMATTING.COMMENT.BLOCK_OF_ASTERISK, Doxygen-style 주석 형식 계열.",
                "/** @brief delta marker */\r\n// ->\r\n// Delta marker.");
            AddRuleInfo(BMemberBlank, "memberblank",
                "메서드/프로퍼티/필드 등 멤버 선언 사이에 빈 줄을 추가합니다.",
                "보완 체커: FORMATTING.BETWEEN_MEMBER_DEFINITION.MISSING_BLANK_LINE.",
                "public int A { get; set; }\r\npublic int B { get; set; }\r\n// ->\r\npublic int A { get; set; }\r\n\r\npublic int B { get; set; }");
            AddRuleInfo(BOneDeclaration, "onedeclaration",
                "한 줄에 여러 지역변수를 선언한 구문을 줄별 선언으로 나눕니다.",
                "보완 체커: 한 줄에 하나의 선언문 배치.",
                "int x = 1, y = 2;\r\n// ->\r\nint x = 1;\r\nint y = 2;");
            AddRuleInfo(BOneStatement, "onestatement",
                "한 줄에 여러 문장이 붙은 구문을 문장별 줄로 나눕니다.",
                "보완 체커: 한 줄에 하나의 구문 배치.",
                "Start(); Stop();\r\n// ->\r\nStart();\r\nStop();");
            AddRuleInfo(BContinuation, "continuation",
                "여러 줄 문장의 continuation line 들여쓰기를 보정합니다.",
                "보완 체커: FORMATTING.CONTINUATION_LINE.BAD_INDENTATION. 레이아웃 변경량이 클 수 있어 DryRun 확인을 권장합니다.",
                "var value = Foo(\r\nx,\r\ny);\r\n// ->\r\nvar value = Foo(\r\n    x,\r\n    y);");
            AddRuleInfo(BLinqAlign, "linqalign",
                "LINQ query expression의 from/where/select 절 정렬을 맞춥니다.",
                "보완 체커: FORMATTING.LINQ.QUERY_CLAUSE_ALIGNMENT.",
                "var q = from x in xs\r\nwhere x.Enabled\r\nselect x;\r\n// ->\r\nvar q = from x in xs\r\n        where x.Enabled\r\n        select x;");
            AddRuleInfo(BBlockPromote, "blockpromote",
                "코드 뒤 inline block comment를 코드 위 독립 주석으로 승격합니다.",
                "보완 체커: 독립된 줄의 주석 작성 권장/별표 블록 제한. 검토필요 커밋 대상입니다.",
                "DoWork(); /* done */\r\n// ->\r\n// Done.\r\nDoWork();");

            AddRuleInfo(CommitCheck, "규칙별 커밋",
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
            var info = new RuleInfo(title, summary, checker, example);
            _ruleInfos[checkBox.Name] = info;
            checkBox.ToolTip = title + Environment.NewLine + checker;
            checkBox.MouseEnter += RuleControl_MouseEnter;
            checkBox.GotKeyboardFocus += RuleControl_FocusOrClick;
            checkBox.Click += RuleControl_FocusOrClick;
        }

        private void RuleControl_MouseEnter(object sender, MouseEventArgs e)
        {
            if (sender is CheckBox checkBox) ShowRuleInfo(checkBox.Name);
        }

        private void RuleControl_FocusOrClick(object sender, RoutedEventArgs e)
        {
            if (sender is CheckBox checkBox) ShowRuleInfo(checkBox.Name);
        }

        private void ShowRuleInfo(string key)
        {
            if (!_ruleInfos.TryGetValue(key, out RuleInfo? info))
            {
                RuleInfoTitle.Text = "규칙 설명";
                RuleInfoBody.Text = "체크박스에 마우스를 올리거나 선택하면 대응 체커와 변경 예시가 표시됩니다.";
                RuleInfoExample.Text = "";
                return;
            }

            RuleInfoTitle.Text = info.Title;
            RuleInfoBody.Text = info.Summary + Environment.NewLine + info.Checker;
            RuleInfoExample.Text = info.Example;
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

        private sealed class RuleInfo
        {
            public RuleInfo(string title, string summary, string checker, string example)
            {
                Title = title;
                Summary = summary;
                Checker = checker;
                Example = example;
            }

            public string Title { get; }
            public string Summary { get; }
            public string Checker { get; }
            public string Example { get; }
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
