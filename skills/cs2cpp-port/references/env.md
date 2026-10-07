# 환경 고정값

## 1. 프로젝트 설정 (.vcxproj)

| 항목 | 값 | 비고 |
|---|---|---|
| PlatformToolset | `v143` | VS2022 |
| Platform | `x64` | Win32(x86) 구성은 만들지 않는다 |
| ConfigurationType | 실행 파일 `Application`, 라이브러리 `StaticLibrary` | `project.md` |
| SubSystem | `Console` | |
| LanguageStandard | `stdcpp20` | `/std:c++20` |
| LanguageStandard_C | `stdc17` | `.c` 파일이 있을 때 `/std:c17` |
| ConformanceMode | `true` | `/permissive-` |
| CharacterSet | `Unicode` | |
| WarningLevel | `Level4` | `/W4` |
| AdditionalOptions | `/utf-8 /Zc:__cplusplus /we4244 /we4267 /we4018 /we4389 /we4706 /we4715 /we4700` | 아래 표 |
| ExceptionHandling | `Sync` | `/EHsc` |
| RuntimeLibrary | Debug `/MDd`, Release `/MD` | **솔루션의 모든 프로젝트가 같아야 한다** (다르면 LNK2038) |
| PreprocessorDefinitions | `WIN32_LEAN_AND_MEAN;NOMINMAX;_WIN32_WINNT=0x0A00` | |
| AdditionalDependencies | `Ws2_32.lib`(소켓), `Winmm.lib`(`timeSetEvent` 등 멀티미디어 타이머) | 사용하는 것만 |

경고를 오류로 바꾸는 이유:

| 경고 | 잡는 것 | SKILL.md 규칙 |
|---|---|---|
| C4244, C4267 | 축소 변환 (`double`→`int`, `size_t`→`int`) | 9 |
| C4018, C4389 | 부호 섞인 비교 | 9 |
| C4706 | 조건 안의 대입 `if (x = 5)` | — |
| C4715 | 일부 경로에서 반환 누락 | — |
| C4700 | 초기화 안 된 지역 변수 | 4 |

선택: 코드 분석(`/analyze`)을 켜면 C26495(초기화 안 된 멤버), C26819(`break` 없는 `case`)도 잡는다.

## 2. 헤더 규칙

- 헤더 맨 위 `#pragma once`.
- include 순서: 대응 헤더 → C++ 표준 → `Win32.h` → 프로젝트 헤더.
- Win32 헤더는 **`Win32.h` 하나만** include한다(`net.md` 1절). `windows.h`·`winsock2.h`를 직접 include하지 않는다.
- 헤더에서 포인터·참조로만 쓰는 형식은 **전방 선언**하고 `.cpp`에서 include한다(헤더 순환 방지).
- `using namespace std;` 금지.
- 헤더에는 선언만. 템플릿과 짧은 인라인 getter만 헤더에 정의한다.

## 3. C++20에서 쓰는 것

C# 의미를 더 그대로 옮기거나 실수를 컴파일 오류로 바꾸는 기능만 쓴다. 매핑은 각 참고 파일에 있다.

| 기능 | 쓰는 곳 |
|---|---|
| `std::format` (`<format>`) | 모든 문자열 조립. C# 기본 문자열과 다른 숫자·bool은 `NetCompat::ToString*` (`idioms.md` 7절) |
| `std::span` | `Span<T>`, `ReadOnlySpan<T>`, `ArraySegment<T>`, 버퍼+오프셋+길이 인자 (`types.md` 2-1절, `ByteStream.h`, `UdpSocket.h`) |
| `std::bit_cast` | `BitConverter.DoubleToInt64Bits`·`Int64BitsToDouble`·`SingleToInt32Bits`, 실수 직렬화 |
| `std::endian` | `BitConverter.IsLittleEndian` → `std::endian::native == std::endian::little` |
| `<bit>` (`std::popcount`, `std::rotl`, `std::countl_zero` 등) | `BitOperations.*`. 부호 없는 형식만 받으므로 `static_cast<uint32_t>` 후 |
| `contains` (`map`·`set`·`unordered_*`) | `ContainsKey`, `HashSet.Contains` |
| `starts_with` / `ends_with` (`std::string`) | `StartsWith`/`EndsWith`를 서수 비교로 옮길 때 (`types.md` 3절) |
| `std::erase_if` | `List.RemoveAll(pred)` (지운 개수를 돌려준다) |
| `std::ssize` | `int` 반복 변수와 컬렉션 크기 비교 (`for (int32_t i = 0; i < std::ssize(v); ++i)`) |
| `std::numbers::pi`, `std::numbers::e` | `Math.PI`, `Math.E` (같은 `double` 값) |
| 지정 초기화 `Foo{ .A = 1 }` | 집합체의 객체 초기화. 멤버 선언 순서대로만 (`idioms.md` 1절) |
| `= default` 비교 (`operator==`) | struct 기본 `Equals` (`idioms.md` 1절) |
| `requires`, `<concepts>` | 제네릭 제약 `where T : ...` (`idioms.md` 1절) |
| `std::jthread` | 모든 스레드. 소멸 때 `join`해서 빠뜨린 `join`이 `std::terminate`가 되지 않는다. `stop_token`은 쓰지 않는다 (`concurrency.md`) |
| `std::counting_semaphore`, `std::latch` | `SemaphoreSlim`, `CountdownEvent` (없는 멤버는 `concurrency.md` 4절) |
| C++17 기능 전부 | `std::optional`, `std::variant`, `std::string_view`(멤버 저장 금지), `std::filesystem`, 구조적 바인딩, `if constexpr`, `if (init; cond)`, `inline` 변수, `std::scoped_lock`, `std::shared_mutex`, `[[nodiscard]]`, `[[maybe_unused]]`, `[[fallthrough]]` |

## 4. 금지

| 금지 | 이유 / 대체 |
|---|---|
| 모듈 `import`, `export module` | 빌드 구성이 바뀐다. `#include` |
| 코루틴 `co_await`, `co_yield`, `co_return` | `async`·`yield`는 C#에서 스레드·반복문으로 정리돼 있다 |
| `std::ranges` 뷰(`std::views::filter` 등) | 지연 평가라 LINQ와 같은 함정이 생긴다. C#에서 정리된 반복문을 1:1로 |
| `std::string::contains` | C++23이라 `/std:c++20`에 없다. `s.find(x) != std::string::npos` |
| `std::print`, `std::to_underlying` 등 C++23 | `/std:c++20`에 없다. `std::cout << std::format(...)`, `static_cast<std::underlying_type_t<E>>` |
| `u8"..."` 문자열, `char8_t` 문자열 | C++20에서 `char8_t`라 `std::string`에 넣을 수 없다. `/utf-8`로 평범한 `"..."`를 쓴다 |
| `std::filesystem::u8path` | C++20에서 사용 중지. `TextEncoding::PathFromUtf8` (`serialization.md` 4절) |
| `std::chrono::current_zone`, `zoned_time`, `locate_zone` | Windows ICU에 기대고 OS 판마다 결과가 다를 수 있다. 로컬 시각은 `localtime_s` |
| `std::format`의 지역화 `L` 지정자 | 문화권 고정 "C" |
| `std::source_location`으로 `[CallerMemberName]` 대체 | 함수 이름 형식이 C#과 다르다. 원본 호출부가 넘기는 이름을 문자열 상수로 옮긴다 |
| `consteval`, `constinit` | 1:1 포팅에 필요 없다. `constexpr`, 함수 안 `static` |

## 4-1. C++20에서 바뀐 것 (컴파일은 되지만 틀리거나, 오류가 나는 곳)

| 상황 | C++20 동작 | 처리 |
|---|---|---|
| 생성자를 선언한 struct(`Foo() = default;` 포함)에 `Foo{1, 2}` | 집합체가 아니라 오류 | 생성자를 만들거나 멤버별 대입 |
| `operator==`를 비대칭(비 `const` 멤버, 값 인자 등)으로 정의 | 뒤집힌 후보와 모호하다는 오류 | `bool operator==(const T&) const` 하나 |
| 다른 열거형끼리 산술·비교, 열거형과 실수 산술 | 사용 중지 경고 | 원본처럼 정수로 `static_cast` 후 계산 |
| `volatile` 변수의 `++`, `+=` | 사용 중지 경고 | C# `volatile`은 `std::atomic` (`concurrency.md` 4절) |
| 람다 `[=]`의 암묵적 `this` 캡처 | 사용 중지 경고 | 나중에 실행되는 람다에 `[=]` 금지 (`idioms.md` 3절) |
| 부호 있는 정수 왼쪽 시프트 `-1 << 3` | 정의됨(2의 보수, C#과 같음) | 그대로 |
| `std::format` 형식 문자열 | 컴파일 시점 검사. 실행 중에 만든 문자열은 오류 | `std::vformat(fmt, std::make_format_args(...))` |
| `std::format("{}", 0.1 + 0.2)` | `0.30000000000000004` (최단 왕복 표기) | C# 출력과 같아야 하면 `NetCompat::ToString(d)` |

## 5. 외부 라이브러리 대체

`PORT_CONFIG.md`의 "추가 허용 라이브러리"(`project.md` 5절)에 적힌 것만 더 쓸 수 있다. 없으면 아래 대체를 쓴다.

| 필요 | 쓰는 것 |
|---|---|
| 소켓 | Winsock2 (`net.md`) |
| 스레드·동기화 | `<thread>`, `<mutex>`, `<condition_variable>`, `<atomic>` |
| 시간 | `<chrono>`, 로컬 시각은 `localtime_s(&tm, &t)` (MSVC 인자 순서) |
| 인코딩 변환 | `MultiByteToWideChar` / `WideCharToMultiByte` |
| 파일·경로 | `<fstream>`, `<filesystem>`. **한글 경로는 `TextEncoding::PathFromUtf8(utf8)`로 만든다** (MSVC는 `std::string` 경로를 ACP로 해석하고, `u8path`는 C++20에서 사용 중지) |
| 로그 | 프로젝트 `Logger` 한 곳 (`idioms.md` 8절) |
| 단위 시험 | 외부 프레임워크 없음 (`testing.md`) |
| 정규식 | `std::regex`는 .NET `Regex`와 문법·동작이 달라 쓰지 않는다. `PREPORT-DECISION` 또는 `PORT_CONFIG.md`의 방식을 따르고, 없으면 `TODO(PORT)` |
| 설정·XML | `PORT_CONFIG.md`의 방식(`project.md` 5절). 없으면 설정을 모은 클래스의 선언만 옮기고 구현은 `TODO(PORT)` |
