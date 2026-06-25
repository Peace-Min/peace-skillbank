## Leak analysis (from reference-chain evidence)

`LeakSample.DeviceViewModel` is leaking. The reference-chain evidence shows why each instance is retained:

1. A `BitmapCache` holds an `ObservableCollection` that keeps the DeviceViewModel objects alive --
   `Frame -> BitmapCache -> ObservableCollection -> DeviceViewModel`. The root is a Stack reference, so
   these are in-use on the stack.
2. An `EventManager` / `EventHandlerState` keeps an `EventHandlerList` alive that retains the rest.

Fix:
- Dispose the BitmapCache so the ObservableCollection releases the DeviceViewModel.
- Unsubscribe the handlers on the EventManager.
