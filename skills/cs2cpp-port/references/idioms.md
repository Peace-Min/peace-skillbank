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
| 가변 `static int sCount;` | `inline static int32_t sCount = 0;` |
| `static readonly` 객체 | 함수 안 `static` 지역 변수로 반환 (초기화 순서 문제 방지) |
| `static class Util` | `namespace Util { ... }` 자유 함수 |
| 정적 생성자 | 함수 안 `static` 지역 변수 초기화로 |
| 싱글턴 `Foo.Instance` | `static Foo& Instance() { static Foo s; return s; }` (C++11부터 스레드 안전) + 복사 금지 |
| 복사되면 안 되는 클래스 (스레드·소켓·락 보유) | `Foo(const Foo&) = delete; Foo& operator=(const Foo&) = delete;` |
| `partial class` | 하나의 클래스로 합친다. 원본 파일별로 추적 주석 |
| 중첩 클래스 | 중첩 클래스 그대로 |
| 제네릭 `class Foo<T>` | `template <typename T> class Foo` — 정의는 헤더에 |
| 제약 `where T : struct, Enum` / `where T : IFoo` / `where T : new()` | `requires std::is_enum_v<T>` / `requires std::derived_from<T, IFoo>` / `requires std::default_initializable<T>` (`<concepts>`). 제약은 옮겨 둔다(잘못 쓰면 컴파일 오류로 잡힌다). `class`·`struct` 제약은 옮기지 않는다 |
| 확장 메서드 `static void X(this Foo f)` | 자유 함수 `void X(Foo& f)` |
| `ref int x` / `out int x` | `int32_t& x` |
| 여러 `out` | 그대로 참조 인자들 (구조 변경 금지) |
| 기본 인자 `int x = 0` | 선언(헤더)에만 `int32_t x = 0` |
| 메서드 오버로드 | 그대로 오버로드 |
| 객체 초기화 `new Foo { A = 1, B = 2 }` | 집합체(생성자 없는 struct)면 지정 초기화 `Foo{ .A = 1, .B = 2 }` — **멤버 선언 순서대로만** 적을 수 있다. 순서가 다르거나 생성자가 있으면 생성 후 `SetA(1); SetB(2);`를 원본 순서대로 |
| struct의 기본 `Equals`·`==` (모든 필드 비교) | `bool operator==(const Foo&) const = default;` |
| `Equals`·`==` 재정의 | `bool operator==(const Foo& other) const` 하나만(**`const` 멤버, `const&` 인자**). 비대칭으로 쓰면 C++20의 뒤집힌 후보 때문에 모호성 오류가 난다. `!=`는 만들지 않는다(자동 생성) |

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
| 람다 `x => Foo(x)` | `[this](T x) { Foo(x); }` (캡처 규칙은 아래 "람다 캡처") |

### 람다 캡처 (GC가 없어서 생기는 차이)

C#은 람다가 잡은 변수와 객체를 GC가 람다가 끝날 때까지 살려 둔다. C++은 살려 주지 않는다. **언제 실행되는지**로 캡처를 정한다.

| 실행 시점 | 예 | 캡처 |
|---|---|---|
| 호출이 끝나기 전에 실행 | `Invoke`, `InvokeWithResult`, 정렬 비교자, 그 자리에서 부르는 람다 | `[&]`, `[this]` 가능 |
| 나중에 실행 | `Post`, 타이머 콜백, `Subscribe` 핸들러, 스레드 본문 | 지역 변수는 **이름을 적어 값 캡처** `[a, b]`. `this`는 아래 표 |

- 나중에 실행되는 람다에 `[&]`와 `[=]`를 쓰지 않는다. `[=]`는 `this`를 몰래 잡는다(C++20에서 사용 중지 경고).
- C#은 지역 변수 **자체**를 공유한다. 람다를 넘긴 뒤 원본이 그 변수를 바꾸거나 람다 안에서 바꾸면 값 캡처와 결과가 달라진다. 그 변수는 `auto x = std::make_shared<T>(초기값);`로 만들고 `x`를 값 캡처한다.

나중에 실행되는 람다의 `this`:

| 조건 | 캡처 |
|---|---|
| 객체가 파괴되기 전에 그 큐를 `Stop`, 타이머를 `Dispose`, 이벤트를 `Unsubscribe`한다 (소멸자나 `Dispose`에서 먼저 함) | `[this]` |
| 위가 아니고 객체를 `std::shared_ptr`로 관리한다 | `[self = shared_from_this()]` 후 `self->Foo()`. 클래스는 `std::enable_shared_from_this<T>`를 상속한다. 생성자 안에서는 부를 수 없다 |
| 둘 다 아니다 | `[this]`로 두고 보고에 "수명 미보장"을 적는다 |

`std::weak_ptr`로 실행 직전에 살아 있는지 검사하고 건너뛰는 형태는 쓰지 않는다. C#에서는 객체가 살아 있어서 그 작업이 실행되므로 동작이 달라진다. 원본에 해제 여부 검사(`if (mDisposed) return;`)가 있으면 그 검사만 옮긴다.

```cpp
// Event.h
#pragma once
#include <functional>
#include <mutex>
#include <utility>
#include <vector>

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
        std::erase_if(mHandlers, [id](const auto& p) { return p.first == id; });
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

C++20에도 실행 중 리플렉션이 없다. 리플렉션은 **C# 안에서 명시 코드로 바뀌어 있어야 한다**(`input-contract.md` 1절) (가상 속성, 팩토리 표, 명시 등록, 생성된 `Write`/`Read`). 포팅에서는 그 명시 코드를 1:1로 옮긴다.

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
| null 접근·0 나누기·잘못된 캐스트에 기대는 `catch` | C++에서는 크래시. `PREPORT-DECISION`(`input-contract.md` 3절)을 따르고, 없으면 보고 |
| 스레드 진입·타이머 콜백 | 원본과 같게 (SKILL.md 규칙 16). `ActionQueueThread`·`ThreadTimer`의 예외 처리기로 원본 동작을 재현 |

## 7. 문자열 포맷

`std::format`(`<format>`)을 쓴다. 인자 형식을 컴파일할 때 검사하므로 printf의 `%d`/`%lld` 실수가 생기지 않는다. 형식 문자열은 문자열 리터럴이어야 한다(실행 중에 만든 형식은 `std::vformat`). C# 위치 지정 `{0}`은 그대로 쓸 수 있고, 한 형식 문자열 안에서 `{}`와 `{0}`을 섞지 않는다. `{{`, `}}`도 C#과 같다.

**숫자·bool의 기본 문자열은 C#과 다르다.** 아래 표의 `NetCompat` 함수로 먼저 문자열로 바꾼 뒤 넣는다(`netcompat.md`).

| C# | C++ |
|---|---|
| `string.Format("{0} {1}", a, b)`, `$"{a} {b}"` | `std::format("{0} {1}", a, b)` |
| `{0}` (정수: `int`·`long`·`uint`·`byte` 등) | `{0}` 그대로 (결과 같음) |
| `{0}` (`string`) | `{0}` + `std::string`. 원본이 `null`을 넘길 수 있으면 `optional`을 풀어 빈 문자열로(C#은 `null`을 빈 문자열로 출력) |
| `{0}` (`double`) | `{0}` + `NetCompat::ToString(d)` |
| `{0}` (`float`) | `{0}` + `NetCompat::ToString(f)` |
| `{0}` (`bool`) | `{0}` + `NetCompat::ToString(b)` (`True`/`False`) |
| `{0}` (`enum`) | `{0}` + `ToString(e)` 이름 표 (`types.md` 6절) |
| `{0}` (`char`) | `char16_t`는 `std::format`이 받지 않는다. 원본 문자를 UTF-8 `std::string`으로 바꿔 넣는다 |
| `{0:F3}` | `{0}` + `NetCompat::ToStringF(d, 3)` |
| `{0:D5}` | `{0}` + `NetCompat::ToStringD(n, 5)` |
| `{0:X2}`, `{0:X}` | `{0}` + `NetCompat::ToStringX(n, 2)`, `NetCompat::ToStringX(n)` (`byte`도 그대로 넘긴다) |
| `{0,10}` / `{0,-10}` (정렬) | `{0:>10}` / `{0:<10}`. **방향을 항상 적는다**(`std::format`은 문자열을 왼쪽, 숫자를 오른쪽에 붙여 C#과 다르다) |
| `{0,8:F2}` (정렬 + 서식) | `{0:>8}` + `NetCompat::ToStringF(d, 2)` |
| `BitConverter.ToString(bytes)` (`0A-0B-FF`) | 바이트마다 `std::format("{:02X}", b)`를 `-`로 이어 붙이는 헬퍼 |
| 사용자 지정 서식 `"0.00"`, `"#,##0"`, `"N2"`, `"E3"` 등 | 대응 없음. 로그용이면 가까운 서식으로 옮기고 `TODO(PORT): 서식 확인`, 값 비교·전문·파일이면 보고 |
| `"Count: " + n` (문자열 + 숫자·bool·enum) | `std::format("Count: {}", n)` (`+`로 옮기면 포인터 연산이 된다) |
| 형식 문자열에 지역화 `L` 지정자 | 쓰지 않는다 (문화권 고정 "C") |

## 8. 로그

외부 로그 라이브러리 금지. 프로젝트에 `Logger` 한 곳을 두고 모든 출력을 거기로 보낸다. C#의 로그 호출 위치와 레벨을 그대로 대응시킨다. `Logger.cpp`(콘솔+파일, mutex 직렬화)는 가장 하위 공용 프로젝트에 한 번만 만든다. 이미 있으면 그것을 읽고 쓴다. C# 로그 라이브러리의 파일 형식·경로는 원본을 따르고, 소스가 없으면 `TODO(PORT)`.

```cpp
// Logger.h
#pragma once
#include <cstdint>
#include <format>
#include <string>

enum class LogLevel : int32_t { Debug, Info, Warn, Error };

namespace Logger {
void Write(LogLevel level, const std::string& message);   // 콘솔 + 파일, 내부에서 mutex로 직렬화
}

// 형식은 std::format과 같다: LOG_INFO("수신 {}바이트", n). 숫자·bool은 7절 표대로 NetCompat 함수로 넣는다.
#define LOG_DEBUG(...) Logger::Write(LogLevel::Debug, std::format(__VA_ARGS__))
#define LOG_INFO(...)  Logger::Write(LogLevel::Info,  std::format(__VA_ARGS__))
#define LOG_WARN(...)  Logger::Write(LogLevel::Warn,  std::format(__VA_ARGS__))
#define LOG_ERROR(...) Logger::Write(LogLevel::Error, std::format(__VA_ARGS__))
```

`main` 시작 시 `SetConsoleOutputCP(CP_UTF8);`를 호출해 한글 콘솔 출력이 깨지지 않게 한다.

## 9. 설정·XML

입력 C#에서 설정 읽기는 한 정적 클래스(아래 예: `ConfigStore`)로 모여 있다.

- 다른 클래스의 `ConfigStore.GetString("키")` 호출은 `ConfigStore::GetString("키")`로 그대로 옮긴다. 반환은 `std::optional<std::string>` (C# `null` = 키 없음).
- `ConfigStore` 내부 구현은 `PORT_CONFIG.md`의 설정 파일 방식으로 쓴다. 정해지지 않았으면 `// TODO(PORT): 설정 형식 미결정`과 함께 `std::nullopt` 반환만 둔다.
- 기존 `GetPrivateProfileString` P/Invoke는 Win32 그대로 호출한다 (`GetPrivateProfileStringW`, 경로는 UTF-16 변환).
- `XmlDocument` 사용 위치는 `PREPORT-DECISION` 또는 `PORT_CONFIG.md`의 방식을 따른다. 정해지지 않았으면 읽은 뒤 구조체를 채우는 로직만 옮기고 읽기 부분은 `TODO(PORT)`.

## 10. LINQ

LINQ는 C# 안에서 반복문으로 바뀌어 있어야 한다(지연 실행·안정 정렬·`checked` 합계 등 의미를 C#에서 맞춘 상태). 남아 있으면 입력 확인에서 멈춘다. 반복문은 1:1로 옮긴다.

## 11. 비동기·스레드

| C# | C++ |
|---|---|
`async`/`await`/`Task.Run`은 C# 안에서 스레드로 바뀌어 있어야 한다. 남아 있으면 입력 확인에서 멈춘다.

| 정리된 C# | C++ |
|---|---|
| `new Thread(() => X()) { IsBackground = true }.Start()` | `std::jthread` 멤버, 본문은 `RunThreadBody`로 감싼다. 원본의 종료 플래그·`Join` 순서를 그대로 옮긴다(`stop_token`은 쓰지 않는다). 호출마다 만드는 일회성 스레드면 보관 목록(`std::vector<std::jthread>`)에 넣는다. **`detach()` 금지** |
| `CancellationTokenSource` / `ct.WaitHandle.WaitOne(n)` | `WaitHandle`(`concurrency.md` 3절) 또는 `std::atomic<bool>` + `condition_variable` 대기 |
| `Thread.Join()` | `join()` (자기 스레드에서 부르면 교착이므로 원본이 그럴 수 있으면 보고) |

## 12. 프로세스 수명

| C# | C++ |
|---|---|
| `[STAThread] static void Main` | `int wmain(int argc, wchar_t* argv[])` 또는 `int main`. COM을 쓰지 않으면 STA 처리 없음. COM을 쓰면 `CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED)` |
| `Console.CancelKeyPress += (s, e) => { … }` | `SetConsoleCtrlHandler(Handler, TRUE)`. 처리기는 **별도 스레드**에서 불린다. C#의 `e.Cancel = true`는 `return TRUE`, 아니면 `FALSE` |
| `Environment.Exit(n)` | `std::exit(n)` — 정적 객체 소멸자가 돈다. 실행 중인 스레드가 있으면 그 전에 멈추고 `join` |
| `AppDomain.CurrentDomain.ProcessExit` | `std::atexit` 또는 `main` 끝의 정리 코드 |
| `AppDomain.CurrentDomain.UnhandledException` | `std::set_terminate` (로그만 가능, 계속 실행 불가) |
| (처리되지 않은 예외로 끝날 때 .NET이 표준 오류에 예외를 출력함) | `main` 첫 줄에서 아래 `InstallTerminateLogger()`를 부르고, **작업 스레드 본문은 `RunThreadBody`로 감싼다.** C++ `std::terminate`는 아무것도 출력하지 않아 원인을 알 수 없다. MSVC는 `std::set_terminate`가 스레드마다 따로라 `main`에서 설치한 처리기가 작업 스레드에는 듣지 않는다. 원본에 처리기가 없어도 넣는다 |
| `IsBackground = true` 스레드 | C#은 `Main`이 끝나면 강제 종료된다. C++은 `main` 끝에서 종료 신호 + `join`. 원본에 종료 신호가 없으면 보고 |

```cpp
// TerminateLogger.h
#pragma once
#include <cstdio>
#include <cstdlib>
#include <exception>

// C#: 처리되지 않은 예외로 프로세스가 끝날 때 예외 내용을 표준 오류에 출력하는 .NET 동작.
// 출력한 뒤 비정상 종료한다. MSVC에서 std::abort의 종료 코드는 0xC0000409다.
[[noreturn]] inline void ReportUnhandledAndAbort(const char* what) {
    std::fprintf(stderr, "Unhandled exception: %s\n", what ? what : "(unknown)");
    std::fflush(stderr);
    std::abort();
}

// main 스레드용. MSVC는 std::set_terminate가 스레드마다 따로라서 작업 스레드에는 효과가 없다.
// 작업 스레드는 아래 RunThreadBody로 감싼다.
inline void InstallTerminateLogger() {
    std::set_terminate([] {
        std::exception_ptr error = std::current_exception();
        if (error) {
            try {
                std::rethrow_exception(error);
            } catch (const std::exception& ex) {
                ReportUnhandledAndAbort(ex.what());
            } catch (...) {
                ReportUnhandledAndAbort(nullptr);
            }
        }
        std::fprintf(stderr, "terminate called without an active exception\n");
        std::fflush(stderr);
        std::abort();
    });
}

// 작업 스레드 본문. 처리되지 않은 예외가 스레드 밖으로 나가면 .NET처럼 출력하고 끝낸다.
// 컴파일러와 상관없이 같게 동작한다. 스레드(std::jthread)를 직접 만들 때는 본문을 이것으로 감싼다.
template <typename F>
void RunThreadBody(F&& body) noexcept {
    try {
        body();
    } catch (const std::exception& ex) {
        ReportUnhandledAndAbort(ex.what());
    } catch (...) {
        ReportUnhandledAndAbort(nullptr);
    }
}
```

작업·콜백마다 `try`/`catch`를 둘러 예외를 삼키지 않는다. C#도 처리기가 없으면 프로세스가 끝나므로, 삼키면 원본에서 죽던 결함이 C++에서 조용히 숨는다.

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
