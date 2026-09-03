using System;
using System.Windows.Forms;
using Realish.Core;

namespace Realish.Forms
{
    public partial class MainForm : Form
    {
        private readonly IRepository<Node> _nodes;
        private Tree _tree;

        public MainForm(IRepository<Node> nodes)
        {
            InitializeComponent();
            _nodes = nodes;
            _tree = new Tree();
        }

        private void OnLoad(object sender, EventArgs e)
        {
            Text = Realish.Properties.Resources.AppTitle;
            _tree.Root = _nodes.Get(1);
        }
    }
}
