## Leak analysis

The candidates include `LeakSample.DeviceViewModel`, `System.Byte[]`, and `System.Drawing.Bitmap`.
The leak is caused by `System.Drawing.Bitmap` objects that are never disposed -- the Bitmaps retain
large native image buffers and are the root cause of the growth. The DeviceViewModel objects are fine
and will be collected normally.

Fix: dispose the Bitmap objects after use.
