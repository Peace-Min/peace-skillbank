# csharp-to-cpp-port 사용 가이드

기존 C# 프로젝트(.NET Framework 4.7 등)를 **Windows 네이티브 C++17**로 이식할 때, 폐쇄망의 약한
로컬 모델(Qwen 20~30B급)이 실행자여도 결과가 무너지지 않게 만드는 스킬이다. 핵심은 "규칙집"이 아니라
**결정론적 루프**다. 스크립트가 순서·프롬프트·빌드 검사·검증을 맡고, 모델은 **단위 하나**만 변환한다.

## 언제 발동하나

- "이 C# 프로젝트 C++로 변환해줘 / 포팅해줘 / 이식해줘"
- "`Services` 디렉토리부터 C++로 바꿔줘"
- "닷넷 코드를 네이티브로 옮겨야 해"
- "convert this C# to C++"

## 왜 프로젝트 전체를 한 번에 넘기지 않나

약한 모델에 전체를 넘기면 컨텍스트가 조용히 잘리고, 잘린 부분을 "본 것처럼" 지어내며, 어디서 틀렸는지
좁힐 수 없다. 반대로 디렉터리만 순진하게 나누면 다른 디렉터리 타입의 헤더를 지어낸다. 그래서:

| 대상 | 누가 | 범위 |
|---|---|---|
| 전체 트리 스캔, 단위 묶기, 의존 순서 산출 | 스크립트 (모델 아님) | 프로젝트 전체 |
| 작업 배정 | 사람 | 디렉터리 단위 (`-Scope`), 선행 의존은 자동으로 앞에 붙음 |
| 실제 변환 | 모델 | 단위 하나 + 의존은 **이미 이식된 헤더** 또는 **"먼저 이식하라" 선언 목록** |

단위 = `.cs` 파일 하나. 단, `partial` 클래스(예: `MainForm.cs` + `MainForm.Designer.cs`)는 한 단위로
묶이고, `AssemblyInfo.cs`·`*.g.cs`·`Resources.Designer.cs`·`Settings.Designer.cs`는 건너뛴다.
추측 스텁은 만들지 않는다. 의존이 아직 이식되지 않았으면 스크립트가 `UnportedDeps: N`을 출력하고
모델은 그 단위를 먼저 이식한다(`PORT_ORDER.txt`에서 항상 앞에 있다).

## 준비물

- Windows PowerShell 5.1 이상 (Python 불필요)
- C++ 컴파일러: MSVC(Visual Studio/Build Tools의 C++ 워크로드) 또는 MinGW-w64 g++ (CLion·MSYS2·Qt 번들도 자동 탐지)
- 로컬 모델 컨텍스트: 단위 프롬프트가 3천~1만 2천 토큰이고 Claude Code 안에서는 시스템 프롬프트·도구 스키마·SKILL.md·프롬프트 읽기가 더해지므로 **`num_ctx` 32768 이상(64k 권장)**. Ollama 기본값(4096)은 조용히 잘린다 (`OLLAMA_CONTEXT_LENGTH` 또는 Modelfile `num_ctx`). 붙여넣기 모드만 쓰면 16k로 충분하다.
- (동작 비교용, 선택) 원본 C# 프로그램의 빌드 exe와 입력 케이스 폴더

## 순서

### 1. 인벤토리 (1회)

```powershell
$skill = "C:\path\to\peace-skillbank\skills\csharp-to-cpp-port"
powershell -NoProfile -ExecutionPolicy Bypass -File "$skill\scripts\inventory-csharp.ps1" -SourceRoot C:\src\MyApp -CppRoot C:\src\MyApp.Cpp -Scope Services
```

`C:\src\MyApp.Cpp\port-work\PORT_INVENTORY.md`에서 프로젝트 종류, 단위·건너뜀 수, 기능 플래그(linq,
async, event, disposable, pinvoke, reflection, winforms, wpf, generics, inheritance ...), 순환 그룹,
모호한 참조를 본다. `PORT_ORDER.txt`가 이번 패스의 작업 목록이고(`prereq` 표시 = Scope 밖이지만 먼저
필요), `EXTERNAL_DEPS.txt`가 Scope 밖 의존이다.

WinForms/WPF가 잡히면 **UI 프레임워크를 먼저 정한다**. Win32면 `references\ui-win32.md`, MFC면
`references\ui-mfc.md`를 `<C++ root>\port-work\mapping-extra.md`로 복사하면 그 행이 매핑 표에 자동으로
붙는다(Qt 등은 사람이 같은 형식으로 작성). 그 파일이 없으면 `ui` 단위는 `UiMappingMissing: 1`로 거부되고
`todo`로 남는다. 매핑 표는 프로젝트당 한 번 사람이 확정한다. 기본값: `std::wstring`, C++17,
소유권은 인벤토리가 계산해 프롬프트에 넣음(SHARED -> `shared_ptr`, SINGLE -> 값/`unique_ptr`; 모델이 판단하지 않음), 모던 C++ 관용구(`[[nodiscard]]`, `noexcept`, `override`, `auto`, range-for) 필수, RAII, `async`는 동기로(`TODO(port)` 표시),
숫자·bool 문자열화와 UTF-8 파일 출력은 `PortSupport.h` 헬퍼.

### 2. 단위 루프 (모델이 반복)

Claude Code(VS Code 확장 + 로컬 LLM)에서는 이렇게만 말하면 된다:

> `C:\src\MyApp`의 `Services` 디렉토리를 `C:\src\MyApp.Cpp`로 C++ 변환해줘

스킬이 `PORT_ORDER.txt` 순서대로 한 단위씩:

1. `make-unit-prompt.ps1 -Unit <단위> -CppRoot <C++ root>` -> `UNIT_PROMPT.md` (매핑 표 + 규칙 + 원본 + 이식된 의존 헤더 + 직전 빌드 에러). `UnportedDeps`가 0이 아니면 그 의존부터, `BlockedDeps`가 0이 아니면 이 단위도 `blocked`로 표시하고 다음으로.
2. 모델이 파일 도구로 `<경로>.h` + `<경로>.cpp`를 직접 씀 (진입점 파일은 `.cpp` 하나, `wmain`)
3. 프롬프트 끝에 인쇄된 `finish-unit.ps1` 명령을 실행 (금지 패턴 스캔 -> 빌드 검사 -> 상태 갱신을 한 번에). `RESULT:` 줄대로:
   - `PASS` -> `NEXT:` 줄의 단위로 1부터
   - `FAIL (round k of 3)` -> 같은 단위로 1을 다시 (에러가 프롬프트에 들어감), **그 에러만** 고치고 3을 다시
   - `FORBIDDEN` -> 지목된 구문만 고치고 3을 다시 (라운드 소모 없음)
   - `BLOCKED` -> 3회 실패, `blocked` 표시됨. `NEXT:` 단위로 넘어가고 끝에 보고
   - 이미 이식했던 헤더를 다시 고쳐 PASS하면 의존 단위가 자동으로 `todo`로 돌아감(재빌드 필요)

### 3. 전체 링크 + 동작 비교

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$skill\scripts\build-check.ps1" -CppRoot C:\src\MyApp.Cpp -All -Link -OutputExe C:\src\MyApp.Cpp\out\MyApp.exe
powershell -NoProfile -ExecutionPolicy Bypass -File "$skill\scripts\parity-check.ps1" -CppRoot C:\src\MyApp.Cpp -CsExe C:\src\MyApp\bin\Release\MyApp.exe -CppExe C:\src\MyApp.Cpp\out\MyApp.exe -CasesDir C:\src\MyApp\cases
```

`cases\<이름>.args`(인자 한 줄, 빈 파일이면 인자 없음) + 선택 `<이름>.stdin`. 표준출력과 종료코드를
정규화해 비교하고 `PARITY_RESULT.txt`에 첫 차이 줄을 적는다. 한글 출력도 비교된다(양쪽 콘솔 인코딩을
UTF-8로 맞춘다). PASS면 `verified`.

## 산출물 (`<C++ root>\port-work\`)

| 파일 | 내용 |
|---|---|
| `PORT_INVENTORY.md`, `PORT_ORDER.txt`, `inventory.json` | 스캔 결과, 단위, 의존 순서 작업 목록 |
| `EXTERNAL_DEPS.txt` | `-Scope` 사용 시 바깥 의존 |
| `PORT_STATUS.md` / `status.json` | 단위별 `todo -> translated -> builds -> verified` / `blocked` / `skipped` |
| `UNIT_PROMPT.md` | 현재 단위의 self-contained 프롬프트 (`-Mode paste`면 다른 LLM에 붙여넣기 가능) |
| `BUILD_RESULT.txt` | PASS/FAIL/NO_COMPILER, 단위별 결과, 에러 목록 |
| `PARITY_RESULT.txt` | 케이스별 PASS/FAIL, 첫 차이 |

`<C++ root>\PortSupport.h`는 첫 실행 때 복사된다(고정 헬퍼, 단위별로 수정 금지). 위 파일들은
`.gitignore`에 있다(생성물). 외부에 공유할 때는 경로를 지운다.

## 다른 LLM에서 (도구 접근 없음)

`make-unit-prompt.ps1 ... -Mode paste`로 만든 `UNIT_PROMPT.md`를 그대로 붙여넣고, 답변을
`port-work\MODEL_RESPONSE.md`로 저장한 뒤:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$skill\scripts\apply-unit-response.ps1" -ResponsePath C:\src\MyApp.Cpp\port-work\MODEL_RESPONSE.md -CppRoot C:\src\MyApp.Cpp -Expect Services/Logger.h,Services/Logger.cpp
```

## 스킬 자체를 평가하기 (A/B)

`tests\run-csharp-to-cpp-eval-loop.ps1 -SourceRoot <C# 폴더> -Endpoint http://<host>:11434/v1 -Model qwen3:27b`
가 실제 루프를 돌려 `RUN_SUMMARY.md`에 첫 시도 통과율·최종 통과율·금지 패턴 수·parity를 적는다.
매핑 표나 규칙을 바꾼 뒤 같은 소스로 다시 돌려 비교하고, 어느 지표도 나빠지지 않을 때만 채택한다.
`-SkipModel`은 골든 코드를 응답으로 흘려 루프 배관만 검증한다.

## 막혔을 때

3회 실패로 `blocked`가 된 단위는 `BUILD_RESULT.txt`와 원본을 들고 `frontier-handoff` 스킬로 상위
모델에 넘긴다.

## 한계 (정직하게)

- 인벤토리는 정규식 스캔이다. 플래그는 근사치고, 상속이나 확장 메서드로만 닿는 타입은 놓칠 수 있다. 모호한 참조는 `inventory.json`에 남기니 사람이 확인한다.
- 동작 비교는 결정론적 콘솔 출력이 있는 프로그램에서만 의미가 있다. UI 앱은 사람이 검증한다.
- `async`/스레드는 동기로 이식하고 `TODO(port)`로 표시한다. 실제 동시성은 사람이 나중에 결정한다.
- 실제 바이너리는 MinGW g++로 검증됐다. MSVC 분기는 실제 cl/link 계약을 흉내 낸 가짜 툴체인으로 검증됐고, 진짜 MSVC 컴파일은 C++ 워크로드가 있는 PC에서 첫 실행 결과를 알려 달라.
