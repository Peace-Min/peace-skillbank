# cs2cpp-port

C# 코드를 C++17로 1:1 포팅하는 스킬. C++에 대응이 없는 기능(Dispatcher·리플렉션·async·LINQ·Timer 등)은 C# 안에서 먼저 정리된 코드를 받는다. 입력 조건은 `references/input-contract.md`, 그 정리에 쓰는 C# 대체 클래스는 `references/csharp-helpers.md`에 있다. 런타임 규칙은 `SKILL.md`, 매핑표·패턴 코드는 `references/`에 있다. 사람용 안내는 [사용 가이드](../../docs/cs2cpp-port-usage.md).

스킬에는 **C#→C++ 번역 규칙만** 둔다. 바이트 순서·헤더 구성·메시지 목록 같은 대상 프로젝트 고유 사실은 넣지 않고, 변환할 C# 원본에서 읽게 한다.

## 정한 기본값

| 항목 | 기본값 | 위치 |
|---|---|---|
| 환경 | C++17, VS2022 v143 x64, 표준 라이브러리 + Win32만 | env.md |
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
- **MSVC v143 빌드는 아직 검증하지 않았다.** 시험 스크립트는 C++ 워크로드가 온전한 MSVC가 있으면 env.md의 경고 설정으로 먼저 빌드한다.

## 설치

저장소를 클론해 루트에서 Claude Code를 시작하면 `/cs2cpp-port`가 바로 보인다. plugin 설치 시에는 `/peace-skillbank:cs2cpp-port`. 외부 스크립트·네트워크 의존은 없다.
