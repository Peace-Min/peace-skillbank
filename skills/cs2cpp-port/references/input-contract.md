# 입력 조건

이 스킬은 **C++에 대응이 없는 C# 기능이 C# 안에서 먼저 정리된 코드**를 받는다. 그 정리를 어떻게 했는지(사람, 다른 스킬, 작업지시)는 묻지 않는다. 아래 조건만 본다.

## 1. 남아 있으면 멈추는 것

코드 줄(주석 제외)에 아래가 있으면 그 파일은 변환하지 않는다. 위치 목록을 2절 형식으로 보고하고 멈춘다.

| 찾는 것 | C++에 없는 이유 | C#에서 먼저 바꿀 형태 |
|---|---|---|
| `Dispatcher`, `DispatcherTimer`, `SynchronizationContext` | WPF 스레드 마셜링 | `ActionQueueThread`(`csharp-helpers.md` 1절). `DispatcherTimer`는 `ThreadTimer` + 큐 `Invoke` |
| `System.Windows`, `INotifyPropertyChanged`, `ObservableCollection`, `ICommand` | WPF 형식·바인딩 | 일반 클래스·`List<T>`·메서드. WPF 값 형식(`Point` 등)은 같은 필드의 자체 struct |
| `DevExpress`, `Messenger.` 및 소스 없는 제3자 DLL | C++ 판이 없음 | 서비스는 자체 정적 등록부, 메시지는 `Event<T>`(`csharp-helpers.md` 3절) |
| `GetCustomAttribute`, `Activator.`, `GetProperties(`, `GetTypes()`, `DynamicMethod`, `ILGenerator`, `Type.GetType(` | 실행 중 리플렉션이 없음 | Attribute 값 → 가상 속성, 형식 생성 → 팩토리 표, 자동 등록 → 명시 등록, 자동 직렬화 → 클래스마다 명시 `Write`/`Read` |
| `Enum.GetValues`, `Enum.GetNames`, `Enum.IsDefined` | 열거형 목록이 없음 | 값을 나열한 정적 배열 |
| `async `, `await `, `Task.Run`, `Task.Factory`, `yield return` | 코루틴·작업 스케줄러 의미가 다름 | 전용 스레드 + 대기, 결과를 모은 `List<T>` |
| `new Timer(`, `System.Timers` | 스레드 풀 콜백 | `ThreadTimer`(`csharp-helpers.md` 2절). 재진입 방지가 있던 타이머는 건너뛰기 모드 |
| `ConfigurationManager` | app.config가 없음 | 설정 읽기를 한 정적 클래스로 모은다. C++ 구현은 `PORT_CONFIG.md`의 설정 형식을 따른다 |
| LINQ 메서드(`.Where(`, `.Select(`, `.OrderBy(`, `.ToList(` 등) | 지연 실행·안정 정렬·`checked` 합계 | 같은 결과의 반복문 |

C# 대체 클래스 파일 자체(5절)는 이 검사와 3절 검사에서 뺀다.

## 2. 보고 형식 (정리가 안 된 입력)

```text
### 포팅 전 정리 필요
| 파일:줄 | 찾은 것 | C#에서 먼저 바꿀 형태 (1절) |
```

C# 원본은 고치지 않는다. 정리는 이 스킬의 범위가 아니다.

## 3. 결정이 필요한 것 (보고 대상)

아래는 기계적으로 바꿀 수 없어 사람이 정한다. 결정은 그 위치 바로 위 주석으로 남긴다.

`Thread.Abort`·`Interrupt`, `Parallel.`, `ThreadPool`, `[ThreadStatic]`·`ThreadLocal`, `MethodInfo.Invoke`, `dynamic`, `Enum.Parse`, `Regex`, `decimal`, `XmlDocument`·`XDocument`, `BinaryFormatter`, 문화권 의존 서식(`double.Parse`, `DateTime.Parse`, 인자 없는 `ToUpper`), 런타임 예외(`NullReferenceException`·`InvalidCastException`·`IndexOutOfRangeException`·`DivideByZeroException`)를 잡아 흐름을 잇는 `catch`.

```csharp
// PREPORT-DECISION: <ID> <정한 내용 한 줄>
```

- `<ID>`는 프로젝트가 정하는 식별자다(예: `THR-02`). 형식은 묻지 않는다.
- 표식이 있으면 그 결정대로 옮긴다. 결정이 C++ 쪽 방식을 정하는 것이면(예: "`Regex`를 손으로 쓴 문자 비교로") 그대로 따른다.
- 표식이 없으면 그 부분만 변환하지 않고 `// TODO(PORT): 정리 단계 결정 필요 — <찾은 것>`을 남긴다. 파일의 나머지는 옮긴다.

## 4. 그 밖의 표식

| 표식 | 뜻 | 이 스킬의 처리 |
|---|---|---|
| `// PREPORT-VERIFY` (파일 첫 줄 근처) | 정리 단계의 검증 도구 코드 | 포팅하지 않는다 |
| `// PREPORT: <ID>` | 정리 단계에서 바꾼 위치 기록 | 무시한다. 추적 주석으로 옮기지 않는다 |

## 5. C# 대체 클래스 파일

입력에 `ActionQueueThread.cs`, `ThreadTimer.cs`, `Event.cs`처럼 **C# 대체 클래스 자체**가 있으면 그 파일은 C++로 번역하지 않는다. 같은 이름의 C++ 패턴 헤더(`concurrency.md`, `idioms.md` 3절)를 공용 프로젝트에 넣고, 그 파일을 쓰는 다른 파일만 옮긴다.

프로젝트가 다른 이름의 대체 클래스를 썼으면 `PORT_CONFIG.md`의 "대체 클래스 이름" 표(`project.md` 5절)로 대응시킨다. 동작이 `csharp-helpers.md`와 다르면(예: `Stop` 때 남은 작업을 실행함) 같은 이름으로 대응시키지 말고 보고한다.
