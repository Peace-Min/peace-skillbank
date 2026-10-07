# cs2cpp-port 사용 가이드

C# 콘솔 코드(.NET Framework 4.7.2/4.8)를 **C++20으로 1:1 포팅**하는 스킬이다. 약한 로컬 모델이 즉흥 변환하지 않도록, 환경·매핑·패턴 코드·점검표·출력 형식을 고정해 둔다.

## 입력 조건

C++에 대응이 없는 기능은 **C# 안에서 먼저** 같은 동작의 형태로 바꿔 둔 코드를 받는다. 이 스킬은 C#을 고치지 않는다. 남아 있으면 위치와 "C#에서 바꿀 형태"를 보고하고 멈춘다.

- 대상 기능: Dispatcher, WPF 형식, 제3자 DLL, 리플렉션, `async`, LINQ, `Timer`, `ConfigurationManager`
- 기준: `skills/cs2cpp-port/references/input-contract.md`
- 정리에 쓰는 C# 대체 클래스: `references/csharp-helpers.md`의 `ActionQueueThread`·`ThreadTimer`·`Event<T>`. C++ 패턴과 이름·동작이 같아서 호출을 1:1로 옮길 수 있다. 이 클래스 파일 자체는 번역하지 않고 C++ 헤더를 넣는다.
- 사람이 정해야 하는 것(`Thread.Abort`, `Regex`, `decimal`, 런타임 예외 `catch` 등)은 그 위치에 `// PREPORT-DECISION: <ID> <결정>`을 남긴다. 표식이 없으면 그 부분만 `TODO(PORT)`로 남는다.

## 프로젝트별 조정: PORT_CONFIG.md

대상 저장소 루트에 `PORT_CONFIG.md`를 두면 아래만 바꿀 수 있다. 서식은 `references/project.md` 5절에 있다.

- 추가 허용 라이브러리
- 설정 파일·XML·문화권 서식·정규식을 처리할 방식
- `Encoding.Default` 코드페이지
- 대체 클래스 이름 대응
- 폴더 대응
- 포팅 제외, 입력 점검 예외, 정리 단계 결정

C++20, VS2022 x64, UTF-8 `std::string`, `recursive_mutex`, `NetCompat`, 정적 라이브러리는 고정이다. 패턴 코드가 이 전제로 쓰여 있기 때문이다.

## 고정 환경

| 항목 | 값 |
|---|---|
| 언어 | C++20 (`/std:c++20`). 쓰는 기능과 금지 목록은 `references/env.md` 3·4절 |
| 컴파일러 | VS2022 v143, x64, `.vcxproj`. 축소 변환·부호 비교·조건 대입 등 경고를 오류로 |
| 라이브러리 | C++ 표준 라이브러리 + Win32(Winsock2 포함)만 |
| 형태 | 콘솔. C# 클래스 라이브러리 → 정적 라이브러리 |
| 문자열 | 소스 UTF-8 + `/utf-8`, 내부 UTF-8 `std::string`. 바이트로 바꾸는 지점에서만 원본 인코딩 |

## 호출

```text
/cs2cpp-port C:\src\MyApp\Core\Device.cs C:\src\MyApp.Cpp\Core
```

plugin으로 설치했으면 `/peace-skillbank:cs2cpp-port`로 부른다. **한 번에 파일 하나만** 옮긴다.

## 순서와 관문

1. 솔루션의 `<ProjectReference>`로 의존 그래프를 만들고 **가장 하위 프로젝트부터** 옮긴다. 프로젝트 안에서는 열거형·구조체 → 메시지 → 서비스 → 관리자 → `Program` 순서다.
2. 파일마다 입력 조건을 확인한다. 대응이 없는 기능이 남아 있으면 "포팅 전 정리 먼저"로 멈춘다. 보고 항목인데 `// PREPORT-DECISION:` 표식이 없으면 그 부분은 `TODO(PORT)`로만 남긴다.
3. 의존 형식이 이미 포팅됐으면 그 헤더와 `API_MAP.md`의 선언대로 호출한다. 아직이면 "선행 포팅 필요"로 멈춘다.
4. 라이브러리 관문을 통과해야 상위 라이브러리로 넘어간다: 빌드 성공, 시험 대상 메서드의 골든 대조 통과, `API_MAP.md` 작성, 남은 TODO 정리.

## 핵심 내용

- **호환 함수 `NetCompat.h`**: .NET과 비슷하지만 다르게 동작하는 곳을 한곳에 모았다.
  - `int.Parse` (`"12abc"`는 FormatException, 형식 오류가 넘침보다 우선, 끝의 `'\0'` 허용)
  - `Math.Round`·`Convert.ToInt32` (은행가 반올림)
  - 인덱서 (`dict[k]`가 새 항목을 넣지 않음)
  - .NET 예외 이름·상속 관계
- **스레드·타이머:** C# 대체 클래스와 이름·동작이 같은 `ActionQueueThread`, `ThreadTimer`
  - 작업은 큐 잠금을 푼 뒤 실행하고, `Stop`·소멸자가 스레드를 `join`한다.
  - 처리기가 없는 작업 예외는 .NET처럼 프로세스를 끝낸다. `main`의 `InstallTerminateLogger()`가 죽기 전에 예외를 출력한다.
- **람다 캡처:** C#은 GC가 람다가 잡은 객체를 살려 두지만 C++은 그렇지 않다.
  - 나중에 실행되는 람다(`Post`·타이머·구독·스레드)에는 `[&]`·`[=]`를 쓰지 않는다.
  - 지역 변수는 이름을 적어 값으로 캡처한다.
  - `this`는 파괴 전에 `Stop`·`Dispose`·`Unsubscribe`가 보장될 때만 캡처하고, 아니면 `shared_from_this`를 쓴다.
- **직렬화·통신:** `ByteWriter`/`ByteReader`(바이트 순서 지정), 팩토리 표, Winsock UDP(멀티캐스트, `SIO_UDP_CONNRESET`, 동기 `Receive`)
- **줄 단위 함정 규칙:**
  - 문자열과 숫자 `+` 연결
  - 인자 평가 순서
  - 생성자 안 가상 호출
  - 부호 섞인 비교
  - `switch`의 `break`
  - class `==`
  - 속성 복합 연산
  - `long` 크기
  - 필드 초기화
- **`lock`은 항상 `std::recursive_mutex`:** C# `lock`이 재진입되기 때문
- **단위 시험:** 모델은 메서드 분류와 입력 목록만 쓰고, 기대값은 C# 원본을 실행해서 얻는다(`references/testing.md`)

## 결과

모델은 코드를 Write 도구로 파일에만 쓰고, 응답에는 다음을 낸다.
- 의존
- 작성한 파일
- 동작 차이
- 시험 분류
- API_MAP 추가분
- `TODO(PORT)` 목록
- 빌드 결과
- 해당 점검표 항목

빌드는 MSBuild(`-p:Platform=x64`, Git Bash에서는 스위치를 `-`로)로 한다. 3회 실패나 셸 2회 시간 초과면 멈춘다.

## 저장소 검증

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\cs2cpp-port-fixtures.ps1
```

- **정적 검사:** 패턴 헤더 14개가 모두 있는지, `env.md` 4절 금지 기능(모듈, 코루틴, `ranges` 뷰, `u8` 문자열, C++23 등)과 맨 `std::thread`가 없는지, Win32 헤더를 `Win32.h`로만 include하는지 확인한다. 검사기 자체를 나쁜 예시로 먼저 시험한다.
- **빌드와 동작 시험:** 컴파일러가 있으면 헤더를 뽑아 `tests/fixtures/cs2cpp-port/PatternTests.cpp`와 함께 C++20으로 빌드한다. MSVC는 C++ 워크로드가 온전할 때만 쓰고, 아니면 MinGW g++를 쓴다. 경고는 오류로 취급한다. 시험 항목은 이렇다.
  - NetCompat: 파싱·반올림·인덱서·예외 상속, 숫자·bool 문자열(.NET Framework 출력값과 비교)
  - 큐: 큐 16개 `RunOnCurrentThread`
  - 타이머: 두 모드와 콜백 안 `Dispose`
  - 바이트 순서 왕복, `FieldVisit`, 인코딩 변환
  - UDP: 루프백·동기 수신·멀티캐스트
  - 스레드 예외 종료: 예외를 출력하고 0이 아닌 코드로 끝나는지
- **C# 대체 클래스:** C# 컴파일러가 있으면 `csharp-helpers.md`의 코드를 뽑아 C# 7.3·경고 오류로 빌드하고, `tests/fixtures/cs2cpp-port/HelperTests.cs`로 C++과 같은 시나리오를 돌린다. 컴파일러는 VS2022 Roslyn `csc.exe`를 먼저 쓰고, 없으면 .NET SDK의 `csc.dll`을 쓴다.
- g++ 경로를 직접 줄 때는 `-Gpp <경로>` 또는 환경변수 `CS2CPP_GPP`를 쓴다. 이때는 MSVC가 있어도 g++로 빌드한다.

## 한계

- MSVC v143 빌드는 C++ 워크로드가 온전한 환경에서 아직 검증하지 않았다. 처음 대상 환경의 VS2022에서 시험 스크립트를 돌려 결과를 확인한다.
- 설정 파일 형식, XML 처리, `double.Parse` 같은 문화권 의존 서식은 프로젝트가 정할 일이라 `TODO(PORT)`로 남는다.
- C# 골든 기록기와 C++ 재생기는 별도 도구다. 이 스킬은 입력 목록 형식만 정의한다.
