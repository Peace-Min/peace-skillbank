using Arction.Wpf.Charting;
using Arction.Wpf.Charting.SeriesXY;
using Arction.Wpf.Charting.Views.ViewXY;

public class ChartSetup
{
    public void Build(LightningChart chart)
    {
        chart.BeginUpdate();

        // The local model keeps suggesting this line, but the build fails -- I can't find
        // AddRainbowAxis anywhere in IntelliSense. Is it real?
        chart.ViewXY.AddRainbowAxis();

        var series = new PointLineSeries(chart.ViewXY, chart.ViewXY.XAxes[0], chart.ViewXY.YAxes[0]);
        chart.ViewXY.PointLineSeries.Add(series);

        chart.EndUpdate();
    }
}
