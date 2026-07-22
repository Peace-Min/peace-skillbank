using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Linq;

namespace SparrowRunner.Gui
{
    public sealed class SourceScopeNode : INotifyPropertyChanged
    {
        private bool? _isChecked;
        private bool _isExpanded;
        private bool _updating;

        public SourceScopeNode(string name, string fullPath, bool isFile, SourceScopeNode? parent = null)
        {
            Name = name;
            FullPath = fullPath;
            IsFile = isFile;
            Parent = parent;
            Children = new ObservableCollection<SourceScopeNode>();
            _isChecked = true;
        }

        public event PropertyChangedEventHandler? PropertyChanged;

        public string Name { get; }
        public string FullPath { get; }
        public bool IsFile { get; }
        public bool HasChildren => Children.Count > 0;
        public SourceScopeNode? Parent { get; }
        public ObservableCollection<SourceScopeNode> Children { get; }

        public bool IsExpanded
        {
            get => _isExpanded;
            set
            {
                if (_isExpanded == value) return;
                _isExpanded = value;
                OnPropertyChanged(nameof(IsExpanded));
            }
        }

        public bool? IsChecked
        {
            get => _isChecked;
            set => SetChecked(value, updateChildren: true, updateParent: true);
        }

        public IEnumerable<string> EnumerateFiles()
        {
            if (IsFile)
            {
                yield return FullPath;
                yield break;
            }

            foreach (SourceScopeNode child in Children)
            {
                foreach (string file in child.EnumerateFiles())
                {
                    yield return file;
                }
            }
        }

        public IEnumerable<string> EnumerateSelectedFiles()
        {
            if (IsFile)
            {
                if (_isChecked == true) yield return FullPath;
                yield break;
            }

            foreach (SourceScopeNode child in Children)
            {
                foreach (string file in child.EnumerateSelectedFiles())
                {
                    yield return file;
                }
            }
        }

        public void SetSubtree(bool isChecked)
        {
            SetChecked(isChecked, updateChildren: true, updateParent: true);
        }

        public void ApplySelection(ISet<string> selectedFiles)
        {
            if (IsFile)
            {
                SetChecked(selectedFiles.Contains(FullPath), updateChildren: false, updateParent: true);
                return;
            }

            foreach (SourceScopeNode child in Children)
            {
                child.ApplySelection(selectedFiles);
            }
            RefreshFromChildren();
        }

        public void RefreshFromChildren()
        {
            if (IsFile || Children.Count == 0) return;
            bool all = Children.All(c => c.IsChecked == true);
            bool none = Children.All(c => c.IsChecked == false);
            SetChecked(all ? true : none ? false : null, updateChildren: false, updateParent: true);
        }

        private void SetChecked(bool? value, bool updateChildren, bool updateParent)
        {
            if (_updating) return;
            if (_isChecked == value && (!updateChildren || IsFile)) return;

            try
            {
                _updating = true;
                _isChecked = value;
                OnPropertyChanged(nameof(IsChecked));

                if (updateChildren && value.HasValue)
                {
                    foreach (SourceScopeNode child in Children)
                    {
                        child.SetChecked(value.Value, updateChildren: true, updateParent: false);
                    }
                }
            }
            finally
            {
                _updating = false;
            }

            if (updateParent)
            {
                Parent?.RefreshFromChildren();
            }
        }

        private void OnPropertyChanged(string name)
        {
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
        }
    }
}
