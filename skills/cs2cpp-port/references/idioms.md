# 관용구 매핑

## 1. 클래스 구조

| C# | C++ |
|---|---|
| `class Foo : Base, IBar` | `class Foo : public Base, public IBar` |
| `interface IBar { void X(); }` | `class IBar { public: virtual ~IBar() = default; virtual void X() = 0; };` |
| `abstract class` + `abstract void X();` | `virtual void X() = 0;` + 가상 소멸자 |
| `virtual` / `override` | `virtual` / `override` (C++에서도 `override` 반드시 붙임) |
| `sealed` | `final` |
| 기반 클래스 소멸 | 상속되는 모든 클래스는 `virtual ~Base() = default;` |
| `public int Foo { get; set; }` | `int32_t GetFoo() const { return mFoo; }` + `void SetFoo(int32_t v) { mFoo = v; }` + `int32_t mFoo = 0;` |
| `public int Foo { get; private set; }` | getter만 public, setter는 private |
| `public int Foo => mBar * 2;` | `int32_t GetFoo() const { return mBar * 2; }` |
| `readonly` 필드 | **`const`를 붙이지 않고** `// C#: readonly` 주석만 단다. C#은 생성자 본문·`out` 인자로도 대입할 수 있어서 `const`로 옮기면 구조를 바꾸게 된다. 예: `readonly object mLock` → `std::recursive_mutex mLock; // C#: readonly` |
| `const int X = 5;` | `static constexpr int32_t X = 5;` |
| `const string X = "a";` | `static constexpr const char* X = "a";` |
| 가변 `static int sCount;` | `inline static int32_t sCount = 0;` (C++17) |
| `static readonly` 객체 | 함수 안 `static` 지역 변수로 반환 (초기화 순서 문제 방지) |
| `static class Util` | `namespace Util { ... }` 자유 함수 |
| 정적 생성자 | 함수 안 `static` 지역 변수 초기화로 |
| 싱글턴 `Foo.Instance` | `static Foo& Instance() { static Foo s; return s; }` (C++11부터 스레드 안전) + 복사 금지 |
| 복사되면 안 되는 클래스 (스레드·소켓·락 보유) | `Foo(const Foo&) = delete; Foo& operator=(const Foo&) = delete;` |
| `partial class` | 하나의 클래스로 합친다. 원본 파일별로 추적 주석 |
| 중첩 클래스 | 중첩 클래스 그대로 |
| 제네릭 `class Foo<T> where T : class` | `template <typename T> class Foo` (제약 생략) — 정의는 헤더에 |
| 확장 메서드 `static void X(this Foo f)` | 자유 함수 `void X(Foo& f)` |
| `ref int x` / `out int x` | `int32_t& x` |
| 여러 `out` | 그대로 참조 인자들 (구조 변경 금지) |
| 기본 인자 `int x = 0` | 선언(헤더)에만 `int32_t x = 0` |
| 메서드 오버로드 | 그대로 오버로드 |

## 2. 객체 수명과 소유 (GC 대체)

C#은 누가 지우는지 신경 쓰지 않는다. C++에서는 **한 객체에 소유자 하나**를 정한다.

| C#에서의 모습 | C++ |
|---|---|
| 필드에서 `new`해서 끝까지 들고 있는 객체 | 값 멤버 `Foo mFoo;` 또는 `std::unique_ptr<Foo> mpFoo;` |
| 생성자로 받아서 참조만 하는 객체 (주입) | 비소유 포인터 `Foo* mpFoo = nullptr;` 또는 참조 `Foo& mFoo;` — 수명은 소유자가 더 길어야 함. 보고에 수명 관계 적기 |
| 스레드 사이로 넘기는 메시지 객체 | `std::shared_ptr<T>` (큐에 들어간 뒤에도 살아 있어야 하므로) |
| 다형 객체 목록 `List<BaseMsg>` | `std::vector<std::unique_ptr<BaseMsg>>` |
| 역참조(자식→부모) | 비소유 포인터 |
| 여러 곳이 정말 함께 소유 | `std::shared_ptr` — 드문 경우. 순환이면 한쪽 `std::weak_ptr` |
| `IDisposable.Dispose()` | 소멸자. `Dispose()`가 외부에서 명시 호출되면 `Dispose()`도 두고 소멸자에서 호출(두 번 불려도 안전하게) |
| `using (var x = ...) { }` | 블록 안 지역 객체 (RAII) |
| finalizer `~Foo()` | 소멸자 |

`new`/`delete`를 직접 쓰지 않는다. `std::make_unique`, `std::make_shared`만 쓴다.

## 3. 이벤트와 델리게이트

| C# | C++ |
|---|---|
| `Action` / `Action<T>` / `Func<T,R>` | `std::function<void()>` / `std::function<void(T)>` / `std::function<R(T)>` |
| `event Action<T> OnX;` | 아래 `Event<T>` 멤버 |
| `OnX += Handler;` | `mOnXSubId = OnX.Subscribe(...)` — 구독 id 필드 이름은 `m<이벤트명>SubId` |
| `OnX -= Handler;` | `OnX.Unsubscribe(mOnXSubId)` (std::function은 비교가 안 되므로 id로 해제). 해제 직후에도 다른 스레드에서 진행 중인 `Invoke`가 핸들러를 부를 수 있다. 해제하고 바로 객체를 파괴하는 경로는 보고 |
| `EventHandler<TArgs>` (`sender, e`) | `Event<Sender*, const TArgs&>` 또는 원본이 sender를 안 쓰면 `Event<const TArgs&>` |
| `OnX?.Invoke(a)` | `OnX.Invoke(a)` |
| 람다 `x => Foo(x)` | `[this](T x) { Foo(x); }` |
| 람다가 지역 변수를 캡처 | C#은 변수 자체를 공유. C++에서 람다가 나중에(다른 스레드·타이머) 실행되면 **값 캡처** `[=]` 또는 명시 `[a, b]`. `[&]`는 즉시 실행될 때만 |
| 람다가 `this`를 캡처하고 나중에 실행 | 객체가 먼저 죽으면 댕글링. 구독 해제를 소멸자에서 하거나 보고에 적기 |

```cpp
// Event.h
#pragma once
#include <functional>
#include <mutex>
#include <utility>
#include <vector>
#include <algorithm>

template <typename... Args>
class Event {
public:
    using Handler = std::function<void(Args...)>;

    int Subscribe(Handler handler) {
        std::lock_guard<std::mutex> lock(mMutex);
        const int id = ++mNextId;
        mHandlers.emplace_back(id, std::move(handler));
        return id;
    }

    void Unsubscribe(int id) {
        std::lock_guard<std::mutex> lock(mMutex);
        mHandlers.erase(std::remove_if(mHandlers.begin(), mHandlers.end(),
                                       [id](const auto& p) { return p.first == id; }),
                        mHandlers.end());
    }

    // 핸들러 목록을 복사한 뒤 락 밖에서 호출한다 (핸들러 안에서 Subscribe해도 교착 없음)
    void Invoke(Args... args) {
        std::vector<std::pair<int, Handler>> copy;
        {
            std::lock_guard<std::mutex> lock(mMutex);
            copy = mHandlers;
        }
        for (auto& p : copy) {
            p.second(args...);
        }
    }

private:
    std::mutex mMutex;
    std::vector<std::pair<int, Handler>> mHandlers;
    int mNextId = 0;
};
```

## 4. 타입 검사·분기

| C# | C++ |
|---|---|
| `x is Foo` | `dynamic_cast<Foo*>(p) != nullptr` |
| `x as Foo` | `dynamic_cast<Foo*>(p)` |
| `if (x is Foo f)` | `if (auto* f = dynamic_cast<Foo*>(p))` |
| `switch (message) { case FooMsg m: ... }` (타입 패턴) | 원본 case 순서대로 `if (auto* m = dynamic_cast<FooMsg*>(p)) { ... } else if (...)`. 상속 관계에서 앞 case가 먼저 잡히는 C# 규칙이 그대로 유지된다 |
| `a == b` (class, 재정의 없음) | 포인터 비교 `pa == pb` (같은 객체인지) |
| `a == b` (struct, 또는 `operator==` 재정의) | 값 비교 `operator==` |
| `switch` 문자열 | `if / else if` 비교 |
| `switch` case 끝 fall-through 없음 | 모든 case 끝에 `break;` |
| `typeof(T)` / `GetType()` | 변환하지 않음. 쓰임새를 보고 ID·표로 대체하고 보고 |

## 5. 리플렉션·속성(Attribute)

C++17에는 실행 중 리플렉션이 없다. 리플렉션은 **포팅 전 정리 단계에서 C# 안에서 명시 코드로 바뀌어 있어야 한다** (가상 속성, 팩토리 표, 명시 등록, 생성된 `Write`/`Read`). 포팅에서는 그 명시 코드를 1:1로 옮긴다.

| 정리된 C# | C++ |
|---|---|
| `public override ushort AttrMsgId { get { return 0x0101; } }` | `uint16_t GetAttrMsgId() const override { return 0x0101; }` |
| `Dictionary<ushort, Func<MsgBase>>` 팩토리 표 | `std::unordered_map<uint16_t, std::function<std::shared_ptr<MsgBase>()>>` (`serialization.md` 3절) |
| 명시 등록 `bus.Register(typeof(X), m => On((X)m))` | 같은 순서로 등록. 형식 키는 `std::type_index(typeid(X))`, 캐스트는 `static_cast` |
| Attribute 클래스 자체 | 옮기지 않는다 (C++에 없음). 명시 값으로 이미 대체됨 |
| 남아 있는 리플렉션 호출 | 입력 확인에서 멈춘다 (SKILL.md 2절) |

## 6. 예외

| C# | C++ |
|---|---|
| `try { } catch (Exception ex) { }` | `try { } catch (const std::exception& ex) { }` — 원본에 없던 `catch (...)`는 추가하지 않는다 |
| `catch (FormatException)` 등 특정 예외 | `catch (const NetCompat::FormatException&)` — 상속 관계가 .NET과 같다 (`netcompat.md`) |
| `throw new XxxException("msg")` | `throw NetCompat::XxxException("msg")` — **항상 throw로 옮긴다** (호출자가 다른 파일에 있을 수 있음) |
| `throw;` (다시 던지기) | `throw;` |
| `catch (SocketException)` | Winsock은 예외를 안 던진다. 반환값·`WSAGetLastError()` 검사로 같은 분기 |
| `finally { }` | RAII 가드 객체(소멸자) 또는 블록 끝 정리 코드. 반드시 돌아야 하면 가드 클래스 |
| `ex.Message` | `ex.what()` |
| `ArgumentNullException` 가드 `if (x == null) throw ...` | `if (x == nullptr) { throw NetCompat::ArgumentNullException("x"); }` |
| null 접근·0 나누기·잘못된 캐스트에 기대는 `catch` | C++에서는 크래시. 정리 단계의 결정(`PREPORT-DECISION`)을 따르고, 없으면 보고 |
| 스레드 진입·타이머 콜백 | 원본과 같게 (SKILL.md 규칙 15). `ActionQueueThread`·`ThreadTimer`의 예외 처리기로 원본 동작을 재현 |

## 7. 문자열 포맷

`std::format`은 C++20이라 금지. 아래 헬퍼를 쓴다.

```cpp
// StrFormat.h
#pragma once
#include <cstdarg>
#include <cstdio>
#include <string>
#include <vector>

inline std::string StrFormat(const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    va_list copy;
    va_copy(copy, args);
    const int len = std::vsnprintf(nullptr, 0, fmt, copy);
    va_end(copy);
    if (len <= 0) {
        va_end(args);
        return std::string();
    }
    std::vector<char> buf(static_cast<size_t>(len) + 1);
    std::vsnprintf(buf.data(), buf.size(), fmt, args);
    va_end(args);
    return std::string(buf.data(), static_cast<size_t>(len));
}
```

| C# 서식 | printf 서식 |
|---|---|
| `{0}` (int) | `%d` (`int32_t`) |
| `{0}` (long) | `%lld` + `static_cast<long long>(v)` |
| `{0}` (uint) | `%u` |
| `{0}` (ulong) | `%llu` + `static_cast<unsigned long long>(v)` |
| `{0}` (double) | `%.15g` |
| `{0:F3}` | `%.3f` |
| `{0:X2}` | `%02X` (`byte`는 `static_cast<unsigned>(b)`) |
| `{0:X4}` | `%04X` |
| `{0:D5}` | `%05d` — 음수는 C# `-00042`, printf `-0042`로 다름. 음수가 올 수 있으면 부호를 따로 붙인다 |
| `{0,-10}` / `{0,10}` (정렬) | `%-10s` / `%10s` |
| `BitConverter.ToString(bytes)` (`0A-0B-FF`) | 헬퍼로 `%02X`를 `-`로 이어 붙임 |
| `{0:F3}`, `{0}` (double) | 로그용이면 허용. 값 비교·전문·파일에 쓰면 마지막 자리 차이 가능 → `TODO(PORT)` |
| `{0}` (string) | `%s` + `s.c_str()` |
| `{0}` (bool) | `%s` + `(b ? "True" : "False")` — C#은 `True`/`False` 대문자 |
| `{0}` (enum) | `%s` + `ToString(e)` 이름 표 |

## 8. 로그

외부 로그 라이브러리 금지. 프로젝트에 `Logger` 한 곳을 두고 모든 출력을 거기로 보낸다. C#의 로그 호출 위치와 레벨을 그대로 대응시킨다. `Logger.cpp`(콘솔+파일, mutex 직렬화)는 가장 하위 공용 프로젝트에 한 번만 만든다. 이미 있으면 그것을 읽고 쓴다. C# 로그 라이브러리의 파일 형식·경로는 원본을 따르고, 소스가 없으면 `TODO(PORT)`.

```cpp
// Logger.h
#pragma once
#include <cstdint>
#include <string>
#include "StrFormat.h"

enum class LogLevel : int32_t { Debug, Info, Warn, Error };

namespace Logger {
void Write(LogLevel level, const std::string& message);   // 콘솔 + 파일, 내부에서 mutex로 직렬화
}

#define LOG_DEBUG(...) Logger::Write(LogLevel::Debug, StrFormat(__VA_ARGS__))
#define LOG_INFO(...)  Logger::Write(LogLevel::Info,  StrFormat(__VA_ARGS__))
#define LOG_WARN(...)  Logger::Write(LogLevel::Warn,  StrFormat(__VA_ARGS__))
#define LOG_ERROR(...) Logger::Write(LogLevel::Error, StrFormat(__VA_ARGS__))
```

`main` 시작 시 `SetConsoleOutputCP(CP_UTF8);`를 호출해 한글 콘솔 출력이 깨지지 않게 한다.

## 9. 설정·XML

포팅 전 정리 단계에서 설정 읽기는 `ConfigStore` 한 곳으로 모여 있다.

- 다른 클래스의 `ConfigStore.GetString("키")` 호출은 `ConfigStore::GetString("키")`로 그대로 옮긴다. 반환은 `std::optional<std::string>` (C# `null` = 키 없음).
- `ConfigStore` 내부 구현은 **설정 파일 형식이 정해질 때까지** `// TODO(PORT): 설정 형식 미결정`과 함께 `std::nullopt` 반환만 둔다.
- 기존 `GetPrivateProfileString` P/Invoke는 Win32 그대로 호출한다 (`GetPrivateProfileStringW`, 경로는 UTF-16 변환).
- `XmlDocument` 사용 위치는 사람이 정한 방식을 따른다. 정해지지 않았으면 읽은 뒤 구조체를 채우는 로직만 옮기고 읽기 부분은 `TODO(PORT)`.

## 10. LINQ

LINQ는 포팅 전 정리 단계에서 C# 반복문으로 바뀌어 있어야 한다(지연 실행·안정 정렬·`checked` 합계 등 의미를 C#에서 맞춘 상태). 남아 있으면 입력 확인에서 멈춘다. 반복문은 1:1로 옮긴다.

## 11. 비동기·스레드

| C# | C++ |
|---|---|
`async`/`await`/`Task.Run`은 정리 단계에서 C# 안에서 스레드로 바뀌어 있어야 한다. 남아 있으면 입력 확인에서 멈춘다.

| 정리된 C# | C++ |
|---|---|
| `new Thread(() => X()) { IsBackground = true }.Start()` | `std::thread` 멤버 + 종료 시 `join`. 호출마다 만드는 일회성 스레드면 보관 목록에 넣고 종료 때 `join`. **`detach()` 금지** |
| `CancellationTokenSource` / `ct.WaitHandle.WaitOne(n)` | `WaitHandle`(`concurrency.md` 3절) 또는 `std::atomic<bool>` + `condition_variable` 대기 |
| `Thread.Join()` | `std::thread::join()` |

## 12. 프로세스 수명

| C# | C++ |
|---|---|
| `[STAThread] static void Main` | `int wmain(int argc, wchar_t* argv[])` 또는 `int main`. COM을 쓰지 않으면 STA 처리 없음. COM을 쓰면 `CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED)` |
| `Console.CancelKeyPress += (s, e) => { … }` | `SetConsoleCtrlHandler(Handler, TRUE)`. 처리기는 **별도 스레드**에서 불린다. C#의 `e.Cancel = true`는 `return TRUE`, 아니면 `FALSE` |
| `Environment.Exit(n)` | `std::exit(n)` — 정적 객체 소멸자가 돈다. 실행 중인 `std::thread`가 있으면 그 전에 멈추고 `join` |
| `AppDomain.CurrentDomain.ProcessExit` | `std::atexit` 또는 `main` 끝의 정리 코드 |
| `AppDomain.CurrentDomain.UnhandledException` | `std::set_terminate` (로그만 가능, 계속 실행 불가) |
| `IsBackground = true` 스레드 | C#은 `Main`이 끝나면 강제 종료된다. C++은 `main` 끝에서 종료 신호 + `join`. 원본에 종료 신호가 없으면 보고 |

## 13. 자체 Service Locator

원본이 직접 만든 Service Locator(형식으로 객체를 등록·조회)는 같은 이름의 클래스로 옮긴다. **원본의 동작(덮어쓰기, 미등록 시 null, 알려진 결함 포함)을 그대로 재현한다.**

```cpp
// C# 원본의 이름과 메서드 이름을 그대로 쓴다. 아래 이름은 예시다.
class ServiceRegistry {
public:
    template <typename T>
    void Register(std::shared_ptr<T> service) {   // C#: Register<T>(T service)
        std::lock_guard<std::recursive_mutex> lock(mLock);
        mServices[std::type_index(typeid(T))] = std::move(service);
    }
    template <typename T>
    std::shared_ptr<T> Get() {                       // C#: Get<T>() — 없으면 null
        std::lock_guard<std::recursive_mutex> lock(mLock);
        auto it = mServices.find(std::type_index(typeid(T)));
        return it == mServices.end() ? nullptr : std::static_pointer_cast<T>(it->second);
    }
private:
    std::recursive_mutex mLock;
    std::unordered_map<std::type_index, std::shared_ptr<void>> mServices;
};
```
