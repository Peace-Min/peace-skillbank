# Track C 전면 검수 기록 및 수정 계획 (2026-07-19)

이 문서는 5.6 SOL 서브 에이전트 검수 결과와 운영자 결정을 실제 코드 수정 전에 고정하기 위한 기록이다.

현재 상태:

- Track C는 Sparrow XLS를 LLM/사람 작업용 `requests/`로 패키징한다.
- 미등록 체커는 XLS 기반 fallback guide/request를 생성하도록 보완했다.
- GUI 최종 출력은 `requests/`만 남긴다.
- 아래 P1/P2는 아직 전부 구현된 상태가 아니다. 후속 커밋에서 이 문서를 기준으로 수정한다.

## 확정 운영 결정

### D1. Track C에서 Track A/B 포함 여부 옵션은 제거한다

Track C 실행 시점의 Sparrow XLS는 Track A/B 자동수정 실행 후에도 남은 잔여 검출로 본다.

따라서 XLS에 Track A/B 성격의 체커가 남아 있더라도, 그것은 자동화가 놓친 엣지케이스이며 LLM/사람 판단 대상으로 넘겨야 한다. 사용자가 Track A/B 포함 여부를 선택하게 두면 잔여 검출이 조용히 누락될 수 있다.

결정:

- Track C GUI에서 `Track A 가이드 포함`, `Track B 가이드 포함` 옵션을 제거한다.
- Track C package 생성은 기본적으로 `Tracks=A,B,C`와 동일하게 동작한다.
- `references/checkers/<CHECKER_KEY>.md`에 A/B/C 트랙이 있든 없든, XLS 행은 request 생성 대상이다.
- 전용 guide가 없는 체커도 fallback request를 생성한다.

예외:

- 테스트/자동화용 내부 CLI에서는 좁힌 재현을 위해 `-Tracks` 옵션을 유지할 수 있다.
- 일반 GUI/운영 문서에서는 Track C 전건 전달을 기본 계약으로 둔다.

## P1 수정 항목

### P1-1. Track C request가 "수정 지시서 작성"에서 끝나지 않도록 한다

문제:

- 현재 `triage-prompt.md`는 LLM에게 Markdown 수정 지시서를 작성하게 한다.
- 폐쇄망 로컬 LLM이 이 request를 받아 실제 소스를 수정해야 하는 운영에서는, 이 구조가 "보고서만 생성하고 코드 수정은 안 하는" 병목을 만들 수 있다.

수정 방향:

- request의 역할을 "수정 지시서 작성자"가 아니라 "실제 소스 수정 작업자"로 바꾼다.
- LLM이 파일 접근/수정 권한이 있으면 실제 파일을 수정하게 한다.
- 파일 접근이 없거나 문맥이 부족할 때만 Markdown patch/Before-After와 `문맥 필요`를 작성하게 한다.
- 출력 형식은 "작업 결과 보고"로 바꾸고, 실제 수정 여부, 수정 파일, 검증 필요 항목을 쓰게 한다.

완료 기준:

- 생성된 request를 읽은 LLM이 기본적으로 실제 파일 수정을 수행한다.
- "코드상 문제없으니 스킵" 또는 "수정 지시서만 작성"으로 끝나지 않는다.

### P1-2. Track C는 XLS 전건 request 생성을 기본 계약으로 한다

문제:

- 현재 GUI에는 Track A/B 포함 옵션이 있어 기본 C만 전달될 수 있다.
- 자동수정 후 남은 A/B 체커는 자동화가 놓친 엣지케이스인데, 옵션이 꺼져 있으면 LLM에게 전달되지 않는다.

수정 방향:

- GUI의 Track C 범위 옵션에서 A/B 체크박스를 제거한다.
- `BuildTrackCTracksValue()`는 GUI 경로에서 항상 `A,B,C`를 반환하거나, prepare 호출에서 track filter를 비활성화한다.
- GUI 설명 문구를 "Track C는 XLS 전건을 LLM requests로 만든다"로 바꾼다.
- 내부 CLI의 `-Tracks`는 테스트/정밀 재현용으로만 문서화한다.

완료 기준:

- GUI Track C 실행만으로 XLS의 모든 체커 키가 request 생성 후보가 된다.
- 가이드가 C로 분류되지 않은 A/B 체커도 request로 생성된다.

### P1-3. unresolved 행이 GUI 최종 출력에서 사라지지 않게 한다

문제:

- GUI는 최종 산출물로 `requests/`만 복사하고 temp 폴더를 삭제한다.
- `unresolved.csv`가 생기면 상세 정보가 사라진다.
- fallback 도입 후에도 `체커 키 없음`, item md 없음 같은 행은 unresolved로 남을 수 있다.

수정 방향:

- GUI 기준 최종 출력은 계속 `requests/`만 유지한다.
- 대신 unresolved가 있으면 `requests/_UNRESOLVED/` 또는 `requests/_UNRESOLVED.md`를 생성해 LLM/사람이 볼 수 있게 한다.
- unresolved가 1건 이상이면 GUI 로그와 상태에 명확히 표시한다.
- 가능하면 unresolved를 실패로 처리하지 말고, "처리 필요 항목" request로 남긴다.

완료 기준:

- GUI 실행 후 temp 삭제가 되어도 미처리 행의 ID, 체커 키, 파일, 라인, 사유가 최종 `requests/` 안에 남는다.
- 사용자가 Sparrow 항목 유실 여부를 확인할 수 있다.

## P2 수정 항목

### P2-1. 체커 필터 의미를 1차 파싱과 2차 prepare에서 통일한다

문제:

- `SparrowExporter`의 checker filter는 대소문자 무시 부분 일치다.
- `TriagePreparer` C# 구현은 대소문자 구분 완전 일치다.
- PowerShell 구현은 기본 비교가 대소문자 무시라 C#과도 다르다.

수정 방향:

- GUI에서 체커 필터를 유지한다면 한 단계에서만 적용한다.
- 권장: GUI Track C의 체커 필터는 정확한 체커 키 선택/입력으로 제한하고, prepare 단계도 동일한 비교 규칙을 사용한다.
- 부분 검색 UI가 필요하면 request 생성 전 preview/search 용도로만 둔다.

완료 기준:

- `FORWARD`, `forward_null`, `FORWARD_NULL` 입력 시 동작이 문서와 코드에서 일관된다.
- PS/Core byte-identical 테스트가 필터 케이스를 포함한다.

### P2-2. "그 라인만 고쳐라" 문구를 "TARGET LINE 포함 최소 범위"로 통일한다

문제:

- item md는 현재 대상 라인만 고치라고 강하게 지시한다.
- resource leak, try/catch, object initializer, using 변환 등은 인접 구문까지 수정해야 한다.
- 프롬프트의 "TARGET LINE을 포함한 최소 범위"와 충돌한다.

수정 방향:

- item md의 문구를 "TARGET LINE은 anchor이며, 해당 결함 제거에 필요한 최소 인접 범위까지 수정한다"로 바꾼다.
- 임의 리팩터링 금지는 유지한다.

완료 기준:

- LLM이 한 줄 제한 때문에 필요한 using/catch/finally/initializer 범위를 못 고치는 일이 줄어든다.
- 동시에 무관한 주변 코드 수정은 금지된다.

### P2-3. 실제 XLS 회귀 테스트의 고정 건수 의존을 제거한다

문제:

- `CoreTests`는 구버전 실제 XLS의 7170행/28체커 같은 숫자에 고정되어 있다.
- 최신 XLS가 바뀌면 PS/Core 결과가 같아도 실패한다.

수정 방향:

- 기본 회귀는 fixture-only로 둔다.
- 실제 XLS 테스트는 사용자가 파일을 명시했을 때만 수행한다.
- 실제 XLS 테스트의 핵심 검증은 고정 건수가 아니라 PS/Core 동일성, request 생성 수, unresolved 처리 여부로 둔다.
- 특정 XLS baseline이 필요하면 별도 baseline 파일을 명시적으로 저장하되, 기본 테스트에는 넣지 않는다.

완료 기준:

- 최신 Sparrow XLS를 넣어도 포맷/행 수 변화만으로 실패하지 않는다.
- PS/Core 불일치, request 누락, unresolved 손실은 계속 잡는다.

### P2-4. `ExceptionAnalyzer` 고유 명칭을 정책 문서에서 제거한다

문제:

- `project-conventions.md`에 폐기하기로 한 `ExceptionAnalyzer` 명칭과 전용 로그 표현이 남아 있다.
- Track C request에 이 명칭이 포함되어 로컬 LLM이 특정 프로젝트/도구를 전제로 오해할 수 있다.

수정 방향:

- "로컬 .NET Framework reference XML의 `<exception>` 문서에서 추출한 예외 후보"로 일반화한다.
- 해당 자료는 보조 근거이며, 실제 try 본문과 호출 경계, 프로젝트 정책을 함께 확인해야 한다고 명시한다.

완료 기준:

- `ExceptionAnalyzer` 문자열이 Track C request에 포함되지 않는다.
- 예외 후보의 출처가 로컬 .NET DLL/XML 문서라는 점이 명확하다.

## 후속 구현 순서

1. P1-3 unresolved 최종 requests 보존.
2. P1-2 Track A/B 옵션 제거 및 GUI 전건 전달.
3. P1-1 request prompt를 실제 수정 작업 지향으로 변경.
4. P2-1 checker filter 일관화.
5. P2-2 target line 문구 완화.
6. P2-4 ExceptionAnalyzer 명칭 제거.
7. P2-3 CoreTests 실제 XLS 고정값 제거.

## 검증 기준

수정 후 최소 검증:

```powershell
dotnet build .\skills\sparrow-static-analysis\SparrowRunner.Gui\SparrowRunner.Gui.sln -c Release

$tokens=$null; $errors=$null
[System.Management.Automation.Language.Parser]::ParseFile(
  (Resolve-Path ".\skills\sparrow-static-analysis\references\triage\Run-Triage.ps1"),
  [ref]$tokens,
  [ref]$errors
)
$errors

powershell -ExecutionPolicy Bypass -File .\skills\sparrow-static-analysis\references\triage\fixtures\run-validate.ps1
dotnet run --project .\skills\sparrow-static-analysis\tools\_internal\SparrowXlsExport.Core\CoreTests\CoreTests.csproj -c Release -- --fixtures-only
powershell -ExecutionPolicy Bypass -File .\skills\sparrow-static-analysis\references\triage\e2e-lab\run-e2e.ps1
```

운영 검증:

- 실제 최신 Sparrow XLS로 GUI Track C를 실행한다.
- 최종 `requests/` 아래 체커별 폴더와 `_UNRESOLVED` 항목을 확인한다.
- A/B/C 체커가 옵션 없이 모두 request 후보가 되었는지 확인한다.
