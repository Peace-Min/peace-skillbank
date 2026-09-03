using System.Collections.Generic;

namespace Realish.Core
{
    public class Repo<T> : IRepository<T> where T : class
    {
        public enum Mode
        {
            Strict = 0,
            Lenient = 1
        }

        private readonly Dictionary<int, T> _items = new Dictionary<int, T>();
        public static Repo<T> Instance { get; } = new Repo<T>();
        public Mode CurrentMode { get; set; }

        public T Get(int id)
        {
            T found;
            return _items.TryGetValue(id, out found) ? found : null;
        }

        public void Add(T item)
        {
            _items[_items.Count + 1] = item;
        }

        public int Count { get { return _items.Count; } }

#if DEBUG
        public string DebugInfo() { return "debug"; }
#else
        public string DebugInfo() { return "release"; }
#endif
    }
}
