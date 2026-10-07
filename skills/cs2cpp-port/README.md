# cs2cpp-port

C# 코드를 C++20으로 1:1 포팅하는 스킬. C++에 대응이 없는 기능(Dispatcher·리플렉션·async·LINQ·Timer 등)은 C# 안에서 먼저 정리된 코드를 받는다. 입력 조건은 `references/input-contract.md`, 그 정리에 쓰는 C# 대체 클래스는 `references/csharp-helpers.md`에 있다. 런타임 규칙은 `SKILL.md`, 매핑표·패턴 코드는 `references/`에 있다. 사람용 안내는 [사용 가이드](../../docs/cs2cpp-port-usage.md).

스킬에는 **C#→C++ 번역 규칙만** 둔다. 바이트 순서·헤더 구성·메시지 목록 같은 대상 프로젝트 고유 사실은 넣지 않고, 변환할 C# 원본에서 읽게 한다.

## 정한 기본값

| 항목 | 기본값 | 위치 |
|---|---|---|
| 환경 | C++20(`/std:c++20`), VS2022 v143 x64, 표준 라이브러리 + Win32만 | env.md |
| 프로젝트 형태 | 클래스 라이브러리 → 정적 라이브러리, 하위→상위 순서, `API_MAP.md`, 라이브러리 관문 | project.md |
| 문자열 | UTF-8 `std::string`, 바이트 변환 지점에서만 원본 인코딩 | serialization.md 4절 |
| 경고 | `/W4` + 축소 변환·부호 비교·조건 대입·반환 누락·미초기화 경고를 오류로 | env.md 1절 |
| .NET 의미 차이 | `NetCompat.h`(예외 형식·인덱서·파싱·반올림) | netcompat.md |
| `lock` | 항상 `std::recursive_mutex` | SKILL.md 규칙 14 |
| 람다 캡처 | 나중에 실행되는 람다는 값 캡처, `this`는 수명이 보장될 때만 | idioms.md 3절 |
| 스레드 예외 | 원본과 같게 (처리기 없으면 프로세스 종료, 종료 전 예외 출력) | SKILL.md 규칙 16, idioms.md 12절 |
| 프로젝트별 조정 | `PORT_CONFIG.md` (허용 라이브러리·설정 형식·서식·코드페이지·대체 클래스 이름) | project.md 5절 |
| 시험 | 모델은 메서드 분류·입력 목록만, 기대값은 C# 실행 결과 | testing.md |

## 프로젝트가 정할 것

설정 파일 형식, XML 처리, 문화권 의존 서식(`double.Parse` 등), 정규식 대체 — `PORT_CONFIG.md`에 적는다. C# 안의 사전 정리와 C# 골든 기록기·C++ 재생기 제작.

## 검증 기록

- 2026-10-01: `references/`의 C++ 헤더 15개를 추출했다. `ActionQueueThread`, `ThreadTimer`, `WaitHandle`, `Stopwatch`, `Event`, `StrFormat`, `Logger`, `Win32`, `UdpSocket`, `NetCompat`, `ByteStream`, `MsgFactory`, `TextEncoding`, `FieldVisit`, `TerminateLogger`이다. g++ 13.1(MinGW) `-std=c++17 -pedantic -Wall -Wextra -Wshadow -Wconversion -Wsign-conversion -Werror`로 빌드했고, 동작 시험 56개와 스레드 예외 종료 시험(예외를 출력한 뒤 비정상 종료)이 통과했다.
- 같은 날 `csharp-helpers.md`의 C# 대체 클래스 3개를 C# 7.3 `-warnaserror`로 빌드했고(VS2022 Roslyn csc, .NET Framework 4.7.2 참조 어셈블리), C++과 같은 시나리오의 동작 시험 18개가 통과했다. 둘 다 `tests/cs2cpp-port-fixtures.ps1`이 돌린다.
- 2026-10-02(사내): VS2022 Professional, MSVC 14.44 v143에서 패턴 헤더 15개와 시험이 env.md 경고 설정으로 빌드됐고 동작 시험 55/55가 통과했다. 스레드 예외 종료 시험만 실패했다(예외 출력 없이 `0xC0000409`). 원인은 MSVC의 `std::set_terminate`가 스레드마다 따로라 `main`에서 설치한 처리기가 작업 스레드에 듣지 않는 것이다.
- 2026-10-06: 위 문제를 고쳤다. 작업 스레드 본문을 `RunThreadBody`로 감싸 처리되지 않은 예외를 출력하고 끝낸다. `ActionQueueThread`, `ThreadTimer`, `UdpSocket`의 스레드도 이것으로 시작한다. 큐 스레드 예외 종료 시험(`--terminate-queue`)을 더했다. `NetCompat.h`의 C4146 경고(부호 없는 형식에 단항 `-`)를 `if constexpr`로 없앴다. 시험 스크립트가 `vcvarsall.bat` 호출 전에 Visual Studio Installer 폴더를 PATH에 넣는다(`vswhere.exe`를 이름만으로 불러 실패하던 문제). g++ 13.1과 **MSVC 14.44(VS2022 Community 17.14, v143)** 모두에서 정적 검사, C# 18/18, 동작 56/56, 종료 시험 2개(일반 스레드, 큐 스레드)가 통과했다. 같은 MSVC에서 고치기 전 방식(`main`의 `set_terminate`만)은 `0xC0000409`에 예외 출력 없이 끝나는 것을 다시 확인했다.
- 2026-10-07: **C++20으로 바꿨다.** 컴파일 `/std:c++20`(C는 `/std:c17`). `env.md` 3절에 쓰는 기능, 4절에 금지, 4-1절에 C++20에서 바뀐 것을 적었다.
  - 패턴 헤더: `StrFormat.h`를 없애고 `std::format`으로(`Logger.h` 포함). `ByteStream.h`는 `std::span`·`std::bit_cast`, `UdpSocket.h`는 `std::span`, 스레드는 모두 `std::jthread`, `Event.h`는 `std::erase_if`, `FieldVisit.h`는 `requires`. `TextEncoding::PathFromUtf8` 추가(`u8path`는 C++20에서 사용 중지).
  - `NetCompat.h`에 숫자·bool 문자열 함수 `ToString(double/float/bool)`, `ToStringF`, `ToStringD`, `ToStringX`를 더했다. `std::format`의 기본 표기가 C#과 달라서다(`0.1 + 0.2` → `0.30000000000000004` 대 `0.3`, `2.675` F2 → `2.67` 대 `2.68`). .NET Framework 4.8이 낸 문자열 4,036줄(무작위 3,000개, 15자리 동률, `-0.0`, `NaN`, 무한대, `float` 1,000개, 정수 `D`·`X`)과 대조해 16,201개가 모두 같았다.
  - 정적 검사를 C++20 금지 목록으로 바꿨다(모듈, 코루틴, `ranges` 뷰, `u8` 문자열, `u8path`, C++23, 시간대, 맨 `std::thread`).
  - MSVC 14.44와 g++ 13.1(`-std=c++20 -pedantic -Wconversion -Wsign-conversion -Werror`) 모두 정적 검사(헤더 14개), C# 18/18, 동작 72/72, 종료 시험 2개가 통과했다.

## 설치

저장소를 클론해 루트에서 Claude Code를 시작하면 `/cs2cpp-port`가 바로 보인다. plugin 설치 시에는 `/peace-skillbank:cs2cpp-port`. 외부 스크립트·네트워크 의존은 없다.
