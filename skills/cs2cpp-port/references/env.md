# 환경 고정값

## 1. 프로젝트 설정 (.vcxproj)

| 항목 | 값 | 비고 |
|---|---|---|
| PlatformToolset | `v143` | VS2022 |
| Platform | `x64` | Win32(x86) 구성은 만들지 않는다 |
| ConfigurationType | 실행 파일 `Application`, 라이브러리 `StaticLibrary` | `project.md` |
| SubSystem | `Console` | |
| LanguageStandard | `stdcpp17` | |
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

## 3. C++17에서 쓸 수 있는 것

`std::optional`, `std::variant`, `std::string_view`(멤버 저장 금지), `std::filesystem`, 구조적 바인딩, `if constexpr`, `if (init; cond)`, `inline` 변수, `namespace A::B {}`, `std::scoped_lock`, `std::shared_mutex`, `std::make_unique`, `std::clamp`, `[[nodiscard]]`, `[[maybe_unused]]`, `[[fallthrough]]`.

## 4. 금지 (C++20 이상)

| 금지 | 대체 |
|---|---|
| `map.contains(k)` | `map.find(k) != map.end()` |
| `str.starts_with(p)` / `ends_with` | `str.compare(0, p.size(), p) == 0` / 끝 부분 `compare` |
| `std::format` | `StrFormat` (`idioms.md` 7절) |
| `std::span` | 포인터 + 길이, `const std::vector<uint8_t>&` |
| `std::bit_cast` | `std::memcpy` |
| `std::endian` | 없음 (x64 little-endian 고정, 전문은 바이트 단위 처리) |
| `std::erase_if` | `erase(remove_if(...), end())` |
| 지정 초기화 `Foo{ .a = 1 }` | 생성자 또는 멤버별 대입 |
| `<=>` | `operator==`, `operator<` |
| `std::jthread`, `stop_token` | `std::thread` + 종료 플래그 + `join` |
| `concept`, `requires`, `ranges` | 제약 없는 템플릿, `<algorithm>` |
| `char8_t`, `consteval`, `constinit`, `source_location` | 일반 문자열, `constexpr`, `__FILE__`/`__LINE__` |
| `counting_semaphore`, `latch`, `barrier` | `mutex` + `condition_variable` |
| `std::numbers::pi` | `constexpr double kPi = 3.14159265358979323846;` |

## 5. 외부 라이브러리 대체

| 필요 | 쓰는 것 |
|---|---|
| 소켓 | Winsock2 (`net.md`) |
| 스레드·동기화 | `<thread>`, `<mutex>`, `<condition_variable>`, `<atomic>` |
| 시간 | `<chrono>`, 로컬 시각은 `localtime_s(&tm, &t)` (MSVC 인자 순서) |
| 인코딩 변환 | `MultiByteToWideChar` / `WideCharToMultiByte` |
| 파일·경로 | `<fstream>`, `<filesystem>`. **한글 경로는 `std::filesystem::u8path(utf8)`로 만든다** (MSVC는 `std::string` 경로를 ACP로 해석) |
| 로그 | 프로젝트 `Logger` 한 곳 (`idioms.md` 8절) |
| 단위 시험 | 외부 프레임워크 없음 (`testing.md`) |
| 정규식 | `std::regex`는 .NET `Regex`와 문법·동작이 달라 쓰지 않는다. 정리 단계에서 보고된 위치는 사람이 정한다 |
| 설정·XML | **미결정**. `ConfigStore` 등 정리 단계에서 모은 클래스의 선언만 옮기고 구현은 `TODO(PORT)` |
