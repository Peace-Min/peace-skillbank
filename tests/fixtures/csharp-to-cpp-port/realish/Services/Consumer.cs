using System;
using Realish.Core;
using Realish.Util;

namespace Realish.Services
{
    public class Consumer
    {
        private readonly Tree _tree = new Tree();

        #region Helpers
        public string Describe(Item item, Node node)
        {
            return item.Code + (node.IsLeaf() ? " leaf" : " branch") + " size=" + _tree.Size();
        }
        #endregion
    }
}
