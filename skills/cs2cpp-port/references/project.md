# 프로젝트 구성과 순서

## 1. 프로젝트 대응

| C# | C++ |
|---|---|
| 클래스 라이브러리 `.csproj` | **정적 라이브러리** `.vcxproj` (`StaticLibrary`) — 같은 이름 |
| 콘솔 실행 프로젝트 | 콘솔 `.vcxproj` (`Application`) |
| `<ProjectReference>` | vcxproj `<ProjectReference>` + 상대 include 경로 |
| 어셈블리 폴더 구조 | 같은 폴더 구조 |
| `public` 형식·멤버 | 헤더에 선언 |
| `internal` 형식·멤버 | 헤더에 노출하지 않음 (`.cpp` 안 익명 네임스페이스, 또는 `detail` 네임스페이스) |
| `InternalsVisibleTo` (시험용) | 시험 프로젝트가 `detail` 헤더를 include |
| 임베디드 리소스 | 대응 없음 → `TODO(PORT)` |

DLL로 만들지 않는 이유: STL 형식이 DLL 경계를 넘으면 모든 DLL의 빌드 설정을 똑같이 맞춰야 하고 export 매크로가 필요하다.

## 2. 순서

1. 솔루션의 `<ProjectReference>`로 의존 그래프를 만든다. 아무것도 참조하지 않는 프로젝트가 가장 하위다.
2. **하위 프로젝트부터** 하나씩 포팅한다. 위 프로젝트는 아래 프로젝트의 관문이 끝난 뒤 시작한다.
3. 프로젝트 안 순서: 열거형·상수 → 구조체·값 형식 → 메시지 클래스 → 유틸리티 → 서비스 → 관리자 → `Program`.
4. **공용 패턴 헤더**(`Win32.h`, `NetCompat.h`, `StrFormat.h`, `Logger.h`, `ByteStream.h`, `ActionQueueThread.h`, `ThreadTimer.h`, `Event.h`, `WaitHandle.h`, `Stopwatch.h`)는 **가장 하위 공용 프로젝트에 한 번만** 둔다. 정리 단계의 C# 대체 클래스와 같은 이름이다.

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
