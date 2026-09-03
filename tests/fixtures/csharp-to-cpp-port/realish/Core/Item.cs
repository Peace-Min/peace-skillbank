namespace Realish.Core
{
    public struct Item
    {
        public int Id;
        public string Label;

        public override string ToString()
        {
            return Id + ":" + Label;
        }
    }
}
