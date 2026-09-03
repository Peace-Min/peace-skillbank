# Peace.Skillbank

개인용 LLM/에이전트 스킬 저장소.

A personal skill bank for reusable LLM/Codex workflows, scripts, and model-agnostic prompts.

이 저장소는 재사용 가능한 분석 절차, 스크립트, 프롬프트 템플릿을 보관하는 스킬뱅크다. Claude Code에서는 repo 루트에서 바로 프로젝트 스킬로 쓸 수 있고, Codex에서는 `skills/<skill-name>/SKILL.md`를 Skill로 복사하거나 참조해서 쓴다. Codex 밖의 LLM에서는 스크립트 출력물과 `references/`의 프롬프트를 직접 입력으로 사용한다.

## 목표

- 반복 가능한 작업 절차를 `SKILL.md`로 정리한다.
- 실수하기 쉬운 변환/검증 작업은 `scripts/`에 둔다.
- Codex에만 의존하지 않고 다른 LLM에도 넘길 수 있는 입력 파일과 프롬프트를 함께 둔다.
- 덤프, 로그, 분석 결과처럼 민감할 수 있는 산출물은 저장소에 커밋하지 않는다.

## 구조

각 스킬은 동일한 형태를 따른다(자세한 목록은 아래 "현재 스킬" 참고).

```text
skills/
  <skill-name>/
    SKILL.md            # 런타임 계약(YAML frontmatter: name + description)
    scripts/            # 결정적 변환/검증 도구 (PowerShell / Python)
    references/         # 프롬프트·로컬 코퍼스 (민감/라이선스 자료는 gitignore)
    agents/             # (선택) Codex 등 외부 에이전트 메타데이터

# 스킬 목록은 아래 "현재 스킬" 섹션 참고(여기 직접 나열하지 않아 드리프트 방지)
```

## Codex에서 사용

이 저장소는 스킬뱅크 구조를 사용한다. clone만으로 Codex가 자동 발견하는 repo-scoped skill 위치는 아니다.

사용 방법은 둘 중 하나를 선택한다.

- 필요한 스킬 폴더를 Codex skills 경로로 복사한다.
- 작업 프롬프트에 `skills/<skill-name>` 경로를 명시한다.

Codex repo-scoped 자동 발견이 필요하면 해당 스킬 폴더를 대상 프로젝트의 `.agents/skills/` 아래에 복사한다.

예:

```powershell
$skillName = "diagsession-memory-analysis"
$source = "C:\path\to\peace-skillbank\skills\$skillName"
$target = Join-Path $env:USERPROFILE ".codex\skills\$skillName"
Copy-Item -Recurse -Force -LiteralPath $source -Destination $target
```

## Claude Code에서 사용

### 클론 후 바로 사용

이 저장소는 Claude Code 프로젝트 스킬 진입점을 `.claude/skills/`에 포함한다. 폐쇄망에서 repo를
클론한 뒤 **repo 루트에서** Claude Code를 시작하면 바로 다음 커맨드가 노출된다.

```text
/diagsession-memory-analysis
/lightningchart-72
/frontier-handoff
/dmp-triage
/addsim-xml-report
/xml-report
/csharp-to-cpp-port
```

이미 실행 중인 세션에서 새로 클론했거나 `.claude/skills/`가 세션 시작 뒤 생겼다면 Claude Code를
재시작한다. 프로젝트 스킬은 Claude Code가 시작 디렉터리와 부모 디렉터리의 `.claude/skills/`를
자동 발견하는 방식이다.

### plugin marketplace 설치

이 저장소는 Claude Code marketplace 파일도 포함한다. GitHub에 push한 뒤 Claude Code에서 저장소 주소를 marketplace로 추가하면 plugin을 설치할 수 있다.

사람용 전체 사용법은 [diagsession-memory-analysis 사용 가이드](docs/diagsession-memory-analysis-usage.md)를 먼저 본다.

```text
/plugin marketplace add Peace-Min/peace-skillbank
/plugin install peace-skillbank@peace-skillbank
/reload-plugins
```

`/plugin install` 직후에는 커맨드가 현재 세션에 바로 등록되지 않을 수 있다. `/reload-plugins`를 실행하거나 Claude Code를 재시작한다.

이미 설치한 경우 marketplace를 갱신한 뒤 plugin을 업데이트하고 다시 reload한다.

```text
/plugin marketplace update peace-skillbank
/plugin update peace-skillbank@peace-skillbank
/reload-plugins
```

설치 후에는 plugin namespace를 붙인 호출을 사용한다. plugin으로 설치한 커맨드는 항상 `peace-skillbank:` namespace로 등록된다.

```text
/peace-skillbank:diagsession-memory-analysis C:\dumps\leak-test.diagsession

액션은 장비 목록 새로고침 30회 반복.
시작점은 DeviceRefreshService.RefreshAsync.
```

`/diagsession-memory-analysis`처럼 namespace 없는 짧은 형태는 plugin 설치만으로는 등록되지 않는다(이 경우 "등록된 커맨드가 없다"고 나온다). 짧은 형태가 필요하면 `commands/diagsession-memory-analysis.md`를 대상 환경의 `.claude/commands/`에 직접 복사해 개인 command로 둔다.

커맨드가 안 보이면 `/reload-plugins`를 먼저 실행하고, 그래도 없으면 `/plugin`에서 설치·활성(enabled) 상태와 Errors 탭을 확인한다.

로컬에서 테스트할 때는 저장소 루트에서 다음 명령을 사용한다.

```powershell
claude plugin validate .
claude --plugin-dir .
```

## Codex 밖의 LLM에서 사용

먼저 스크립트로 `LLM_MEMORY_INPUT.txt`를 만든 뒤, `references/model-agnostic-prompt.md`의 프롬프트와 함께 입력한다.

### 요구사항

- Windows PowerShell 5.1 이상 또는 PowerShell 7 이상
- .NET SDK 또는 runtime
- `dotnet-gcdump`

`dotnet-gcdump`는 PATH에 있거나, `C:\tools\dotnet-gcdump\dotnet-gcdump.exe`에 있거나, `-ToolPath`로 지정할 수 있어야 한다.

일반 온라인 환경에서는 다음 방식으로 설치할 수 있다.

```powershell
dotnet tool install --global dotnet-gcdump
```

오프라인 환경에서는 별도 오프라인 번들로 설치한 뒤 `-ToolPath`를 지정한다.

```powershell
$skillDir = "C:\path\to\peace-skillbank\skills\diagsession-memory-analysis"
powershell -NoProfile -ExecutionPolicy Bypass -File "$skillDir\scripts\extract-gcdump-reports.ps1" -InputPath C:\dumps\leak-test.diagsession
```

추출/분석 주요 산출물:

```text
LLM_MEMORY_INPUT.txt
MANIFEST.txt
reports/
ANALYSIS.md (분석 완료 후)
```

`LLM_MEMORY_INPUT.txt`는 기본적으로 전체 로컬 경로를 제거하고 파일명만 포함한다. 전체 경로는 `MANIFEST.txt`에만 기록된다.

외부 LLM에 넘기기 전에는 `LLM_MEMORY_INPUT.txt`를 한번 검토한다. 타입명, 네임스페이스, 프로젝트명 자체가 민감 정보일 수 있다.

`ANALYSIS.md`는 분석 결과와 후속 수정 세션용 handoff summary를 담는 표준 파일이다. `MANIFEST.txt`에서 입력 순서, `.diagsession` 내부 entry, 생성된 report 경로를 확인한다. 하나의 `.diagsession` 안에 여러 `.gcdump`가 있으면 archive entry 순서가 사용되므로 before/after 의미는 사용자가 직접 확인해야 한다.

이 스킬은 분석 전용이다. 실제 코드 수정, 패치, 커밋은 분석 결과의 handoff summary를 바탕으로 별도 작업에서 진행한다.

## 오픈소스 스킬 레포 관리 방식

이 저장소는 "각자 알아서 쓰라"는 형태를 피하기 위해 다음을 함께 유지한다.

- marketplace/plugin manifest: Claude Code에서 repo 주소로 설치 가능하게 한다.
- skill metadata: Codex와 Claude가 스킬을 발견하고 설명할 수 있게 한다.
- command alias: Claude Code에서 짧은 `/diagsession-memory-analysis` 진입점을 제공한다.
- README quick start: 설치, 호출, 출력물, 프라이버시 주의사항을 문서화한다.
- validation script: publish 전에 구조와 manifest를 검증한다.

## 완전 제거

플러그인 관리 UI가 남기는 캐시·설정 항목까지 한 번에 지우려면:

```text
tools\uninstall-peace-skillbank.cmd      더블클릭 - 계획을 보여주고 y/N 확인 후 삭제
```

제거 대상은 플러그인 캐시/마켓플레이스 등록, 개인 스킬 7종과 각 슬래시 커맨드,
`DMP_TRIAGE_*` 환경변수, `~\.claude.json`의 사용 기록이다. **다른 번들의 스킬(심볼릭 포함)과
무관한 플러그인은 건드리지 않으며**, 편집하는 JSON은 타임스탬프 백업을 남긴다.
`-WhatIfOnly`는 계획만 출력하고, `-KeepConfig`는 설정 파일을 건드리지 않는다.
덤프·분석 리포트·repo 클론은 삭제 대상이 아니다.

## 검증

스킬을 수정한 뒤 최소 검증을 수행한다.

실제 `.diagsession` 파일을 사용한 end-to-end loop 검증은 [DiagSession loop validation](docs/diagsession-loop-validation.md)을 따른다.

```powershell
$tokens=$null; $errors=$null
[System.Management.Automation.Language.Parser]::ParseFile(
  "skills\diagsession-memory-analysis\scripts\extract-gcdump-reports.ps1",
  [ref]$tokens,
  [ref]$errors
)
$errors
```

Codex skill validator가 있는 환경에서는 `skills/diagsession-memory-analysis`를 대상으로 검증한다.

저장소 기본 검증:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\validate.ps1
```

## 현재 스킬

- [`sparrow-static-analysis`](docs/sparrow-static-analysis-usage.md): Sparrow 정적분석 결과를 줄이기 위한 통합 GUI/자동화 스킬. Track A는 C# 코드 규칙 자동수정, Track B는 주석·레이아웃 규칙 자동수정, Track C는 Sparrow XLS를 폐쇄망 LLM에게 넘길 `requests/` 패키지로 변환한다. GUI 진입점은 `skills/sparrow-static-analysis/SparrowRunner.Gui/SparrowRunner.Gui.sln`이다.
- [`diagsession-memory-analysis`](docs/diagsession-memory-analysis-usage.md): Visual Studio `.diagsession` 또는 `.gcdump` 스냅샷에서 .NET managed heap 누수 분석용 LLM 입력을 생성하고, before/after 증가 타입을 중심으로 분석하는 절차.
- [`lightningchart-72`](docs/lightningchart-72-usage.md): LightningChart Ultimate SDK 7.2(Arction) API·프로퍼티·사용법을 로컬 7.2 소스(DLL API 인덱스 + 매뉴얼 + 프로젝트 코드)에 근거해서만 답하고, 인용·API 실재 검증으로 할루시네이션을 막는 스킬. 코퍼스는 라이선스 원본으로 로컬 생성(커밋 안 함).
- [`frontier-handoff`](docs/frontier-handoff-usage.md): 폐쇄망 약한/오프라인 모델로 작업하다 막히거나 할루시네이션이 날 때, 현재 코드·문제·시도·환경·요청을 프론티어 모델용 self-contained 프롬프트 1개로 묶어주는 스킬. `finalize-handoff.py`가 필수 응답 지시문(잘게 쪼갠 실행 단계)을 결정론적으로 보장(자동 시크릿 마스킹은 없음 — 입력 보안은 사용자가 관리).
- [`dmp-triage`](docs/dmp-triage-usage.md): Windows 프로세스 덤프(`.dmp`)를 폐쇄망에서 설치 없이 분석하는 마스터 CLI 스킬. 순수 PowerShell 사전판정(표준/행/크래시, 스레드·컨텍스트, 모듈) → cdb 네이티브 트랙(`!analyze -hang`, `!uniqstack`, `!locks`) → SOS 관리코드 트랙(PDB 없이 .NET 메서드 스택)을 거쳐 LLM용 `report.md`로 압축한다. LLM의 덤프 직접 파싱을 철칙으로 금지하며, USB 반입용 self-contained zip 패키징(`package`)을 지원한다.
- [`xml-report`](docs/xml-report-usage.md): 임의의 XML을 결정적 PowerShell 스크립트로 뎁쓰(계층)별 전수 분석해 항상 동일한 8섹션 자립형 HTML 보고서를 만드는 범용 스킬. 파싱/렌더링 요소 수 대조, SHA-256, 미분류 요소 명시로 신뢰성을 보장하고, LLM은 마지막 "문서 해석" 섹션(모델 생성 배지)만 작성한다. 도메인별 매핑 파일(`-MappingPath`)로 라벨/커넥션/브랜드를 교체할 수 있다.
- [`addsim-xml-report`](docs/addsim-xml-report-usage.md): `xml-report`와 동일 엔진의 AddSIM(국방 M&S) 특화판. BSM/플레이어/컴포넌트 XML의 문서유형 자동 판별, AddSIM 요소 한글 라벨, 커넥션 출발/도착 강조, 공개 논문 기반 배경지식(`references/addsim-structure.md`)을 내장하고, 폐쇄망 현장에서 미분류 요소를 `config/mapping.json`에 보강하는 캘리브레이션 워크플로를 제공한다.
- [`csharp-to-cpp-port`](docs/csharp-to-cpp-port-usage.md): 기존 C# 프로젝트(.NET Framework 4.7 등)를 Windows C++17로 **파일 하나씩** 이식하는 결정론적 루프. 스크립트가 전체 트리를 스캔해 의존 순서를 내고(디렉터리 단위 `-Scope` 배정 지원), 단위 프롬프트에 고정 매핑 표(`std::wstring`, RAII, `shared_ptr`, `PortSupport.h` 헬퍼)와 의존 선언(이미 이식된 헤더, 아니면 "먼저 이식하라" 선언 목록)을 넣고, MSVC/MinGW 빌드 검사 에러를 다음 프롬프트에 재투입하며, 금지 패턴 스캔과 C#-C++ 출력 비교(parity)로 검증한다. 약한 로컬 모델(Qwen 20B급)이 실행자여도 프로젝트 전체를 한 번에 넘기지 않게 설계됨.
