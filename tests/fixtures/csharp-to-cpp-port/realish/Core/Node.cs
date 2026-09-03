using System.Collections.Generic;

namespace Realish.Core
{
    public class Node
    {
        public int Id { get; set; }
        public Tree Owner { get; set; }
        public List<Node> Children { get; } = new List<Node>();

        public int Depth()
        {
            int d = 0;
            foreach (Node c in Children) { d = System.Math.Max(d, c.Depth() + 1); }
            return d;
        }
    }
}
