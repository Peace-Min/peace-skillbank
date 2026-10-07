---
name: cs2cpp-port
description: C# 코드(.NET Framework 4.7.2/4.8 콘솔)를 C++20 콘솔 코드로 1:1 포팅할 때 따르는 고정 규칙. C++에 대응이 없는 기능(Dispatcher·리플렉션·async·LINQ·Timer 등)은 C#에서 먼저 정리된 것을 입력으로 받고, 남아 있으면 위치와 C#에서 바꿀 형태를 보고하고 멈춘다. 환경(VS2022 v143 x64, 표준 라이브러리 + Win32만, 프로젝트별 PORT_CONFIG.md로 일부 조정), 하위→상위 프로젝트 순서와 API_MAP, C#→C++ 타입·관용구 매핑, 람다 캡처·수명 규칙, .NET과 같은 의미의 호환 함수(NetCompat), 스레드·큐·타이머·UDP·바이트 직렬화 패턴과 같은 이름의 C# 대체 클래스, 단위 시험 분류와 입력 목록, 자가 점검표와 출력 형식을 담는다. "C# 코드를 C++로 포팅/변환해줘", "이 클래스 C++로 옮겨줘", "C#→C++", "C++로 이식", "port/convert/translate C# (.cs) to C++" 같은 요청에 반드시 사용한다. 일반 지식으로 즉흥 변환하지 말고 이 규칙을 먼저 읽는다.
---

# C# → C++20 포팅 규칙

너의 일은 **C# 원본의 동작을 바꾸지 않고** C++20으로 옮기는 것이다. 개선·재설계·최적화는 하지 않는다.
모르는 것은 추측해서 채우지 않고 `TODO(PORT)`로 남긴다.

## 1. 고정 환경

| 항목 | 값 |
|---|---|
| 언어 표준 | **C++20** (`/std:c++20`, C 파일은 `/std:c17`). 쓰는 기능·금지·C++20에서 바뀐 것은 `references/env.md` 3·4절 |
| 컴파일러 | **VS2022 v143, x64**, `.vcxproj`. 경고를 오류로 바꾸는 설정 포함 (`env.md` 1절) |
| 라이브러리 | **C++ 표준 라이브러리 + Win32(Winsock2 포함)만** |
| 형태 | 콘솔. C# 클래스 라이브러리는 **정적 라이브러리**(`.lib`) |
| 인코딩 | 소스 UTF-8 + `/utf-8`. 내부 문자열 UTF-8 `std::string` |
| 도구 | 검색은 **Grep·Glob·Read**, 파일 작성은 **Write·Edit** 도구. 셸은 빌드에만 쓴다 |
| 빌드 | 파일마다 빌드한다(6절). **빌드가 성공하기 전에는 완료라고 하지 않는다** |

대상 저장소에 `PORT_CONFIG.md`가 있으면 작업 전에 읽는다. 추가 허용 라이브러리, 설정·XML·서식·정규식 방식, 코드페이지, 대체 클래스 이름, 폴더, 포팅 제외, 입력 점검 예외, 정리 단계 결정만 바꿀 수 있고 위 표의 나머지는 고정이다(`references/project.md` 5절).

## 2. 작업 절차

한 번에 **C# 파일 하나(또는 클래스 하나)**만 옮긴다. 순서는 프로젝트 **하위→상위**, 프로젝트 안에서는 열거형·구조체 → 메시지 → 서비스 → 관리자 → `Program` (`references/project.md`).

1. **입력 확인** (`references/input-contract.md`). 코드 줄(주석이 아닌 부분)에 아래가 남아 있으면 변환하지 말고, 위치와 "C#에서 먼저 바꿀 형태"를 계약서 2절 형식으로 보고하고 멈춘다. C# 원본은 고치지 않는다. 단, `PORT_CONFIG.md`의 "포팅 제외"에 든 코드와 "입력 점검 예외"에 적힌 위치는 멈추지 않는다(계약서 1절 끝).
   `Dispatcher`, `DispatcherTimer`, `SynchronizationContext`, `System.Windows`, `INotifyPropertyChanged`, `ObservableCollection`, `ICommand`, `DevExpress`, `Messenger.`, `GetCustomAttribute`, `Activator.`, `GetProperties(`, `GetTypes()`, `DynamicMethod`, `ILGenerator`, `Type.GetType(`, `async `, `await `, `Task.Run`, `Task.Factory`, `yield return`, `new Timer(`, `System.Timers`, `Enum.GetValues`, `Enum.GetNames`, `Enum.IsDefined`, `ConfigurationManager`, LINQ 메서드(`.Where(`, `.Select(`, `.OrderBy(`, `.ToList(` 등)
   **보고 대상**(`Thread.Abort`, `Parallel.`, `ThreadPool`, `[ThreadStatic]`, `MethodInfo.Invoke`, `Enum.Parse`, `Regex`, `decimal`, `XmlDocument`, 런타임 예외 `catch` 등, 계약서 3절)이 있는데 그 위치에 `// PREPORT-DECISION:` 표식이 없고 `PORT_CONFIG.md` "정리 단계 결정"에도 없으면, 그 부분만 변환하지 말고 `// TODO(PORT): 정리 단계 결정 필요`를 남긴다.
   포팅하지 않는 파일: `// PREPORT-VERIFY`가 붙은 파일, 검증 도구 프로젝트, **C# 대체 클래스 파일**(`ActionQueueThread.cs`·`ThreadTimer.cs`·`Event.cs`, 또는 `PORT_CONFIG.md`의 대응 이름). 대체 클래스는 같은 이름의 C++ 패턴 헤더를 넣는다.
2. **의존 확인.** 이 파일이 쓰는 형식을 전부 적는다.
   - **이미 포팅됨**: 그 C++ 헤더와 해당 라이브러리의 `API_MAP.md`를 읽고 **거기 적힌 선언대로** 호출한다. C# 시그니처를 짐작해 쓰지 않는다.
   - **아직 포팅 안 됨**: 순서가 어긋났다. 변환하지 말고 "선행 포팅 필요: 형식 / 소속 프로젝트"를 보고하고 멈춘다.
   - **.NET 기본 라이브러리**: `references/types.md`, `idioms.md`, `netcompat.md`의 대응으로.
3. **변환.** `types.md` → `idioms.md` → 필요하면 `concurrency.md`, `serialization.md`, `net.md`. 패턴 코드는 그대로 쓰고, 같은 역할의 클래스를 새로 만들지 않는다. 공용 패턴 헤더가 이미 프로젝트에 있으면 include만 한다.
4. **파일 작성.** `Foo.cs` 하나당 `Foo.h` + `Foo.cpp`를 **Write 도구로** 쓴다. 네임스페이스는 C#과 같게. 같은 프로젝트 안에서 서로 참조하는 두 클래스(순환)는 두 헤더를 전방 선언으로 먼저 쓰고 `.cpp`를 차례로 쓴다.
5. **빌드.** 6절. 실패하면 오류만 고치고 다시 빌드한다.
6. **시험 분류.** 공개 메서드마다 `references/testing.md` 기준으로 시험 필요 여부와 입력 목록을 적는다.
7. **자가 점검.** `references/pitfalls-checklist.md`에서 **해당하는 항목만** 근거와 함께 적는다.
8. **API_MAP 갱신.** 이 파일의 공개 API가 C++에서 어떻게 바뀌었는지 `API_MAP.md`에 추가한다.

## 3. 핵심 규칙

1. **이름을 바꾸지 않는다.** 클래스·메서드·필드·열거값은 C# 이름 그대로. 속성 `Foo`만 `GetFoo()`/`SetFoo()`.
2. **추적 주석.** 함수 정의 위에 `// C#: <파일> <클래스.메서드>`. 줄 번호는 입력에 줄 번호가 있을 때만 적는다.
3. **정수 크기는 `<cstdint>`.** `long` → `int64_t` (MSVC `long`은 32비트). `char` → `char16_t`.
4. **모든 멤버 필드를 선언과 함께 초기화한다.** C#은 0으로 채우지만 C++은 쓰레기값이다.
5. **참조형을 값으로 복사하지 않는다.** C# class·배열·`List`·`Dictionary`는 참조형이다. 대입·인자 전달로 공유되던 것은 포인터·참조·`shared_ptr`로 (`idioms.md` 2절, 프로젝트가 만든 소유 관계표가 있으면 그대로).
6. **문자열은 `std::format`으로 만든다.** 숫자·bool·enum을 `+`로 이으면 포인터 연산이 된다. `double`·`float`·`bool`과 `F`·`D`·`X` 서식은 C#과 문자열이 달라 `NetCompat::ToString`·`ToStringF`·`ToStringD`·`ToStringX`로 먼저 바꾼다(`idioms.md` 7절).
7. **인자·피연산자 평가 순서.** C++은 함수 인자와 대부분의 이항 연산자 피연산자 순서가 정해져 있지 않다. 둘 이상에 호출·`++`·대입이 있으면 왼쪽부터 지역 변수로 나눈다.
8. **생성자에서 가상 함수를 부르지 않는다.** C#은 파생 재정의가 불리고 C++은 기반 버전이 불린다. 원본이 그렇게 하면 `Init()`/`Start()`로 나누고 보고한다.
9. **축소 변환·부호 섞인 비교는 명시한다.** `double`→`int`는 `static_cast`, `int`와 `uint` 비교는 둘 다 `int64_t`로 캐스트.
10. **`switch`의 모든 `case` 끝에 `break`.** 문자열 `switch`는 `if`/`else if`.
11. **`==`의 의미를 지킨다.** C# class의 `==`는 같은 객체인지 비교 → 포인터 비교. 값 비교였으면(재정의) `operator==`.
12. **속성 복합 연산.** `obj.Count++`, `obj.Value += 3` → `obj.SetCount(obj.GetCount() + 1)`.
13. **인덱서·파싱·반올림·예외는 `NetCompat`로.** `dict[k]` 읽기 → `NetCompat::DictAt`, `list[i]` → `ListAt`, `int.Parse` → `ParseInteger<int32_t>`, `Math.Round` → `MathRound`, C# 예외 형식 → 같은 이름의 `NetCompat` 예외, 숫자 문자열 → `NetCompat::ToString*` (`netcompat.md`).
14. **`lock`은 `std::recursive_mutex`로.** C# `lock`은 같은 스레드가 다시 잡아도 된다. 호출 사슬을 거친 재진입은 코드만 보고 판단하기 어려우므로 항상 `recursive_mutex`를 쓴다(`Monitor.Wait`는 `condition_variable_any`).
15. **나중에 실행되는 람다는 캡처를 정한다.** `Post`·타이머·구독·스레드 람다에 `[&]`·`[=]` 금지. 지역 변수는 이름을 적어 값으로, `this`는 수명이 보장될 때만(`idioms.md` 3절 "람다 캡처").
16. **스레드 예외·종료는 원본과 같게.** 원본 스레드 본문에 `catch`가 있으면 같게 옮긴다. 없으면 C#도 프로세스가 끝나므로 그대로 두고 보고에 적는다. 이벤트 핸들러 호출부에 원본에 없는 `catch`를 추가하지 않는다. `main` 첫 줄에서 `InstallTerminateLogger()`를 불러 .NET처럼 죽기 전에 예외를 출력한다. 스레드는 `std::jthread`로 만들고 본문을 `RunThreadBody`로 감싼다. MSVC는 `std::set_terminate`가 스레드마다 따로라 `main`의 처리기가 작업 스레드에 듣지 않는다(`idioms.md` 12절). 패턴 헤더의 스레드는 이미 감싸 두었다. C# `IsBackground` 스레드는 `Main`이 끝나면 그냥 죽지만 C++ 스레드는 `join`해야 하므로, 종료 신호가 없는 배경 루프는 보고한다.
17. **전문은 필드 단위.** 원본 `Write`/`Read`를 같은 순서로 `ByteWriter`/`ByteReader`에 옮긴다. 구조체 `memcpy` 금지.
18. **버그처럼 보여도 고치지 않는다.** `// TODO(PORT-BUG?): 내용`.
19. **없는 API를 만들지 않는다.** 확신이 없으면 `TODO(PORT)`.

## 4. 출력 형식

코드는 **Write 도구로 파일에만 쓴다. 응답에 코드 전문을 붙이지 않는다.** 파일 안에서는 함수 본문을 생략하지 않는다(`// ...` 금지).

```
### 변환 대상
- 원본: <C# 경로> (<클래스>)   생성: <Foo.h>, <Foo.cpp>

### 의존
| 형식 | 상태(포팅됨/선행 필요/.NET) | 근거(헤더·API_MAP 항목) |

### 작성한 파일
| 파일 | 함수·멤버 수 |

### 동작 차이
- C#과 달라질 수 있는 지점과 이유. 없으면 "없음"

### 시험 분류
| 메서드 | 분류(순수/상태/연결/불필요) | 이유 | 입력 목록(정상·경계·오류) |

### API_MAP 추가분
| C# 공개 API | C++ 선언 | 호출 형태 차이 |

### TODO(PORT) 목록
### 빌드
### 자가 점검 (해당 항목만, 나머지는 "해당 없음: A3, C5 …")
```

## 5. 참고 파일

| 파일 | 내용 |
|---|---|
| `references/input-contract.md` | 입력 조건: 남아 있으면 멈추는 것과 C#에서 바꿀 형태, `PREPORT-DECISION` 표식 |
| `references/csharp-helpers.md` | C# 대체 클래스 `ActionQueueThread`·`ThreadTimer`·`Event<T>` (C++ 패턴과 같은 이름·동작) |
| `references/env.md` | 프로젝트 설정·경고 오류화, 헤더 규칙, C++20에서 쓰는 것·금지·바뀐 것 |
| `references/project.md` | 하위→상위 순서, csproj→정적 라이브러리, `API_MAP.md`, 라이브러리 관문, `PORT_CONFIG.md` |
| `references/types.md` | 기본형·문자열·컬렉션·시간·열거형 매핑, 수치 의미 차이 |
| `references/idioms.md` | 클래스·속성·이벤트·람다 캡처·소유권·예외·포맷·로그·프로세스 수명 |
| `references/netcompat.md` | `NetCompat.h`: .NET 예외 형식, 인덱서, 파싱, 반올림, 숫자·bool 문자열 |
| `references/concurrency.md` | `ActionQueueThread`, `ThreadTimer`, `WaitHandle`, `Stopwatch`, lock·Interlocked |
| `references/serialization.md` | `ByteWriter`/`ByteReader`, 메시지 팩토리, `VisitFields`, 문자 인코딩 |
| `references/net.md` | `Win32.h`, Winsock UDP·멀티캐스트, TCP |
| `references/testing.md` | 메서드 분류, 시험 입력·골든 파일 형식 |
| `references/pitfalls-checklist.md` | 자가 점검표 |

## 6. 빌드

```bash
"/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe" -latest -requires Microsoft.Component.MSBuild -find "MSBuild/**/Bin/MSBuild.exe"
"<위에서 찾은 MSBuild.exe>" "<프로젝트>.vcxproj" -m -v:minimal -nologo -p:Configuration=Debug -p:Platform=x64
```

Git Bash에서는 스위치를 `/` 대신 `-`로 쓴다(`/p:`가 경로로 바뀌는 것을 막는다). C++ 워크로드가 없으면 그 사실을 그대로 보고하고 **"빌드 미확인, 미완료"**로 둔다. 빌드 3회 실패, 또는 셸 명령이 2회 시간 초과되면 멈추고 보고한다.
