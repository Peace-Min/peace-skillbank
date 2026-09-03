namespace Realish.Legacy
{
    public class Item
    {
        #region Consumer
        public string Code { get; set; }
        public string Node { get; set; }
        public int Tree;
        #endregion

#if DEBUG
        public string Build() { return "debug"; }
#else
        public string Build() { return "release"; }
#endif
    }
}
