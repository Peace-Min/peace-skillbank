namespace Realish.Core
{
    public interface IRepository<T>
    {
        T Get(int id);
        void Add(T item);
        int Count { get; }
    }
}
