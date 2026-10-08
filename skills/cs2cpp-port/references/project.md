# 프로젝트 구성과 순서

## 1. 프로젝트 대응

| C# | C++ |
|---|---|
| 클래스 라이브러리 `.csproj` | **정적 라이브러리** `.vcxproj` (`StaticLibrary`) — 같은 이름 |
| 콘솔 실행 프로젝트 | 콘솔 `.vcxproj` (`Application`) |
| `<ProjectReference>` | vcxproj `<ProjectReference>` + 상대 include 경로 |
| 어셈블리 폴더 구조 | 같은 폴더 구조 |
| 솔루션 탐색기의 폴더 | `<프로젝트>.vcxproj.filters`를 같이 만든다. 필터 이름 = 디스크 폴더 경로(`Collection`, `Collection\Sub`), 파일마다 자기 폴더의 필터. C++ 프로젝트는 이 파일이 없으면 VS에서 모든 파일이 한 줄로 보인다 |
| `public` 형식·멤버 | 헤더에 선언 |
| `internal` 형식·멤버 | 헤더에 노출하지 않음 (`.cpp` 안 익명 네임스페이스, 또는 `detail` 네임스페이스) |
| `InternalsVisibleTo` (시험용) | 시험 프로젝트가 `detail` 헤더를 include |
| 임베디드 리소스 | 대응 없음 → `TODO(PORT)` |

DLL로 만들지 않는 이유: STL 형식이 DLL 경계를 넘으면 모든 DLL의 빌드 설정을 똑같이 맞춰야 하고 export 매크로가 필요하다.

## 2. 순서

1. 솔루션의 `<ProjectReference>`로 의존 그래프를 만든다. 아무것도 참조하지 않는 프로젝트가 가장 하위다.
2. **하위 프로젝트부터** 하나씩 포팅한다. 위 프로젝트는 아래 프로젝트의 관문이 끝난 뒤 시작한다.
3. 프로젝트 안 순서: 열거형·상수 → 구조체·값 형식 → 메시지 클래스 → 유틸리티 → 서비스 → 관리자 → `Program`.
4. **공용 패턴 헤더**(`Win32.h`, `NetCompat.h`, `Logger.h`, `ByteStream.h`, `ActionQueueThread.h`, `ThreadTimer.h`, `Event.h`, `WaitHandle.h`, `Stopwatch.h`)는 **가장 하위 공용 프로젝트에 한 번만** 둔다. C# 대체 클래스(`csharp-helpers.md`)와 같은 이름이다.

## 3. API_MAP.md

라이브러리마다 `API_MAP.md`를 둔다. 상위 프로젝트를 포팅할 때 호출 형태는 **이 표를 보고** 바꾼다.

```markdown
# API_MAP: <프로젝트 이름>

| C# 공개 API | C++ 선언 | 호출 형태 차이 | 비고 |
|---|---|---|---|
| `int Count { get; }` | `int32_t GetCount() const;` | `x.Count` → `x.GetCount()` | |
| `List<Item> Items { get; }` | `std::vector<Item>& GetItems();` | 참조 반환 | C#은 내부 리스트를 반환하고 호출자가 수정함 |
| `event Action<int> Changed` | `Event<int32_t> Changed;` | `+=` → `Subscribe` (id 보관) | |
| `bool TryGet(int k, out Item v)` | `bool TryGet(int32_t k, Item& v);` | `out` → 참조 | |
| `static Foo Instance` | `static Foo& Instance();` | `Foo.Instance` → `Foo::Instance()` | |
```

참조형을 반환하는 API는 "비고"에 **호출자가 수정하는지**를 적는다. 상위 포팅에서 값 복사로 옮기는 실수를 막기 위해서다.

## 4. 라이브러리 관문

다음을 모두 만족해야 그 라이브러리를 완료로 보고 상위로 넘어간다.

1. 빌드 성공 (경고 오류 설정 포함)
2. `testing.md`의 "시험 필요" 메서드가 골든 대조를 모두 통과
3. `API_MAP.md` 작성 완료 (공개 API 전부)
4. 남은 `TODO(PORT)`와 `TODO(PORT-BUG?)`를 목록으로 정리하고, 사람이 처리 여부를 결정

## 5. PORT_CONFIG.md (프로젝트 설정, 선택)

대상 저장소 루트(또는 C++ 솔루션 폴더)에 `PORT_CONFIG.md`가 있으면 **작업 전에 읽고**, 적힌 항목은 이 스킬의 기본값보다 우선한다. 없으면 기본값으로 한다. 적히지 않은 항목도 기본값이다.

```markdown
# PORT_CONFIG

## 추가 허용 라이브러리
| 이름 | include | 링크 | 쓰는 곳 |
|---|---|---|---|
| (없음) | | | |

## 정한 방식
| 항목 | 방식 |
|---|---|
| 설정 파일 | 예: INI를 GetPrivateProfileStringW로 / (미정) |
| XML | 예: 사용 위치 없음 / (미정) |
| 문화권 의존 서식 | 예: 고정 "C" 로캘, 소수점 '.' / (미정) |
| 정규식 | 예: 손으로 쓴 문자 비교 / (미정) |
| Encoding.Default 코드페이지 | 예: 949 고정 / CP_ACP |

## 대체 클래스 이름
| 프로젝트 C# 이름 | 이 스킬의 이름 |
|---|---|
| 예: `WorkQueue` | `ActionQueueThread` |

## 폴더
| C# 프로젝트 | C++ 프로젝트 폴더 |
|---|---|

## 포팅 제외
- 파일 또는 멤버, 이유(예: 사용처 0)

## 입력 점검 예외
| 파일·위치 | 걸린 낱말 | 이유 | 처리 |
|---|---|---|---|
| 예: `Service/QueueService.cs` | `Dispatcher` | 이름만 같음. 자체 `ActionQueueThread` 묶음 | 이름 그대로 옮긴다 |

## 정리 단계 결정
| ID | 대상(파일·범위) | 정한 내용 |
|---|---|---|
| 예: `C3` | `IO/*.cs`의 `decimal` 길이 | `int64_t`, 범위 밖이면 `NetCompat::OverflowException` |
```

| 항목 | 기본값 | 바꿀 수 있나 |
|---|---|---|
| 추가 허용 라이브러리 | 없음 (표준 + Win32만) | 예. 표에 없는 라이브러리는 여전히 금지 |
| 설정 파일·XML·문화권 서식·정규식 | 미정 → `TODO(PORT)` | 예. 적힌 방식대로 옮긴다 |
| `Encoding.Default` 코드페이지 | `CP_ACP` | 예. 번호를 적으면 `TextEncoding`에 그 번호를 쓴다 |
| 대체 클래스 이름 | `csharp-helpers.md`의 이름 | 예. 동작이 같을 때만 (`input-contract.md` 5절) |
| 폴더 대응 | C#과 같은 구조 | 예 |
| 포팅 제외 | 없음 | 예. 적힌 파일·멤버는 옮기지 않고, 입력 점검도 하지 않는다 |
| 입력 점검 예외 | 없음 | 예. 적힌 위치는 멈추지 않고 "처리"대로 옮긴다. 표에 없는 위치는 그대로 멈춘다 |
| 정리 단계 결정 | 없음 | 예. `// PREPORT-DECISION:` 표식과 같은 효력 |
| C++20, VS2022 v143 x64, UTF-8 `std::string`, `lock` → `recursive_mutex`, `NetCompat`, 정적 라이브러리 | 고정 | **아니오.** 패턴 코드가 이 전제로 쓰여 있다. 바꿔야 하면 스킬을 복사해 고친다 |

`PORT_CONFIG.md`의 내용이 이 스킬의 규칙과 부딪히면(예: 고정 항목을 바꾸라고 함) 따르지 않고 보고한다.
