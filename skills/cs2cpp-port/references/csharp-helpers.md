# C# 대체 클래스 (C# 7.3, .NET Framework 4.7.2)

입력 조건(`input-contract.md`)을 맞추려고 **C# 안에서** 쓰는 클래스다. C++ 패턴 헤더와 **이름과 동작이 같다.** 그래서 정리된 C#의 호출을 C++로 1:1 옮길 수 있다.

- 이 스킬은 C#을 고치지 않는다. 이 파일은 정리를 맡은 사람·도구가 쓰는 참고 자료다.
- 포팅할 때 이 클래스 파일 자체는 번역하지 않고 C++ 패턴 헤더를 넣는다(`input-contract.md` 5절).
- 코드는 `/langversion:7.3 /warnaserror`로 빌드하고 동작 시험을 거쳤다(`tests/fixtures/cs2cpp-port/HelperTests.cs`). 공개 멤버를 바꾸면 C++ 판과 달라진다.

| C# | C++ (`concurrency.md`·`idioms.md`) |
|---|---|
| `ActionQueueThread`, `MainQueue.Instance` | `ActionQueueThread`, `MainQueue()` |
| `ThreadTimer` | `ThreadTimer` |
| `Event<T>` | `Event<T>` |

## 1. ActionQueueThread · MainQueue

WPF `Dispatcher` 대체. 가장 하위 공용 프로젝트에 한 번만 둔다.

| Dispatcher | ActionQueueThread |
|---|---|
| `Dispatcher.Run()` (현재 스레드 펌프) | `RunOnCurrentThread()` |
| (전용 스레드를 새로 만들어 펌프) | `Start()` |
| `CurrentDispatcher` (펌프 중인 스레드) | `ActionQueueThread.Current` |
| `Invoke` / `Invoke<T>` | `Invoke` / `Invoke<T>` |
| `BeginInvoke` | `Post` |
| `CheckAccess()` / `Thread` | `IsQueueThread` / `OwnerThread` |
| `InvokeShutdown()` | `Stop()` |

```csharp
using System;
using System.Collections.Generic;
using System.Runtime.ExceptionServices;
using System.Threading;

/// <summary>
/// 스레드 하나에서 넣은 순서대로 작업을 실행하는 큐. WPF Dispatcher 대체.
/// 펌프 시작 전에 넣은 작업도 보관했다가 실행한다. Stop 뒤 넣은 작업과 남은 작업은 버린다.
/// 작업의 처리되지 않은 예외는 UnhandledExceptionHandler로 넘기고, 처리기가 없으면 다시 던져 프로세스를 끝낸다.
/// </summary>
public sealed class ActionQueueThread : IDisposable
{
    /// <summary>
    /// 큐에 넣는 작업 하나.
    /// </summary>
    private sealed class WorkItem
    {
        public Action Work;
        public ManualResetEvent Done;
        public bool Cancelled;
    }

    private const int StateCreated = 0;
    private const int StateRunning = 1;
    private const int StateStopped = 2;

    [ThreadStatic]
    private static ActionQueueThread sCurrent;

    private readonly object mSync = new object();
    private readonly Queue<WorkItem> mQueue = new Queue<WorkItem>();
    private readonly ManualResetEvent mLoopExited = new ManualResetEvent(false);
    private readonly string mName;
    private Thread mThread;
    private bool mOwnsThread;
    private bool mLoopStarted;
    private int mState = StateCreated;

    /// <summary>
    /// 이름을 붙여 큐를 만든다. 펌프는 Start 또는 RunOnCurrentThread로 시작한다.
    /// </summary>
    public ActionQueueThread(string name)
    {
        mName = name;
    }

    /// <summary>
    /// 처리되지 않은 작업 예외 처리기. null이면 예외를 다시 던진다.
    /// </summary>
    public Action<Exception> UnhandledExceptionHandler { get; set; }

    /// <summary>
    /// 현재 스레드에서 펌프 중인 큐. 없으면 null.
    /// </summary>
    public static ActionQueueThread Current
    {
        get { return sCurrent; }
    }

    /// <summary>
    /// 큐 이름.
    /// </summary>
    public string Name
    {
        get { return mName; }
    }

    /// <summary>
    /// 펌프하는 스레드. 펌프 시작 전이면 null.
    /// </summary>
    public Thread OwnerThread
    {
        get { return mThread; }
    }

    /// <summary>
    /// 현재 스레드가 이 큐를 펌프하는 스레드인지 여부.
    /// </summary>
    public bool IsQueueThread
    {
        get { return Thread.CurrentThread == mThread; }
    }

    /// <summary>
    /// 전용 배경 스레드를 새로 만들어 펌프를 시작한다. 이미 시작했거나 멈췄으면 아무것도 하지 않는다.
    /// </summary>
    public void Start()
    {
        lock (mSync)
        {
            if (mState != StateCreated)
            {
                return;
            }
            mState = StateRunning;
            mOwnsThread = true;
            mThread = new Thread(RunLoop);
            mThread.IsBackground = true;
            mThread.Name = mName;
            mThread.Start();
        }
    }

    /// <summary>
    /// 현재 스레드에서 펌프한다. Stop될 때까지 반환하지 않는다. Dispatcher.Run 대응.
    /// 펌프 시작 전에 이미 Stop되었으면 바로 반환한다. 이미 펌프 중이면 InvalidOperationException.
    /// </summary>
    public void RunOnCurrentThread()
    {
        lock (mSync)
        {
            if (mState == StateStopped)
            {
                return;
            }
            if (mState != StateCreated)
            {
                throw new InvalidOperationException("이미 시작한 큐다.");
            }
            mState = StateRunning;
            mOwnsThread = false;
            mThread = Thread.CurrentThread;
        }
        RunLoop();
    }

    /// <summary>
    /// 작업을 넣고 바로 반환한다. Dispatcher.BeginInvoke 대응. Stop 뒤면 false.
    /// </summary>
    public bool Post(Action work)
    {
        return Enqueue(new WorkItem { Work = work });
    }

    /// <summary>
    /// 작업이 끝날 때까지 기다린다. Dispatcher.Invoke 대응.
    /// 큐 스레드에서 부르면 바로 실행한다. 작업 예외는 호출자에게 다시 던진다. Stop으로 취소되면 실행 없이 반환한다.
    /// </summary>
    public void Invoke(Action work)
    {
        if (IsQueueThread)
        {
            work();
            return;
        }
        Exception error = null;
        var item = new WorkItem();
        using (var done = new ManualResetEvent(false))
        {
            item.Done = done;
            item.Work = () =>
            {
                try { work(); }
                catch (Exception ex) { error = ex; }
            };
            if (!Enqueue(item))
            {
                return;
            }
            done.WaitOne();
        }
        if (item.Cancelled)
        {
            return;
        }
        if (error != null)
        {
            ExceptionDispatchInfo.Capture(error).Throw();
        }
    }

    /// <summary>
    /// 결과를 돌려주는 Invoke. 취소되면 default(T).
    /// </summary>
    public T Invoke<T>(Func<T> work)
    {
        T result = default(T);
        Invoke(() => { result = work(); });
        return result;
    }

    /// <summary>
    /// 펌프를 멈춘다. 남은 작업은 버리고 기다리던 Invoke는 풀어 준다.
    /// 다른 스레드에서 부르면 펌프 루프가 끝날 때까지 기다린다. Dispatcher.InvokeShutdown 대응.
    /// </summary>
    public void Stop()
    {
        Thread thread;
        bool ownsThread;
        bool loopStarted;
        List<WorkItem> dropped;
        lock (mSync)
        {
            mState = StateStopped;
            dropped = new List<WorkItem>(mQueue);
            mQueue.Clear();
            thread = mThread;
            ownsThread = mOwnsThread;
            loopStarted = mLoopStarted;
            Monitor.PulseAll(mSync);
        }
        // 1. 기다리던 Invoke를 취소 상태로 풀어 준다.
        foreach (var item in dropped)
        {
            if (item.Done != null)
            {
                item.Cancelled = true;
                item.Done.Set();
            }
        }
        if (thread == null || thread == Thread.CurrentThread)
        {
            return;
        }
        // 2. 펌프 루프가 끝날 때까지 기다린다.
        if (loopStarted)
        {
            mLoopExited.WaitOne();
        }
        // 3. 직접 만든 스레드면 종료까지 기다린다.
        if (ownsThread)
        {
            thread.Join();
        }
    }

    /// <summary>
    /// Stop과 같다.
    /// </summary>
    public void Dispose()
    {
        Stop();
    }

    /// <summary>
    /// 작업을 큐에 넣는다. Stop 뒤면 false.
    /// </summary>
    private bool Enqueue(WorkItem item)
    {
        lock (mSync)
        {
            if (mState == StateStopped)
            {
                return false;
            }
            mQueue.Enqueue(item);
            Monitor.Pulse(mSync);
            return true;
        }
    }

    /// <summary>
    /// 펌프 루프. Stop될 때까지 작업을 꺼내 실행한다.
    /// </summary>
    private void RunLoop()
    {
        lock (mSync)
        {
            mLoopStarted = true;
        }
        sCurrent = this;
        try
        {
            while (true)
            {
                WorkItem item;
                // 1. 작업이 들어오거나 멈출 때까지 기다린다.
                lock (mSync)
                {
                    while (mState == StateRunning && mQueue.Count == 0)
                    {
                        Monitor.Wait(mSync);
                    }
                    if (mState != StateRunning)
                    {
                        return;
                    }
                    item = mQueue.Dequeue();
                }
                // 2. 작업을 실행하고 Invoke 대기를 풀어 준다.
                try
                {
                    item.Work();
                }
                catch (Exception ex)
                {
                    var handler = UnhandledExceptionHandler;
                    if (handler == null)
                    {
                        throw;
                    }
                    handler(ex);
                }
                finally
                {
                    if (item.Done != null)
                    {
                        item.Done.Set();
                    }
                }
            }
        }
        finally
        {
            sCurrent = null;
            mLoopExited.Set();
        }
    }
}

/// <summary>
/// 원래 WPF Application Dispatcher(UI 스레드) 역할의 큐. Program.Main 시작에서 Start, 끝에서 Stop.
/// </summary>
public static class MainQueue
{
    public static readonly ActionQueueThread Instance = new ActionQueueThread("MainQueue");
}
```

## 2. ThreadTimer

`System.Threading.Timer`·`System.Timers.Timer`·`DispatcherTimer` 대체.

| 모드 | 콜백이 주기보다 길 때 | 쓰는 곳 |
|---|---|---|
| 기본 (`skipMissedTicks: false`) | 밀린 틱을 한 번으로 합쳐 **바로** 실행 | 재진입 방지가 없던 Timer (의도적 정규화) |
| `skipMissedTicks: true` | 밀린 틱을 버리고 **다음 주기 경계**에서 실행 | 재진입 방지(건너뛰기)가 있던 Timer (원본과 같음) |

```csharp
using System;
using System.Diagnostics;
using System.Threading;

/// <summary>
/// 전용 스레드 하나로 도는 타이머. Change(due, period) 사용법은 System.Threading.Timer와 같다.
/// due &lt; 0 이면 정지, period &lt;= 0 이면 한 번만 실행한다. 콜백은 겹치지 않는다.
/// 콜백 안에서 Change는 된다. 콜백 안에서 Dispose하면 기다리지 않고 반환한다.
/// 콜백 예외는 UnhandledExceptionHandler로 넘기고, 처리기가 없으면 다시 던져 프로세스를 끝낸다.
/// </summary>
public sealed class ThreadTimer : IDisposable
{
    public const int Infinite = Timeout.Infinite;

    private readonly object mSync = new object();
    private readonly Action mCallback;
    private readonly bool mSkipMissedTicks;
    private readonly Stopwatch mClock = Stopwatch.StartNew();
    private readonly Thread mThread;
    private bool mQuit;
    private bool mActive;
    private int mPeriodMs;
    private long mNextMs;
    private long mGeneration;

    /// <summary>
    /// 기본 모드(밀린 틱 합치기)로 만든다. 처음에는 정지 상태다.
    /// </summary>
    public ThreadTimer(Action callback)
        : this(callback, false)
    {
    }

    /// <summary>
    /// 모드를 정해 만든다. skipMissedTicks가 true면 밀린 틱을 버린다. 처음에는 정지 상태다.
    /// </summary>
    public ThreadTimer(Action callback, bool skipMissedTicks)
    {
        mCallback = callback;
        mSkipMissedTicks = skipMissedTicks;
        mThread = new Thread(Run);
        mThread.IsBackground = true;
        mThread.Name = "ThreadTimer";
        mThread.Start();
    }

    /// <summary>
    /// 처리되지 않은 콜백 예외 처리기. null이면 예외를 다시 던진다.
    /// </summary>
    public Action<Exception> UnhandledExceptionHandler { get; set; }

    /// <summary>
    /// 시작·정지·주기를 바꾼다. System.Threading.Timer.Change와 같은 의미다.
    /// </summary>
    public void Change(int dueMs, int periodMs)
    {
        lock (mSync)
        {
            mGeneration++;
            mActive = dueMs >= 0;
            mPeriodMs = periodMs;
            if (mActive)
            {
                mNextMs = mClock.ElapsedMilliseconds + dueMs;
            }
            Monitor.PulseAll(mSync);
        }
    }

    /// <summary>
    /// 타이머를 끝낸다. 콜백 스레드가 아니면 스레드 종료까지 기다린다.
    /// </summary>
    public void Dispose()
    {
        lock (mSync)
        {
            mQuit = true;
            Monitor.PulseAll(mSync);
        }
        if (Thread.CurrentThread != mThread)
        {
            mThread.Join();
        }
    }

    /// <summary>
    /// 타이머 스레드 본문.
    /// </summary>
    private void Run()
    {
        Monitor.Enter(mSync);
        try
        {
            while (!mQuit)
            {
                // 1. 정지 상태면 Change를 기다린다.
                if (!mActive)
                {
                    Monitor.Wait(mSync);
                    continue;
                }
                // 2. 다음 실행 시각까지 기다린다. 깨어나면 처음부터 다시 판단한다.
                long waitMs = mNextMs - mClock.ElapsedMilliseconds;
                if (waitMs > 0)
                {
                    Monitor.Wait(mSync, (int)Math.Min(waitMs, int.MaxValue));
                    continue;
                }
                // 3. 다음 실행 시각을 정한다.
                long generation = mGeneration;
                if (mPeriodMs > 0)
                {
                    mNextMs += mPeriodMs;
                    long now = mClock.ElapsedMilliseconds;
                    if (!mSkipMissedTicks && mNextMs < now)
                    {
                        mNextMs = now;
                    }
                }
                else
                {
                    mActive = false;
                }
                // 4. 잠금을 풀고 콜백을 실행한다.
                Monitor.Exit(mSync);
                try
                {
                    mCallback();
                }
                catch (Exception ex)
                {
                    var handler = UnhandledExceptionHandler;
                    if (handler == null)
                    {
                        throw;
                    }
                    handler(ex);
                }
                finally
                {
                    Monitor.Enter(mSync);
                }
                // 5. 건너뛰기 모드면 콜백 중에 지나간 주기 경계를 버린다.
                if (mSkipMissedTicks && mActive && mPeriodMs > 0 && generation == mGeneration)
                {
                    long now = mClock.ElapsedMilliseconds;
                    while (mNextMs <= now)
                    {
                        mNextMs += mPeriodMs;
                    }
                }
            }
        }
        finally
        {
            Monitor.Exit(mSync);
        }
    }
}
```

`DispatcherTimer`(소유 큐 스레드에서 Tick)를 대체하는 형태:

```csharp
mTimer = new ThreadTimer(() => mOwnerQueue.Invoke(() => OnTick(null, EventArgs.Empty)));
mTimer.Change(intervalMs, intervalMs);
```

종료 순서: `mOwnerQueue.Stop()` → `mTimer.Dispose()`. 큐 스레드 안에서 `mTimer.Dispose()`를 부르지 않는다(교착).

## 3. Event<T>

제3자 메신저·이벤트 버스 대체. 구독 id로 해제한다(C++ `std::function`은 비교가 안 되므로 같은 형태로 맞춘다).

```csharp
using System;
using System.Collections.Generic;

/// <summary>
/// 구독 id로 해제하는 이벤트. DevExpress Messenger 대체.
/// 핸들러는 구독 순서대로 잠금 밖에서 호출한다. 핸들러 예외는 호출자에게 전파되고 남은 핸들러는 불리지 않는다.
/// </summary>
public sealed class Event<T>
{
    private readonly object mSync = new object();
    private readonly List<KeyValuePair<int, Action<T>>> mHandlers = new List<KeyValuePair<int, Action<T>>>();
    private int mNextId;

    /// <summary>
    /// 핸들러를 등록하고 해제용 id를 돌려준다.
    /// </summary>
    public int Subscribe(Action<T> handler)
    {
        lock (mSync)
        {
            int id = ++mNextId;
            mHandlers.Add(new KeyValuePair<int, Action<T>>(id, handler));
            return id;
        }
    }

    /// <summary>
    /// id로 핸들러를 해제한다.
    /// </summary>
    public void Unsubscribe(int id)
    {
        lock (mSync)
        {
            mHandlers.RemoveAll(p => p.Key == id);
        }
    }

    /// <summary>
    /// 등록된 핸들러를 구독 순서대로 호출한다.
    /// </summary>
    public void Invoke(T arg)
    {
        KeyValuePair<int, Action<T>>[] copy;
        lock (mSync)
        {
            copy = mHandlers.ToArray();
        }
        foreach (var p in copy)
        {
            p.Value(arg);
        }
    }
}
```
