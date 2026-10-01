// Behaviour tests for the C# replacement classes in skills/cs2cpp-port/references/csharp-helpers.md.
// The same scenarios run against the C++ pattern headers in PatternTests.cpp, so both sides are checked
// for the same contract (queue order, Invoke/Stop semantics, timer modes, Event order).
// Built by tests/cs2cpp-port-fixtures.ps1 with C# 7.3 and warnings as errors; extracted helper code is compiled alongside.
using System;
using System.Collections.Generic;
using System.Threading;

static class HelperTests
{
    static int sFail;

    static void Check(bool c, string what)
    {
        Console.WriteLine((c ? "PASS " : "FAIL ") + what);
        if (!c) sFail++;
    }

    static int Main()
    {
        // ---- ActionQueueThread ----
        var q = new ActionQueueThread("Q");
        var order = new List<int>();
        q.Post(() => order.Add(1));
        q.Post(() => order.Add(2));
        q.Start();
        q.Invoke(() => order.Add(3));
        Check(string.Join(",", order) == "1,2,3", "queue: Post before Start kept + FIFO");
        Check(q.Invoke(() => q.Invoke(() => 41) + 1) == 42, "queue: nested Invoke runs inline");
        Check(q.Invoke(() => ActionQueueThread.Current == q) && ActionQueueThread.Current == null, "queue: Current inside/outside");
        bool caught = false;
        try { q.Invoke(() => { throw new FormatException(); }); } catch (FormatException) { caught = true; }
        Check(caught, "queue: Invoke rethrows original exception type");
        Exception seen = null;
        q.UnhandledExceptionHandler = e => seen = e;
        q.Post(() => { throw new InvalidOperationException(); });
        q.Invoke(() => { });
        Check(seen is InvalidOperationException, "queue: Post exception goes to handler");
        q.Stop();
        Check(!q.Post(() => { }), "queue: Post after Stop rejected");

        var q2 = new ActionQueueThread("Q2");
        bool ret = false, ran = false;
        var w = new Thread(() => { q2.Invoke(() => { ran = true; }); ret = true; });
        w.Start();
        Thread.Sleep(80);
        q2.Stop();
        w.Join(2000);
        Check(ret && !ran, "queue: Stop cancels pending Invoke");

        var q3 = new ActionQueueThread("Q3");
        q3.Start();
        var inside = new ManualResetEvent(false);
        q3.Post(() => { q3.Stop(); inside.Set(); });
        inside.WaitOne(2000);
        q3.Dispose();
        Check(true, "queue: Stop inside work then Dispose");

        var queues = new Dictionary<string, ActionQueueThread>();
        var ready = new CountdownEvent(16);
        var threads = new List<Thread>();
        for (int i = 1; i <= 16; i++)
        {
            string name = "Queue" + i;
            var th = new Thread(() =>
            {
                var d = new ActionQueueThread(name);
                lock (queues) { queues[name] = d; }
                ready.Signal();
                d.RunOnCurrentThread();
            });
            th.IsBackground = true;
            th.Start();
            threads.Add(th);
        }
        ready.Wait();
        bool allOwn = true;
        int cross = 0;
        foreach (var kv in queues)
        {
            var d = kv.Value;
            int tid = d.Invoke(() => Thread.CurrentThread.ManagedThreadId);
            if (tid != d.OwnerThread.ManagedThreadId || !d.Invoke(() => ActionQueueThread.Current == d && d.IsQueueThread)) allOwn = false;
            cross += d.Invoke(() => queues["Queue1"].Invoke(() => 1));
        }
        Check(allOwn && cross == 16, "queue: RunOnCurrentThread x16, owner thread, Current, cross-queue Invoke");
        foreach (var d in queues.Values) d.Stop();
        bool joined = true;
        foreach (var t in threads) { if (!t.Join(2000)) joined = false; }
        Check(joined, "queue: Stop from other thread waits for loop exit");

        var q4 = new ActionQueueThread("Q4");
        q4.Stop();
        var tq = new Thread(() => q4.RunOnCurrentThread());
        tq.Start();
        Check(tq.Join(1000), "queue: RunOnCurrentThread after Stop returns");

        // ---- ThreadTimer ----
        int running = 0, maxRun = 0, coal = 0;
        var t1 = new ThreadTimer(() =>
        {
            int n = Interlocked.Increment(ref running);
            if (n > maxRun) maxRun = n;
            Thread.Sleep(120);
            coal++;
            Interlocked.Decrement(ref running);
        });
        t1.Change(0, 50);
        Thread.Sleep(530);
        t1.Change(ThreadTimer.Infinite, ThreadTimer.Infinite);
        Thread.Sleep(200);
        t1.Dispose();
        Check(maxRun == 1 && coal >= 4 && coal <= 5, "timer: default mode, no overlap, missed ticks coalesced");

        var starts = new List<long>();
        var sw = System.Diagnostics.Stopwatch.StartNew();
        var t2 = new ThreadTimer(() => { lock (starts) { starts.Add(sw.ElapsedMilliseconds); } Thread.Sleep(120); }, true);
        sw.Restart();
        t2.Change(0, 50);
        Thread.Sleep(530);
        t2.Change(ThreadTimer.Infinite, ThreadTimer.Infinite);
        Thread.Sleep(200);
        t2.Dispose();
        long maxGap = 0;
        bool gapsOk = true;
        for (int i = 1; i < starts.Count; i++)
        {
            long gap = starts[i] - starts[i - 1];
            if (gap > maxGap) maxGap = gap;
            if (gap < 125) gapsOk = false;
        }
        Check(starts.Count >= 3 && starts.Count <= 4 && maxGap >= 140 && gapsOk, "timer: skip mode drops missed ticks, next period boundary");

        int once = 0;
        var t3 = new ThreadTimer(() => Interlocked.Increment(ref once));
        t3.Change(20, ThreadTimer.Infinite);
        Thread.Sleep(150);
        Check(once == 1, "timer: one-shot");
        t3.Dispose();

        int self = 0;
        ThreadTimer t4 = null;
        t4 = new ThreadTimer(() => { self++; if (self == 2) t4.Change(ThreadTimer.Infinite, ThreadTimer.Infinite); }, true);
        t4.Change(0, 30);
        Thread.Sleep(200);
        Check(self == 2, "timer: Change inside callback");
        t4.Dispose();

        var disposedInside = new ManualResetEvent(false);
        ThreadTimer t5 = null;
        t5 = new ThreadTimer(() => { t5.Dispose(); disposedInside.Set(); });
        t5.Change(10, ThreadTimer.Infinite);
        Check(disposedInside.WaitOne(2000), "timer: Dispose inside callback returns");

        var mq = new ActionQueueThread("Owner");
        mq.Start();
        int mtid = mq.Invoke(() => Thread.CurrentThread.ManagedThreadId);
        int dt = 0;
        bool onOwner = true;
        var tt = new ThreadTimer(() => mq.Invoke(() => { if (Thread.CurrentThread.ManagedThreadId != mtid) onOwner = false; dt++; }));
        tt.Change(50, 50);
        Thread.Sleep(280);
        tt.Change(0, 5);
        mq.Stop();
        var dth = new Thread(() => tt.Dispose());
        dth.Start();
        Check(onOwner && dt >= 4 && dth.Join(2000), "timer: DispatcherTimer form, queue Stop then Dispose");

        // ---- Event<T> ----
        var ev = new Event<int>();
        var got = new List<string>();
        int a = ev.Subscribe(x => got.Add("a" + x));
        ev.Subscribe(x => got.Add("b" + x));
        ev.Invoke(1);
        ev.Unsubscribe(a);
        ev.Invoke(2);
        Check(string.Join(",", got) == "a1,b1,b2", "event: subscription order + unsubscribe by id");

        Console.WriteLine(sFail == 0 ? "ALL OK" : ("FAILURES: " + sFail));
        return sFail;
    }
}
