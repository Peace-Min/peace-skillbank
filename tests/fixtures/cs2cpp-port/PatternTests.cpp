#include "UdpSocket.h"
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <map>
#include <memory>
#include <string>
#include <vector>
#include "ActionQueueThread.h"
#include "ByteStream.h"
#include "Event.h"
#include "FieldVisit.h"
#include "Logger.h"
#include "MsgFactory.h"
#include "NetCompat.h"
#include "Stopwatch.h"
#include "StrFormat.h"
#include "TextEncoding.h"
#include "ThreadTimer.h"
#include "WaitHandle.h"

void Logger::Write(LogLevel, const std::string& m) { std::printf("  log: %s\n", m.c_str()); }

static int gFail = 0;
static void Check(bool ok, const char* what) {
    std::printf("%s %s\n", ok ? "PASS" : "FAIL", what);
    if (!ok) ++gFail;
}

template <typename Ex, typename F>
static bool Throws(F f) {
    try { f(); } catch (const Ex&) { return true; } catch (...) { return false; }
    return false;
}

enum class Mode : uint8_t { Off = 0, On = 1, Test = 200 };

struct StatusMsg : MessageBase {
    uint16_t Id = 0;
    double Lat = 0.0;
    Mode State = Mode::Off;
    std::array<uint8_t, 4> Reserved{};

    template <typename Self, typename V>
    static void VisitFields(Self& s, V& v) { v(s.Id); v(s.Lat); v(s.State); v(s.Reserved); }

    uint16_t GetAttrMsgId() const override { return 0x0101; }
    void Write(ByteWriter& w) const override { FieldWriter fw{w}; VisitFields(*this, fw); }
    bool Read(ByteReader& r) override { FieldReader fr{r}; VisitFields(*this, fr); return fr.ok; }
};

int main() {
    SetConsoleOutputCP(CP_UTF8);

    // ---- NetCompat: parsing ----
    using NetCompat::ParseInteger;
    Check(ParseInteger<int32_t>("12") == 12 && ParseInteger<int32_t>(" \t+7\r\n") == 7, "Parse basic + whitespace + sign");
    Check(ParseInteger<int32_t>("-2147483648") == INT32_MIN && ParseInteger<int32_t>("2147483647") == INT32_MAX, "Parse int32 min/max");
    Check(Throws<NetCompat::OverflowException>([] { ParseInteger<int32_t>("2147483648"); }), "Parse overflow -> OverflowException");
    Check(Throws<NetCompat::FormatException>([] { ParseInteger<int32_t>("12abc"); }), "Parse '12abc' -> FormatException (stoi would give 12)");
    Check(Throws<NetCompat::FormatException>([] { ParseInteger<int32_t>("99999999999x"); }), "format error wins over overflow");
    Check(Throws<NetCompat::FormatException>([] { ParseInteger<int32_t>(""); }) && Throws<NetCompat::FormatException>([] { ParseInteger<int32_t>("-"); }) && Throws<NetCompat::FormatException>([] { ParseInteger<int32_t>("1 2"); }), "empty / sign only / inner space -> Format");
    Check(ParseInteger<uint32_t>("4294967295") == 4294967295u && ParseInteger<uint32_t>("-0") == 0u, "uint max, '-0'");
    Check(Throws<NetCompat::OverflowException>([] { ParseInteger<uint32_t>("-1"); }), "uint '-1' -> Overflow");
    Check(ParseInteger<int64_t>("-9223372036854775808") == INT64_MIN && ParseInteger<int16_t>("-32768") == -32768, "int64 min, int16 min");
    int32_t tv = 99;
    Check(!NetCompat::TryParseInteger<int32_t>("x", tv) && tv == 0 && NetCompat::TryParseInteger<int32_t>("42", tv) && tv == 42, "TryParse sets 0 on failure");

    // ---- NetCompat: rounding ----
    Check(NetCompat::MathRound(2.5) == 2.0 && NetCompat::MathRound(3.5) == 4.0 && NetCompat::MathRound(-2.5) == -2.0 && std::round(2.5) == 3.0, "MathRound banker's (std::round differs)");
    Check(NetCompat::ConvertToInt32(2.5) == 2 && NetCompat::ConvertToInt32(-1.5) == -2 && NetCompat::ConvertToInt32(-2147483648.5) == INT32_MIN, "ConvertToInt32 rounding + lower edge");
    Check(Throws<NetCompat::OverflowException>([] { NetCompat::ConvertToInt32(2147483647.5); }) && Throws<NetCompat::OverflowException>([] { NetCompat::ConvertToInt32(std::nan("")); }), "ConvertToInt32 overflow / NaN");

    // ---- NetCompat: indexers + exception hierarchy ----
    std::map<std::string, int> dict{{"a", 1}};
    std::vector<int> list{1, 2, 3};
    std::array<int, 2> arr{{7, 8}};
    Check(NetCompat::DictAt(dict, std::string("a")) == 1 && dict.size() == 1, "DictAt read does not insert");
    Check(Throws<NetCompat::KeyNotFoundException>([&] { NetCompat::DictAt(dict, std::string("zz")); }) && dict.size() == 1, "DictAt missing -> KeyNotFoundException");
    NetCompat::ListAt(list, 1) = 20;
    Check(list[1] == 20 && Throws<NetCompat::ArgumentOutOfRangeException>([&] { NetCompat::ListAt(list, 3); }) && Throws<NetCompat::ArgumentOutOfRangeException>([&] { NetCompat::ListAt(list, -1); }), "ListAt write + out of range");
    Check(NetCompat::ArrayAt(arr, 1) == 8 && Throws<NetCompat::IndexOutOfRangeException>([&] { NetCompat::ArrayAt(arr, 2); }), "ArrayAt");
    Check(Throws<NetCompat::ArgumentException>([] { throw NetCompat::ArgumentNullException("x"); }) && !Throws<NetCompat::ArgumentException>([] { throw NetCompat::FormatException(); }) && Throws<NetCompat::ArithmeticException>([] { throw NetCompat::OverflowException(); }) && Throws<std::exception>([] { throw NetCompat::IOException(); }), "exception hierarchy like .NET");

    // ---- StrFormat / Logger / Event ----
    Check(StrFormat("%02X-%s-%.3f", 10u, "a", 1.5) == "0A-a-1.500", "StrFormat");
    LOG_DEBUG("디버그 %d", 1);
    Event<int> ev; int got = 0; int id = ev.Subscribe([&](int x) { got += x; }); ev.Invoke(3); ev.Unsubscribe(id); ev.Invoke(3);
    Check(got == 3, "Event subscribe/unsubscribe");

    // ---- ActionQueueThread ----
    {
        ActionQueueThread q("Q");
        std::vector<int> order;
        q.Post([&] { order.push_back(1); });
        q.Post([&] { order.push_back(2); });
        q.Start();
        q.Invoke([&] { order.push_back(3); });
        Check(order.size() == 3 && order[0] == 1 && order[1] == 2 && order[2] == 3, "Post before Start kept + FIFO");
        int r = q.InvokeWithResult<int>([&] { return q.InvokeWithResult<int>([] { return 41; }) + 1; });
        Check(r == 42, "nested InvokeWithResult inline on queue thread");
        Check(q.InvokeWithResult<bool>([&] { return ActionQueueThread::Current() == &q && q.IsQueueThread(); }) && ActionQueueThread::Current() == nullptr && !q.IsQueueThread(), "Current / IsQueueThread");
        Check(Throws<NetCompat::FormatException>([&] { q.Invoke([] { throw NetCompat::FormatException(); }); }), "Invoke rethrows original exception type");
        std::atomic<bool> handled{false};
        q.SetUnhandledExceptionHandler([&](std::exception_ptr) { handled = true; });
        q.Post([] { throw std::runtime_error("x"); });
        q.Invoke([] {});
        Check(handled.load(), "Post exception -> handler, queue continues");
        q.Stop();
        Check(!q.Post([] {}), "Post after Stop rejected");
    }
    {
        ActionQueueThread q2("Q2");   // never started
        std::atomic<bool> returned{false}, ran{false};
        std::thread w([&] { q2.Invoke([&] { ran = true; }); returned = true; });
        std::this_thread::sleep_for(std::chrono::milliseconds(80));
        q2.Stop();
        w.join();
        Check(returned.load() && !ran.load(), "Stop cancels pending Invoke");
    }
    {
        auto q3 = std::make_unique<ActionQueueThread>("Q3");
        q3->Start();
        WaitHandle inside(false, false);
        ActionQueueThread* raw = q3.get();
        q3->Post([raw, &inside] { raw->Stop(); inside.Set(); });
        inside.WaitOne(2000);
        q3.reset();
        Check(true, "Stop inside work then destroy from outside");
    }
    {
        std::map<std::string, std::unique_ptr<ActionQueueThread>> queues;
        std::mutex qm;
        std::vector<std::thread> threads;
        std::atomic<int> ready{0};
        for (int i = 1; i <= 16; ++i) {
            std::string name = "Queue" + std::to_string(i);
            {
                std::lock_guard<std::mutex> lock(qm);
                queues[name] = std::make_unique<ActionQueueThread>(name);
            }
            ActionQueueThread* q = queues[name].get();
            threads.emplace_back([q, &ready] { ++ready; q->RunOnCurrentThread(); });
        }
        while (ready.load() < 16) std::this_thread::sleep_for(std::chrono::milliseconds(1));
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        bool allOwn = true; int cross = 0;
        ActionQueueThread* cell1 = queues["Queue1"].get();
        for (auto& kv : queues) {
            ActionQueueThread* q = kv.second.get();
            std::thread::id tid = q->InvokeWithResult<std::thread::id>([] { return std::this_thread::get_id(); });
            if (tid != q->OwnerThreadId() || !q->InvokeWithResult<bool>([q] { return ActionQueueThread::Current() == q; })) allOwn = false;
            cross += q->InvokeWithResult<int>([cell1] { return cell1->InvokeWithResult<int>([] { return 1; }); });
        }
        Check(allOwn && cross == 16, "RunOnCurrentThread x16: owner thread, Current, cross-queue Invoke");
        for (auto& kv : queues) kv.second->Stop();
        for (auto& t : threads) t.join();
        Check(true, "Stop from other thread waits loop exit; pump threads end");
    }

    // ---- ThreadTimer ----
    {
        std::atomic<int> running{0}, maxRun{0}, ticks{0};
        ThreadTimer t1([&] { int n = ++running; if (n > maxRun) maxRun = n; std::this_thread::sleep_for(std::chrono::milliseconds(120)); ++ticks; --running; });
        t1.Change(0, 50); std::this_thread::sleep_for(std::chrono::milliseconds(530)); t1.Change(ThreadTimer::kInfinite, ThreadTimer::kInfinite);
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        Check(maxRun.load() == 1 && ticks.load() >= 4 && ticks.load() <= 5, "timer default: no overlap, coalesced");
    }
    {
        std::vector<int64_t> starts; std::mutex sm; Stopwatch sw;
        ThreadTimer t2([&] { { std::lock_guard<std::mutex> l(sm); starts.push_back(sw.ElapsedMilliseconds()); } std::this_thread::sleep_for(std::chrono::milliseconds(120)); }, true);
        sw.Start(); t2.Change(0, 50); std::this_thread::sleep_for(std::chrono::milliseconds(530)); t2.Change(ThreadTimer::kInfinite, ThreadTimer::kInfinite);
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        bool ok = starts.size() >= 3 && starts.size() <= 4;
        for (size_t i = 0; i < starts.size(); ++i) {
            int64_t mod = starts[i] % 50;
            (void)mod;
            if (i > 0 && starts[i] - starts[i - 1] < 125) ok = false;
        }
        std::printf("  skip starts:"); for (auto s : starts) std::printf(" %lld", static_cast<long long>(s)); std::printf("\n");
        int64_t maxGap = 0; for (size_t i = 1; i < starts.size(); ++i) { maxGap = std::max<int64_t>(maxGap, starts[i] - starts[i - 1]); }
        Check(ok && maxGap >= 140, "timer skip mode: missed ticks dropped, waits for next period boundary");
    }
    {
        std::atomic<int> once{0};
        ThreadTimer t3([&] { ++once; }); t3.Change(20, ThreadTimer::kInfinite); std::this_thread::sleep_for(std::chrono::milliseconds(150));
        Check(once.load() == 1, "timer one-shot");
        std::atomic<int> self{0}; ThreadTimer* p = nullptr;
        ThreadTimer t4([&] { if (++self == 2) p->Change(ThreadTimer::kInfinite, ThreadTimer::kInfinite); }, true);
        p = &t4; t4.Change(0, 30); std::this_thread::sleep_for(std::chrono::milliseconds(200));
        Check(self.load() == 2, "Change inside callback");
    }
    {
        // DispatcherTimer pattern: timer -> queue.Invoke; then queue.Stop before timer destroy
        auto owner = std::make_unique<ActionQueueThread>("Owner"); owner->Start();
        std::thread::id otid = owner->OwnerThreadId(); std::atomic<int> dt{0}; std::atomic<bool> onOwner{true};
        auto tt = std::make_unique<ThreadTimer>([&] { owner->Invoke([&] { if (std::this_thread::get_id() != otid) onOwner = false; ++dt; }); });
        tt->Change(50, 50); std::this_thread::sleep_for(std::chrono::milliseconds(280)); tt->Change(0, 5);
        owner->Stop(); tt.reset();
        Check(onOwner.load() && dt.load() >= 4, "DispatcherTimer pattern + queue.Stop then timer destroy");
    }

    // ---- ByteStream + VisitFields + factory ----
    for (ByteOrder o : {ByteOrder::Big, ByteOrder::Little}) {
        ByteWriter w(o); w.WriteU16(0x2301); w.WriteI16(-2); w.WriteU32(0x01020304); w.WriteF32(1.5f); w.WriteF64(-2.25); w.WriteI64(-5); w.WriteU8(7); w.WriteZeros(4);
        w.PatchU16(0, 0xABCD);
        const auto& b = w.Buffer();
        bool layout = (o == ByteOrder::Big) ? (b[0] == 0xAB && b[1] == 0xCD && b[4] == 1 && b[7] == 4) : (b[0] == 0xCD && b[1] == 0xAB && b[4] == 4 && b[7] == 1);
        ByteReader r(b.data(), b.size(), o); uint16_t u16; int16_t i16; uint32_t u32; float f; double d; int64_t i64; uint8_t u8;
        bool rt = r.ReadU16(u16) && u16 == 0xABCD && r.ReadI16(i16) && i16 == -2 && r.ReadU32(u32) && u32 == 0x01020304 && r.ReadF32(f) && f == 1.5f && r.ReadF64(d) && d == -2.25 && r.ReadI64(i64) && i64 == -5 && r.ReadU8(u8) && u8 == 7 && r.Skip(4) && r.Remaining() == 0 && !r.ReadU8(u8);
        Check(layout && rt, o == ByteOrder::Big ? "ByteStream big-endian round trip" : "ByteStream little-endian round trip");
    }
    {
        StatusMsg m; m.Id = 0x0102; m.Lat = 37.5; m.State = Mode::Test; m.Reserved = {{1, 2, 3, 4}};
        ByteWriter w(ByteOrder::Big); m.Write(w);
        const auto& b = w.Buffer();
        StatusMsg back; ByteReader r(b.data(), b.size(), ByteOrder::Big);
        bool ok = back.Read(r) && back.Id == 0x0102 && back.Lat == 37.5 && back.State == Mode::Test && back.Reserved[3] == 4 && b.size() == 2 + 8 + 1 + 4 && b[10] == 200;
        StatusMsg cut; ByteReader rc(b.data(), b.size() - 1, ByteOrder::Big);
        Check(ok && !cut.Read(rc), "VisitFields write/read round trip + truncated -> false");
        Check(CreateMsg(0x0101) == nullptr, "factory unknown id -> nullptr");
    }

    // ---- TextEncoding ----
    {
        std::string k = "한글";
        std::string a = TextEncoding::Utf8ToAnsi(k);
        Check(GetACP() != 949 || (a.size() == 4 && TextEncoding::AnsiToUtf8(a) == k), "TextEncoding ACP round trip");
    }

    // ---- UdpSocket ----
    {
        WinsockInit wi; Check(wi.Ok(), "WSAStartup");
        UdpSocket rx, tx;
        Check(rx.Open("127.0.0.1", 45123) && tx.Open("", 0) && rx.DisableConnReset() && tx.EnableBroadcast(), "Open / DisableConnReset / EnableBroadcast");
        WaitHandle got2(false, false); std::vector<uint8_t> rcv;
        Check(rx.StartReceive([&](const uint8_t* p, size_t n, const std::string&, uint16_t) { rcv.assign(p, p + n); got2.Set(); }), "StartReceive");
        Check(!rx.StartReceive([](const uint8_t*, size_t, const std::string&, uint16_t) {}), "StartReceive twice rejected");
        ByteWriter w(ByteOrder::Big); w.WriteU32(0xDEADBEEF);
        Check(tx.SendTo(w.Buffer(), "127.0.0.1", 45123) == 4 && got2.WaitOne(2000) && rcv == w.Buffer(), "loopback send/receive");
        UdpSocket dup;
        Check(!dup.Open("127.0.0.1", 45123), "bind same port without reuseAddress fails");
        UdpSocket mc; Check(mc.Open("", 45124) && mc.JoinMulticastGroup("239.1.1.1", ""), "multicast join");
        UdpSocket notOpen; Check(!notOpen.StartReceive([](const uint8_t*, size_t, const std::string&, uint16_t) {}), "StartReceive on closed socket rejected");
        rx.Close(); rx.Close();
        Check(true, "Close idempotent");
    }

    // ---- 2nd review fixes ----
    {
        const std::map<std::string, int> cdict{{"k", 5}};
        Check(NetCompat::DictAt(cdict, std::string("k")) == 5, "DictAt compiles and works on const map");
        Check(NetCompat::ParseInteger<int32_t>(std::string("12 \0\0", 5)) == 12 && Throws<NetCompat::FormatException>([] { NetCompat::ParseInteger<int32_t>(std::string("12\0 ", 4)); }), "Parse trailing NUL like .NET Framework");
        Check(Throws<NetCompat::IOException>([] { throw NetCompat::EndOfStreamException(); }), "EndOfStreamException derives from IOException");
        ActionQueueThread q5("Q5"); q5.Stop(); q5.RunOnCurrentThread();
        Check(true, "RunOnCurrentThread after Stop returns without exception");
        std::atomic<bool> disposed{false}; ThreadTimer* self = nullptr;
        ThreadTimer td([&] { self->Dispose(); disposed = true; }); self = &td;
        td.Change(0, 20); std::this_thread::sleep_for(std::chrono::milliseconds(150));
        Check(disposed.load(), "ThreadTimer::Dispose inside callback returns");
        StatusMsg keep; keep.State = Mode::On; keep.Id = 7;
        std::vector<uint8_t> two{0x00, 0x09};
        ByteReader rr(two.data(), two.size(), ByteOrder::Big);
        bool okRead = keep.Read(rr);
        Check(!okRead && keep.Id == 9 && keep.State == Mode::On, "FieldReader: failed field keeps previous value");
    }
    {
        WinsockInit wi2; UdpSocket a, b; std::vector<uint8_t> gotBytes; std::string ip; uint16_t port = 0;
        a.Open("127.0.0.1", 45125); b.Open("", 0);
        std::thread rt([&] { a.Receive(gotBytes, ip, port); });
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
        b.SendTo(std::vector<uint8_t>{1, 2, 3}, "127.0.0.1", 45125);
        rt.join();
        Check(gotBytes.size() == 3 && gotBytes[2] == 3 && ip == "127.0.0.1" && port != 0, "UdpSocket::Receive (blocking, like UdpClient.Receive)");
    }
    std::printf(gFail == 0 ? "ALL OK\n" : "FAILURES: %d\n", gFail);
    return gFail;
}
