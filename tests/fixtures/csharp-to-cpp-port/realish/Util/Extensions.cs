using Realish.Core;

namespace Realish.Util
{
    public static class Extensions
    {
        public static bool IsLeaf(this Node node)
        {
            return node.Children.Count == 0;
        }
    }
}
