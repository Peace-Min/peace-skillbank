using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using SparrowXlsExport.Core;

namespace SparrowRunner.Gui
{
    /// <summary>
    /// Modeless manager for Track C checker guides (references\checkers\&lt;CHECKER_KEY&gt;.md).
    /// Lets the user register a rule for a checker that has no hand-authored guide yet: the left list is the
    /// registered rules (add / remove / edit-save), the top list surfaces the checkers actually present in the
    /// selected Sparrow XLS marked 등록됨/미등록 so the user does not need to know checker names in advance.
    /// Rules added here are consumed by TriagePreparer on the next Track C run (it reads the guides dir per run).
    /// </summary>
    public partial class RuleManagerWindow : Window
    {
        private static readonly Brush RegBg = new SolidColorBrush(Color.FromRgb(0xE7, 0xF6, 0xEC));
        private static readonly Brush RegFg = new SolidColorBrush(Color.FromRgb(0x1F, 0x92, 0x54));
        private static readonly Brush UnregBg = new SolidColorBrush(Color.FromRgb(0xFF, 0xF3, 0xE0));
        private static readonly Brush UnregFg = new SolidColorBrush(Color.FromRgb(0xC7, 0x77, 0x00));

        private readonly CheckerRuleStore _store;
        private readonly string? _xlsPath;
        private readonly HashSet<string> _registeredKeys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        private IReadOnlyList<string> _xlsKeys = Array.Empty<string>();

        private string? _editingKey;   // selected registered rule; null == "new rule" mode
        private bool _suppressSelection;

        public RuleManagerWindow(Window owner, string guidesDir, string? xlsPath)
        {
            InitializeComponent();
            Owner = owner;
            _store = new CheckerRuleStore(guidesDir);
            _xlsPath = string.IsNullOrWhiteSpace(xlsPath) ? null : xlsPath;

            RefreshRegistered();
            LoadXlsCheckers();
            NewRuleMode();
            StatusText.Text = "가이드 폴더: " + guidesDir;
        }

        // --- registered rules ---

        private void RefreshRegistered()
        {
            IReadOnlyList<CheckerRule> rules;
            try
            {
                rules = _store.List();
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, ex.Message, "목록 읽기 실패", MessageBoxButton.OK, MessageBoxImage.Error);
                rules = Array.Empty<CheckerRule>();
            }

            _registeredKeys.Clear();
            var views = new List<RegisteredView>();
            foreach (CheckerRule r in rules)
            {
                _registeredKeys.Add(r.Key);
                views.Add(new RegisteredView(r.Key, r.Title));
            }

            _suppressSelection = true;
            RegisteredList.ItemsSource = views;
            _suppressSelection = false;
            RegisteredTitle.Text = "등록된 체커 룰 (" + views.Count + ")";
            RefreshXlsMarking();
        }

        private void RegisteredList_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (_suppressSelection) return;
            if (RegisteredList.SelectedItem is not RegisteredView view) return;

            try
            {
                EditorBox.Text = _store.ReadContent(view.Key);
                _editingKey = view.Key;
                EditorTitle.Text = "가이드 편집 · " + view.Key;
                AddKeyBox.Text = "";
                StatusText.Text = "선택: " + view.Key;
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, ex.Message, "가이드 읽기 실패", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        private void NewRuleButton_Click(object sender, RoutedEventArgs e) => NewRuleMode();

        private void NewRuleMode()
        {
            _suppressSelection = true;
            RegisteredList.SelectedItem = null;
            _suppressSelection = false;
            _editingKey = null;
            EditorBox.Text = _store.LoadTemplate();
            EditorTitle.Text = "새 룰 작성";
            AddKeyBox.Focus();
        }

        private void ConfirmAddButton_Click(object sender, RoutedEventArgs e)
        {
            string key = AddKeyBox.Text.Trim();
            string content = string.IsNullOrWhiteSpace(EditorBox.Text) ? _store.LoadTemplate() : EditorBox.Text;
            try
            {
                _store.Add(key, content);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, ex.Message, "추가 실패", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            AddKeyBox.Text = "";
            RefreshRegistered();
            SelectRegistered(key);
            StatusText.Text = "추가됨: " + key;
        }

        private void SaveRuleButton_Click(object sender, RoutedEventArgs e)
        {
            if (_editingKey == null)
            {
                MessageBox.Show(this,
                    "저장할 룰이 선택되지 않았습니다.\n새 룰이면 '새 체커 키'를 입력하고 '확인'을 누르세요.",
                    "저장 안내", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            try
            {
                _store.SaveContent(_editingKey, EditorBox.Text);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, ex.Message, "저장 실패", MessageBoxButton.OK, MessageBoxImage.Error);
                return;
            }

            string key = _editingKey;
            RefreshRegistered();
            SelectRegistered(key);
            StatusText.Text = "저장됨: " + key;
        }

        private void RemoveRuleButton_Click(object sender, RoutedEventArgs e)
        {
            if (RegisteredList.SelectedItem is not RegisteredView view)
            {
                MessageBox.Show(this, "제거할 룰을 목록에서 선택하세요.", "제거 안내",
                    MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            MessageBoxResult confirm = MessageBox.Show(this,
                "정말 삭제할까요? '" + view.Key + ".md' 파일이 지워집니다.",
                "체커 룰 삭제", MessageBoxButton.OKCancel, MessageBoxImage.Warning);
            if (confirm != MessageBoxResult.OK) return;

            try
            {
                _store.Remove(view.Key);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, ex.Message, "제거 실패", MessageBoxButton.OK, MessageBoxImage.Error);
                return;
            }

            string key = view.Key;
            RefreshRegistered();
            NewRuleMode();
            StatusText.Text = "삭제됨: " + key;
        }

        private void SelectRegistered(string key)
        {
            if (RegisteredList.ItemsSource is not IEnumerable<RegisteredView> views) return;
            RegisteredView? match = views.FirstOrDefault(v => string.Equals(v.Key, key, StringComparison.OrdinalIgnoreCase));
            if (match != null) RegisteredList.SelectedItem = match;   // triggers SelectionChanged -> loads content
        }

        // --- XLS checker discovery ---

        private void LoadXlsCheckers()
        {
            if (_xlsPath == null || !File.Exists(_xlsPath))
            {
                XlsCheckerList.Visibility = Visibility.Collapsed;
                AddFromXlsButton.IsEnabled = false;
                XlsHintText.Text = "선택된 Sparrow 결과 XLS가 없습니다. 메인 화면 Track C에서 XLS를 먼저 선택하면 그 XLS의 체커 목록이 여기에 표시됩니다.";
                return;
            }

            try
            {
                _xlsKeys = CheckerRuleStore.GetXlsCheckerKeys(_xlsPath);
            }
            catch (Exception ex)
            {
                XlsCheckerList.Visibility = Visibility.Collapsed;
                AddFromXlsButton.IsEnabled = false;
                XlsHintText.Text = "XLS 체커를 읽지 못했습니다: " + ex.Message;
                return;
            }

            if (_xlsKeys.Count == 0)
            {
                XlsCheckerList.Visibility = Visibility.Collapsed;
                AddFromXlsButton.IsEnabled = false;
                XlsHintText.Text = "이 XLS에서 '체커 키' 컬럼 값을 찾지 못했습니다.";
                return;
            }

            XlsHintText.Text = "미등록 항목을 더블클릭하면 그 키로 새 룰 추가가 채워집니다. (총 " + _xlsKeys.Count + "개 체커)";
            RefreshXlsMarking();
        }

        private void RefreshXlsMarking()
        {
            if (_xlsKeys.Count == 0) return;
            var views = _xlsKeys
                .Select(k => new XlsCheckerView(k, _registeredKeys.Contains(k)))
                .ToList();
            XlsCheckerList.ItemsSource = views;
        }

        private void XlsCheckerList_MouseDoubleClick(object sender, MouseButtonEventArgs e)
        {
            if (XlsCheckerList.SelectedItem is XlsCheckerView view) ActOnXlsChecker(view);
        }

        private void AddFromXlsButton_Click(object sender, RoutedEventArgs e)
        {
            if (XlsCheckerList.SelectedItem is not XlsCheckerView view)
            {
                MessageBox.Show(this, "위 목록에서 체커를 먼저 선택하세요.", "안내",
                    MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }
            ActOnXlsChecker(view);
        }

        // Registered checker -> select it for editing; unregistered -> prefill the add flow with its key.
        private void ActOnXlsChecker(XlsCheckerView view)
        {
            if (view.Registered)
            {
                SelectRegistered(view.Key);
                StatusText.Text = "이미 등록됨: " + view.Key;
                return;
            }

            _suppressSelection = true;
            RegisteredList.SelectedItem = null;
            _suppressSelection = false;
            _editingKey = null;
            AddKeyBox.Text = view.Key;
            EditorBox.Text = _store.LoadTemplate();
            EditorTitle.Text = "새 룰 작성 · " + view.Key;
            AddKeyBox.Focus();
            StatusText.Text = "새 룰 준비: " + view.Key + " — 편집 후 '확인'을 누르세요.";
        }

        private void CloseButton_Click(object sender, RoutedEventArgs e) => Close();

        // --- view models ---

        private sealed class RegisteredView
        {
            public RegisteredView(string key, string title)
            {
                Key = key;
                Title = string.IsNullOrWhiteSpace(title) ? "(제목 없음)" : title;
            }

            public string Key { get; }
            public string Title { get; }
        }

        private sealed class XlsCheckerView
        {
            public XlsCheckerView(string key, bool registered)
            {
                Key = key;
                Registered = registered;
            }

            public string Key { get; }
            public bool Registered { get; }
            public string StatusLabel => Registered ? "등록됨" : "미등록";
            public Brush BadgeBackground => Registered ? RegBg : UnregBg;
            public Brush BadgeForeground => Registered ? RegFg : UnregFg;
        }
    }
}
