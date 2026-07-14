# Track A — 결정론적 자동 정리 (LLM 없이)

Sparrow 검출 중 **스타일/포맷 계열(버킷1)** 은 약한 LLM에게 시키지 않는다. Microsoft 자체 툴체인
(Roslyn 분석기 + `.editorconfig`)이 **의미보존 코드픽스**로 결정론적으로 처리한다. 반입물은
`bucket1-autofix.editorconfig`(순수 텍스트) **하나뿐** — 툴(`dotnet format`/VS)은 폐쇄망에 이미 있다.

## 대상 (버킷1) — 이 5종만
| Sparrow 체커 | Roslyn 규칙 | 예 |
|---|---|---|
| OBVIOUS_VARIABLE_TYPE / OBJECT_INSTANTIATION / LOOP_VARIABLE | IDE0007/0008 (`var`) | `int x=5;` → `var x=5;` |
| MISSING_PARENTHESIS_IN_EXPRESSION | IDE0048 | `a + b * c` → `a + (b * c)` |
| OBJECT_INITIALIZATION.NOT_USED_INITIALIZER | IDE0017 | `p.Name=..; p.Age=..;` → `new P { Name=.., Age=.. }` |

**검증됨(2026-07)**: net472 *레거시(non-SDK)* 더미 프로젝트에서 위 5종 전부 자동수정 확인.
**버킷1 밖**: 주석/여백(~2,000, `dotnet format` 미지원 → 후순위/커스텀), 보안·품질(~230 + OVERLY_CATCH
139 → LLM/사람). 이 문서는 버킷1 전용.

## 실행 (권장) — 한 번의 CLI 호출: `Run-TrackA.ps1`

반입물은 **텍스트 2개**뿐(`Run-TrackA.ps1` + `bucket1-autofix.editorconfig`). 툴(`dotnet format`)은 SDK
내장이라 반입 불필요. 대상 레포의 **fix 브랜치**에서:

```powershell
# 전체(var,괄호,이니셜라이저) + 규칙군별 자동 커밋
.\Run-TrackA.ps1 -Solution C:\Work\OSTES\OSTES.sln -Commit

# 먼저 무엇이 바뀔지만 보기(변경 안 함)
.\Run-TrackA.ps1 -Solution ...\OSTES.sln -DryRun

# 일부 규칙군만
.\Run-TrackA.ps1 -Solution ...\OSTES.sln -Rules var,parens
```

> **`-Commit`/`-DryRun` 둘 다 없이 실행하면** 러너가 `규칙별로 커밋할까요? (Y/N)` 물어봅니다(플래그 빼먹는 실수
> 방지). Y=규칙별 커밋, N=파일만 수정. 비대화형(CI/파이프)이면 안 물어보고 커밋 안 함.

러너가 하는 일: `.editorconfig` 자동 배치(**기존 것은 `.pre-tracka-<시각>.bak`로 백업 후 최신 bucket1로 덮어씀** —
버전 꼬임/충돌 방지. 기존 것을 유지하려면 `-KeepEditorConfig`) → 규칙군별 `dotnet format style --diagnostics`
→ `-Commit`이면 규칙군마다 `*.cs`만 커밋(`.editorconfig`는 워킹파일로 남김) → `dotnet format`이 레거시
프로젝트를 못 열면 경고 후 VS 경로 안내. **검증됨: net472 레거시 더미에서 5종 자동수정 + 규칙별 커밋 3개.**

**콘솔=요약 / 로그=전체 진단.** 규칙마다 콘솔에 `요약`(변경 파일 수)·`로드경고`·`커밋`(또는 "-Commit 미지정 →
커밋 안 함")을 찍고, **전체 진단은 실행 지점의 `Run-TrackA.<시각>.log`** 에 저장(`-LogDir`로 위치 변경). 커밋이
안 되거나 이상하면 그 로그를 확인/공유. (기존 `.editorconfig`가 이미 있으면 우리 규칙이 안 먹어 변경 0이 될 수
있으니, 그 경고가 뜨면 그 파일 내용부터 확인.)

> ⚠ 실행 후에도 **아래 3) 검증(빌드 + 스패로우 재분석)은 필수**. 러너는 수정만 하고 "스패로우가 지웠다"를
> 보장하지 않음(Roslyn 경계 != Sparrow 경계).

**워크스페이스 로드 경고가 뜰 때**(레거시에서 흔함): 치명적이진 않지만 *부분 로드=수정 누락* 신호일 수 있으니
`-Verbosity diagnostic`으로 정체를 확인. "could not resolve / project could not be loaded"면 부분 로드 →
**VS 경로로**. 최종 판단은 exit code가 아니라 **스패로우 재분석 후 건수**.

```powershell
.\Run-TrackA.ps1 -Solution ...\OSTES.sln -Rules var -DryRun -Verbosity diagnostic   # 숨은 로드 경고 노출
```

수동으로 하려면(러너 없이) 아래 절차를 그대로:

## 절차 (수동)

### 0) 설정 배치
`bucket1-autofix.editorconfig` 를 정리할 프로젝트/솔루션 루트에 **`.editorconfig`** 라는 이름으로 복사.

### 1) 실행 — 프로젝트 형식에 따라
- **레거시(구식 .csproj) = 기본 케이스 → Visual Studio** (가장 확실):
  - 솔루션 열기 → 규칙별 전구(💡) → **"솔루션에서 모두 수정(Fix All in Solution)"**, 또는
  - **분석 → 코드 정리(Code Cleanup)** 프로파일에 해당 fixer만 넣고 실행.
  - VS는 레거시 프로젝트를 네이티브 로드하므로 항상 동작.
- **대안 CLI** (SDK가 프로젝트를 로드하면 동작 — 검증 환경에선 레거시도 로드됨, 단 SDK 버전·VS 설치 의존):
  ```powershell
  dotnet format style <proj-or-sln> --severity info --verbosity diagnostic
  ```
  로드 실패하면 위 VS 경로로.

### 2) 커밋 — **규칙 하나씩**
전체를 한 번에 고치지 말 것. **규칙 1개 Fix-All → 커밋 → 다음 규칙**. 검수자가 "var 일괄 N건"
한 커밋을 *패턴*으로 검수 가능 (수천 파일 한 커밋은 검수 불가).

### 3) 검증 — **Sparrow 재분석 (필수)**
`dotnet format`/VS가 고쳤다 != Sparrow가 그 검출을 지웠다. **Roslyn 규칙 경계 ≠ Sparrow 경계**일 수
있으므로:
- 자동수정 후 **해당 파일/모듈 Sparrow 재분석** → 그 체커 건수가 실제로 줄었는지 확인.
- 잔존분이 있으면: `var_elsewhere = false` 로 좁히거나(과적용 원인), 남은 건 수동/개별 처리.
- 빌드 통과도 함께 확인(자동수정이 컴파일을 깨지 않았는지).

## 정직한 경계
- **churn 큼**: 규칙별 diff가 수백~수천 파일 → 규칙별 커밋 필수(§2). 신뢰성시험 재시험 부담을 규칙 단위로 관리.
- **`var_elsewhere = true`(기본, broad)**: Sparrow가 안 잡은 비-명백 타입도 var화할 수 있음. 딱 검출된
  것만 원하면 `false`. 트레이드오프: false면 일부 LOOP_VARIABLE(비명백) 잔존 가능.
- **1:1 보장 없음**: 이 트랙의 목적은 *"~4,100건을 LLM 없이 결정론으로 대량 소거"*이지 100% 소거가
  아니다. 잔존분은 버킷3(LLM/사람) 흐름으로 합류.
