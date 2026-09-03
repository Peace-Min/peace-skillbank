namespace Realish.Core
{
    public class Tree
    {
        public Node Root { get; set; }

        public int Size()
        {
            return Root == null ? 0 : 1 + Root.Children.Count;
        }
    }
}
