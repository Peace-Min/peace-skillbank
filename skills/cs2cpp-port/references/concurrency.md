# 스레드·큐·타이머·동기화

목차: 1. ActionQueueThread · 2. ThreadTimer · 3. WaitHandle · 4. lock·Interlocked·Monitor · 5. Stopwatch·시각

아래 클래스는 **가장 하위 공용 프로젝트에 한 번만** 둔다. C# 대체 클래스(`csharp-helpers.md`)와 **이름·동작이 같다.** 정리된 C#의 호출을 아래 표대로 1:1로 옮긴다. C# 대체 클래스 파일 자체는 번역하지 않고 이 헤더를 넣는다.

## 1. ActionQueueThread (C# `ActionQueueThread`, WPF Dispatcher 대체)

| 정리된 C# | C++ |
|---|---|
| `new ActionQueueThread("Queue1")` | `std::make_unique<ActionQueueThread>("Queue1")` 또는 값 멤버 |
| `q.Start()` / `q.RunOnCurrentThread()` | `q.Start()` / `q.RunOnCurrentThread()` |
| `q.Post(() => A())` | `q.Post([this] { A(); })` |
| `q.Invoke(() => A())` | `q.Invoke([this] { A(); })` |
| `var r = q.Invoke(() => F())` (`Invoke<T>`) | `auto r = q.InvokeWithResult<T>([this] { return F(); })` — **이름이 다르다.** 같은 이름으로 두면 값을 돌려주는 람다가 `void` 판으로 조용히 넘어간다 |
| `q.IsQueueThread` | `q.IsQueueThread()` |
| `q.OwnerThread` | `q.OwnerThreadId()` (`std::thread::id`) |
| `ActionQueueThread.Current` | `ActionQueueThread::Current()` (없으면 `nullptr`) |
| `q.UnhandledExceptionHandler = e => ...` | `q.SetUnhandledExceptionHandler([](std::exception_ptr e) { ... })` |
| `q.Stop()` / `Dispose()` | `q.Stop()` / 소멸자 |
| `MainQueue.Instance` | `MainQueue()` |

동작 (C# 판과 같음):
- 펌프 시작 전에 넣은 작업도 보관했다가 실행한다. `Stop` 뒤 작업과 남은 작업은 버리고, 기다리던 `Invoke`는 실행 없이 반환한다.
- `Invoke`는 큐 스레드에서 부르면 바로 실행한다. 다른 스레드면 끝날 때까지 기다리고 작업 예외를 호출자에게 다시 던진다.
- 다른 스레드에서 `Stop`하면 펌프 루프가 끝날 때까지 기다리고, `Start`로 만든 스레드면 `join`한다.
- 작업 예외: 처리기가 있으면 넘기고, 없으면 다시 던져 프로세스를 끝낸다(C#과 같음).
- **큐 스레드의 작업 안에서 그 큐 객체를 파괴하지 않는다.** 파괴하면 소멸자가 스레드를 분리해 `terminate`만 막는다.
- 작업은 큐 잠금을 푼 뒤 실행한다. 작업 안에서 같은 큐에 `Post`·`Invoke`해도 교착하지 않는다(`Invoke`는 바로 실행).
- 큐 A의 작업이 B에 `Invoke`하고 B의 작업이 A에 `Invoke`하면 교착한다. C# 판도 같으므로 고치지 않고 보고한다.
- `Post`·타이머 람다의 캡처는 `idioms.md` 3절 "람다 캡처"를 따른다. 표의 `[this]`는 그 조건을 만족할 때만 쓴다.

```cpp
// ActionQueueThread.h
#pragma once
#include <atomic>
#include <condition_variable>
#include <deque>
#include <exception>
#include <functional>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>

#include "TerminateLogger.h"

// C#: csharp-helpers.md 1절 ActionQueueThread와 같은 동작.
class ActionQueueThread {
public:
    explicit ActionQueueThread(std::string name) : mName(std::move(name)) {}

    ~ActionQueueThread() {
        Stop();
        std::lock_guard<std::mutex> join(mJoinMutex);
        if (mThread.joinable()) {
            if (mThread.get_id() == std::this_thread::get_id()) {
                mThread.detach();   // 큐 스레드 안에서 파괴됨(금지 사항). terminate만 막는다
            } else {
                mThread.join();
            }
        }
    }

    ActionQueueThread(const ActionQueueThread&) = delete;
    ActionQueueThread& operator=(const ActionQueueThread&) = delete;

    // 현재 스레드에서 펌프 중인 큐. 없으면 nullptr.
    static ActionQueueThread* Current() { return sCurrent; }

    const std::string& Name() const { return mName; }
    std::thread::id OwnerThreadId() const { return mOwnerId.load(); }
    bool IsQueueThread() const { return mOwnerId.load() == std::this_thread::get_id(); }

    void SetUnhandledExceptionHandler(std::function<void(std::exception_ptr)> handler) {
        std::lock_guard<std::mutex> lock(mMutex);
        mHandler = std::move(handler);
    }

    // 전용 스레드를 만들어 펌프를 시작한다.
    void Start() {
        std::lock_guard<std::mutex> lock(mMutex);
        if (mState != State::Created) {
            return;
        }
        mState = State::Running;
        mOwnsThread = true;
        mThread = std::thread([this] { RunThreadBody([this] { RunLoop(); }); });
        mOwnerId = mThread.get_id();
    }

    // 현재 스레드에서 펌프한다. Stop될 때까지 반환하지 않는다 (C#: Dispatcher.Run).
    void RunOnCurrentThread() {
        {
            std::lock_guard<std::mutex> lock(mMutex);
            if (mState == State::Stopped) {
                return;   // 펌프 시작 전에 이미 Stop됨 (C#과 같음)
            }
            if (mState != State::Created) {
                throw std::logic_error("already started");
            }
            mState = State::Running;
            mOwnsThread = false;
            mOwnerId = std::this_thread::get_id();
        }
        RunLoop();
    }

    // C#: Post (Dispatcher.BeginInvoke). Stop 뒤면 false.
    bool Post(std::function<void()> work) {
        Item item;
        item.work = std::move(work);
        return Enqueue(std::move(item));
    }

    // C#: Invoke (Dispatcher.Invoke).
    void Invoke(const std::function<void()>& work) {
        if (IsQueueThread()) {
            work();
            return;
        }
        auto state = std::make_shared<InvokeState>();
        Item item;
        item.invoke = state;
        item.work = [work, state]() {
            try {
                work();
            } catch (...) {
                state->error = std::current_exception();
            }
        };
        if (!Enqueue(std::move(item))) {
            return;
        }
        std::unique_lock<std::mutex> lock(state->mutex);
        state->cv.wait(lock, [&state] { return state->done; });
        if (state->cancelled) {
            return;
        }
        if (state->error) {
            std::rethrow_exception(state->error);
        }
    }

    // C#: Invoke<T>(Func<T>). 취소되면 T{}.
    template <typename T>
    T InvokeWithResult(const std::function<T()>& work) {
        T result{};
        Invoke([&result, &work]() { result = work(); });
        return result;
    }

    // C#: Stop (Dispatcher.InvokeShutdown).
    void Stop() {
        std::deque<Item> dropped;
        bool loopStarted = false;
        bool ownsThread = false;
        std::thread::id owner;
        {
            std::lock_guard<std::mutex> lock(mMutex);
            mState = State::Stopped;
            dropped.swap(mQueue);
            loopStarted = mLoopStarted;
            ownsThread = mOwnsThread;
            owner = mOwnerId.load();
        }
        mWake.notify_all();
        for (auto& item : dropped) {
            if (item.invoke) {
                std::lock_guard<std::mutex> lock(item.invoke->mutex);
                item.invoke->cancelled = true;
                item.invoke->done = true;
                item.invoke->cv.notify_all();
            }
        }
        if (owner == std::thread::id() || owner == std::this_thread::get_id()) {
            return;
        }
        if (loopStarted) {
            std::unique_lock<std::mutex> lock(mMutex);
            mLoopExitCv.wait(lock, [this] { return mLoopExited; });
        }
        if (ownsThread) {
            std::lock_guard<std::mutex> join(mJoinMutex);
            if (mThread.joinable()) {
                mThread.join();
            }
        }
    }

private:
    enum class State { Created, Running, Stopped };

    struct InvokeState {
        std::mutex mutex;
        std::condition_variable cv;
        bool done = false;
        bool cancelled = false;
        std::exception_ptr error;
    };

    struct Item {
        std::function<void()> work;
        std::shared_ptr<InvokeState> invoke;
    };

    bool Enqueue(Item item) {
        {
            std::lock_guard<std::mutex> lock(mMutex);
            if (mState == State::Stopped) {
                return false;
            }
            mQueue.push_back(std::move(item));
        }
        mWake.notify_one();
        return true;
    }

    static void Complete(const Item& item) {
        if (item.invoke) {
            std::lock_guard<std::mutex> lock(item.invoke->mutex);
            item.invoke->done = true;
            item.invoke->cv.notify_all();
        }
    }

    void RunLoop() {
        {
            std::lock_guard<std::mutex> lock(mMutex);
            mLoopStarted = true;
        }
        sCurrent = this;
        struct ExitGuard {
            ActionQueueThread* self;
            ~ExitGuard() {
                sCurrent = nullptr;
                std::lock_guard<std::mutex> lock(self->mMutex);
                self->mLoopExited = true;
                self->mLoopExitCv.notify_all();   // 잠금 안에서 알린다 (대기자가 먼저 파괴하지 않게)
            }
        } exitGuard{this};

        for (;;) {
            Item item;
            {
                std::unique_lock<std::mutex> lock(mMutex);
                mWake.wait(lock, [this] { return mState != State::Running || !mQueue.empty(); });
                if (mState != State::Running) {
                    return;
                }
                item = std::move(mQueue.front());
                mQueue.pop_front();
            }
            try {
                item.work();
            } catch (...) {
                std::function<void(std::exception_ptr)> handler;
                {
                    std::lock_guard<std::mutex> lock(mMutex);
                    handler = mHandler;
                }
                if (!handler) {
                    Complete(item);
                    throw;   // C#과 같이 처리되지 않은 예외로 프로세스를 끝낸다
                }
                handler(std::current_exception());
            }
            Complete(item);
        }
    }

    inline static thread_local ActionQueueThread* sCurrent = nullptr;

    const std::string mName;
    std::mutex mMutex;
    std::condition_variable mWake;
    std::condition_variable mLoopExitCv;
    std::deque<Item> mQueue;
    std::function<void(std::exception_ptr)> mHandler;
    State mState = State::Created;
    bool mOwnsThread = false;
    bool mLoopStarted = false;
    bool mLoopExited = false;
    std::atomic<std::thread::id> mOwnerId{std::thread::id()};
    std::mutex mJoinMutex;
    std::thread mThread;
};

// C#: MainQueue.Instance
inline ActionQueueThread& MainQueue() {
    static ActionQueueThread queue("MainQueue");
    return queue;
}
```

## 2. ThreadTimer (C# `ThreadTimer`)

| 정리된 C# | C++ |
|---|---|
| `new ThreadTimer(cb)` | `ThreadTimer t(cb);` (또는 `std::make_unique`) |
| `new ThreadTimer(cb, true)` (건너뛰기 모드) | `ThreadTimer t(cb, true);` |
| `ThreadTimer.Infinite` | `ThreadTimer::kInfinite` |
| `t.Change(due, period)` | `t.Change(due, period)` |
| `t.UnhandledExceptionHandler = ...` | `t.SetUnhandledExceptionHandler(...)` |
| `t.Dispose()` | `t.Dispose()` (콜백 안에서도 된다). 객체 파괴는 콜백 밖에서 |

동작: 전용 스레드 하나, 콜백은 겹치지 않는다. 기본 모드는 밀린 틱을 합쳐 바로 실행하고, 건너뛰기 모드는 밀린 틱을 버리고 다음 주기 경계에서 실행한다. 콜백 안에서 `Change`는 되고, 자기 타이머 파괴는 금지(join 교착).

```cpp
// ThreadTimer.h
#pragma once
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <exception>
#include <functional>
#include <mutex>
#include <thread>
#include <utility>

#include "TerminateLogger.h"

// C#: csharp-helpers.md 2절 ThreadTimer와 같은 동작.
class ThreadTimer {
public:
    static constexpr int32_t kInfinite = -1;   // C#: Timeout.Infinite

    explicit ThreadTimer(std::function<void()> callback, bool skipMissedTicks = false)
        : mCallback(std::move(callback)), mSkipMissedTicks(skipMissedTicks) {
        mThread = std::thread([this] { RunThreadBody([this] { Run(); }); });
    }

    // C#: Dispose(). 콜백 스레드에서 부르면 기다리지 않고 반환한다.
    void Dispose() {
        {
            std::lock_guard<std::mutex> lock(mMutex);
            mQuit = true;
        }
        mCv.notify_all();
        std::lock_guard<std::mutex> join(mJoinMutex);
        if (mThread.joinable() && mThread.get_id() != std::this_thread::get_id()) {
            mThread.join();
        }
    }

    // 콜백 안에서 이 객체를 파괴하는 것은 금지(Dispose는 된다).
    ~ThreadTimer() { Dispose(); }

    ThreadTimer(const ThreadTimer&) = delete;
    ThreadTimer& operator=(const ThreadTimer&) = delete;

    void SetUnhandledExceptionHandler(std::function<void(std::exception_ptr)> handler) {
        std::lock_guard<std::mutex> lock(mMutex);
        mHandler = std::move(handler);
    }

    // C#: Change(dueTime, period). due < 0 정지, period <= 0 한 번만.
    void Change(int32_t dueMs, int32_t periodMs) {
        {
            std::lock_guard<std::mutex> lock(mMutex);
            ++mGeneration;
            mActive = (dueMs >= 0);
            mPeriodMs = periodMs;
            if (mActive) {
                mNext = Clock::now() + std::chrono::milliseconds(dueMs);
            }
        }
        mCv.notify_all();
    }

private:
    using Clock = std::chrono::steady_clock;

    void Run() {
        std::unique_lock<std::mutex> lock(mMutex);
        while (!mQuit) {
            if (!mActive) {
                mCv.wait(lock);
                continue;
            }
            const uint64_t gen = mGeneration;
            const bool changed = mCv.wait_until(lock, mNext, [this, gen] {
                return mQuit || mGeneration != gen;
            });
            if (changed) {
                continue;
            }
            if (mPeriodMs > 0) {
                mNext += std::chrono::milliseconds(mPeriodMs);
                const auto now = Clock::now();
                if (!mSkipMissedTicks && mNext < now) {
                    mNext = now;
                }
            } else {
                mActive = false;
            }
            std::function<void(std::exception_ptr)> handler = mHandler;
            lock.unlock();
            try {
                mCallback();
            } catch (...) {
                if (!handler) {
                    throw;   // C#과 같이 처리되지 않은 예외로 프로세스를 끝낸다
                }
                handler(std::current_exception());
            }
            lock.lock();
            if (mSkipMissedTicks && mActive && mPeriodMs > 0 && gen == mGeneration) {
                const auto now = Clock::now();
                while (mNext <= now) {
                    mNext += std::chrono::milliseconds(mPeriodMs);
                }
            }
        }
    }

    std::function<void()> mCallback;
    const bool mSkipMissedTicks;
    std::function<void(std::exception_ptr)> mHandler;
    std::mutex mMutex;
    std::condition_variable mCv;
    bool mQuit = false;
    bool mActive = false;
    int32_t mPeriodMs = 0;
    uint64_t mGeneration = 0;
    Clock::time_point mNext;
    std::mutex mJoinMutex;
    std::thread mThread;   // 마지막 멤버 (다른 멤버 초기화 후 시작)
};
```

## 3. WaitHandle (ManualResetEvent / AutoResetEvent / EventWaitHandle)

```cpp
// WaitHandle.h
#pragma once
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <mutex>

class WaitHandle {
public:
    // autoReset=true: AutoResetEvent, false: ManualResetEvent
    explicit WaitHandle(bool initialState, bool autoReset)
        : mSignaled(initialState), mAutoReset(autoReset) {}

    void Set() {
        {
            std::lock_guard<std::mutex> lock(mMutex);
            mSignaled = true;
        }
        if (mAutoReset) {
            mCv.notify_one();
        } else {
            mCv.notify_all();
        }
    }

    void Reset() {
        std::lock_guard<std::mutex> lock(mMutex);
        mSignaled = false;
    }

    // C#: WaitOne(). timeoutMs < 0 이면 무한 대기. 신호를 받으면 true
    bool WaitOne(int32_t timeoutMs = -1) {
        std::unique_lock<std::mutex> lock(mMutex);
        bool ok = true;
        if (timeoutMs < 0) {
            mCv.wait(lock, [this] { return mSignaled; });
        } else {
            ok = mCv.wait_for(lock, std::chrono::milliseconds(timeoutMs), [this] { return mSignaled; });
        }
        if (ok && mAutoReset) {
            mSignaled = false;
        }
        return ok;
    }

private:
    std::mutex mMutex;
    std::condition_variable mCv;
    bool mSignaled;
    bool mAutoReset;
};
```

`WaitHandle.WaitAny`/`WaitAll`는 대응 없음 → 원본 사용처를 보고하고 `TODO(PORT)`.

## 4. lock · Interlocked · Monitor · volatile

| C# | C++ | 주의 |
|---|---|---|
| `private readonly object mLock = new object();` | `std::recursive_mutex mLock;` | `const` 붙이지 않음. 항상 `recursive_mutex` (SKILL.md 규칙 14) |
| `lock (mLock) { ... }` | `{ std::lock_guard<std::recursive_mutex> guard(mLock); ... }` | |
| 락 두 개 | `std::scoped_lock guard(mA, mB);` | |
| `Monitor.Wait(mLock)` / `Pulse` / `PulseAll` | `std::condition_variable_any` `wait` / `notify_one` / `notify_all` | 대기 조건을 술어로 함께 옮긴다. `recursive_mutex`를 여러 번 잡은 상태에서 `wait`하면 교착하므로 원본이 중첩 lock 안에서 `Wait`하면 보고 |
| `lock` 안에서 이벤트·콜백 호출 | 그대로 옮기고 보고에 "락 보유 중 콜백" | 교착 위험 |
| `volatile bool mFlag` / `Volatile.Read/Write` | `std::atomic<bool> mFlag{false};` / `load`·`store` | C++ volatile은 동기화가 아니다 |
| `Interlocked.Exchange(ref x, v)` | `x.exchange(v)` (이전 값 반환) | |
| `Interlocked.Read(ref x)` | `x.load()` | |
| `Interlocked.Increment(ref x)` | `++x` (새 값) | |
| `Interlocked.CompareExchange(ref x, value, comparand)` | `T expected = comparand; x.compare_exchange_strong(expected, value); T original = expected;` | **인자 순서와 반환이 다르다** |
| `Thread` + `IsBackground = true` | `std::thread` 멤버 + 종료 플래그 + `join` | `detach` 금지 |
| `Concurrent*` 컬렉션 | `std::recursive_mutex`로 감싼 표준 컬렉션 (`types.md` 4절) | 열거는 잠금 안에서 복사본으로 |

## 5. Stopwatch · 시각

```cpp
// Stopwatch.h
#pragma once
#include <chrono>
#include <cstdint>

class Stopwatch {
public:
    void Start() {
        if (!mRunning) {
            mStart = Clock::now();
            mRunning = true;
        }
    }
    void Stop() {
        if (mRunning) {
            mAccum += Clock::now() - mStart;
            mRunning = false;
        }
    }
    void Reset() {
        mAccum = Clock::duration::zero();
        mRunning = false;
    }
    void Restart() {
        Reset();
        Start();
    }
    bool IsRunning() const { return mRunning; }
    // C#: ElapsedMilliseconds (long)
    int64_t ElapsedMilliseconds() const {
        auto total = mAccum;
        if (mRunning) {
            total += Clock::now() - mStart;
        }
        return std::chrono::duration_cast<std::chrono::milliseconds>(total).count();
    }

private:
    using Clock = std::chrono::steady_clock;
    Clock::time_point mStart;
    Clock::duration mAccum = Clock::duration::zero();
    bool mRunning = false;
};
```

| C# | C++ |
|---|---|
| `Stopwatch.StartNew()` | `Stopwatch sw; sw.Start();` |
| `sw.ElapsedTicks` | **QPC 틱(100ns 아님).** 원본이 `Stopwatch.Frequency`로 나누면 `QueryPerformanceCounter`/`QueryPerformanceFrequency`를 직접 호출해 같은 값으로 |
| `Environment.TickCount` | `static_cast<int32_t>(GetTickCount())` — **int32로 감싸짐**(약 24.9일마다 음수). 원본의 차이 계산을 그대로 옮긴다 |
| QPC 기반 자체 타이머, `timeSetEvent` | Win32를 그대로 호출해 직역 |
