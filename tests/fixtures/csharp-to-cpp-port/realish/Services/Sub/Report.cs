using Realish.Core;

namespace Realish.Services.Sub
{
    public class Report
    {
        public string Render(Item item)
        {
            return item.Code + ":" + item.Quantity;
        }
    }
}
