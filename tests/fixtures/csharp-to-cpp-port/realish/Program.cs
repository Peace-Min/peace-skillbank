using System;
using Realish.Core;
using Realish.Services;

namespace Realish
{
    internal static class Program
    {
        private static void Main(string[] args)
        {
            var consumer = new Consumer();
            var node = new Node { Id = 1 };
            Repo<Node>.Instance.Add(node);
            Console.WriteLine(Repo<Node>.Instance.Count);
            Console.WriteLine(consumer.Describe(new Item { Code = "a", Quantity = 1 }, node));
        }
    }
}
