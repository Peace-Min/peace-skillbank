## Leak analysis (from HeapStat)

The managed heap grew from about 1 MB to about 20 MB between the two snapshots. The dominant growth is
`LeakSample.DeviceViewModel` (+8,990 instances) plus the `System.Byte[]` buffers those objects appear to
own. A dictionary of DeviceViewModel also grew somewhat.

From HeapStat alone I cannot tell WHAT keeps these objects alive -- it lists only type counts and sizes,
not references or roots. They are probably collected in some dictionary or list. It may also be that
event handlers are retaining them, since `+=` subscriptions that are never removed are a common WPF leak
and would keep the objects alive.

To go further, capture reference paths to the GC roots or check for event-handler subscriptions.
