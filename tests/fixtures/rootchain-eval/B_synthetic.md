## Leak analysis (from HeapStat + reference-chain evidence)

`LeakSample.DeviceViewModel` is leaking (+8,990 instances). The reference-chain evidence shows exactly
why each instance is still alive:

1. Static-cache path (8000 objects): a static `DeviceManager` holds a `Dictionary<int,DeviceViewModel>`
   that is never cleared, so every DeviceViewModel stays reachable. The GC root is a StrongHandle into
   the runtime static array -- `StrongHandle -> Object[] -> DeviceManager -> Dictionary -> DeviceViewModel`
   -- i.e. a sticky/static root, not a transient stack reference.
2. Timer path (1000 objects): a `TimerQueueTimer` keeps a `TimerHolder` alive, and its
   `List<DeviceViewModel>` retains the remaining instances --
   `TimerQueue -> TimerQueueTimer -> TimerHolder -> List -> DeviceViewModel`.

Fix:
- Clear/evict the static `DeviceManager` dictionary when devices go away (or bound its size and unregister
  removed entries), so the cache stops holding DeviceViewModel forever.
- Dispose/stop the `Timer` so the `TimerHolder` and its `List` are released.
