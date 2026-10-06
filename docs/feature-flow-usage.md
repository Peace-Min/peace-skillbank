# feature-flow 사용 가이드

요청 하나를 **인터뷰 → 명세 → 기획 → 개발 → QA → 위키**까지 에이전트 워크플로로 끝까지 진행하는 스킬이다.
외부망 Claude Code에서 **Claude 모델만으로** 돌아간다(다른 회사 모델 없음). **Windows 전용**(Windows PowerShell 5.1 이상,
게이트 명령을 `cmd.exe`로 실행)이라 macOS·Linux에서는 마스터가 시작하지 않고 알린다. 교차 모델 검수 대신 아래 네 겹의 견제를 쓴다.

1. **기계적 게이트**: 검수자를 부르기 전에 `ff.ps1 gate`가 단계별 검사를 한 번에 돌린다. 실패하면 검수자까지
   가지 않고, 게이트가 직접 반려 파일을 쓰고 FAIL을 기록한다.

   | 단계 | 게이트가 하는 일 |
   |---|---|
   | plan | TODO 형식(D·Q 항목, ID 중복 없음, evidence 줄) |
   | dev | 명세의 빌드·테스트 실제 실행 + 체크마다 실재하는 `파일:줄` 근거 + 기준 커밋 대비 diff(새 파일 포함, 줄바꿈만 바뀐 파일 거부) |
   | qa | 빌드·테스트 재실행 + Q 증거(실패 항목은 증거 파일이 있어야 검수자에게 넘어감) |
   | wiki | index 존재, 모든 상대 링크 연결 |
2. **맥락 분리**: 검수자는 매번 새 서브에이전트로 뜨고, 작업자의 설명이 아니라 명세·diff·근거 파일만 받는다.
3. **다른 모델**: 검수자는 항상 그 단계 작업자와 **다른 모델**이다(작업자보다 한 단계 위, 상한이면 한 단계 아래).
4. **읽기 전용 검수자**: `ff-reviewer`는 `Read, Grep, Glob`만 가진다. 지적만 하고 수정은 작업자가 한다.

마스터(메인 세션)는 안전하게 고칠 수 있는 막힘은 **스스로 한 번 해결**하고, 범위 안의 결정은 **직접 내리며**,
사람에게는 정말 필요한 것만 올린다.

## 호출

플러그인 설치 시(권장, 대상 프로젝트에서 실행):

```text
/peace-skillbank:feature-flow 로그인 5회 실패 시 계정 잠금 기능 추가
```

중단된 작업 이어가기:

```text
/peace-skillbank:feature-flow resume work/20261001-1530-로그인-5회-실패-시-계정-잠금
```

이 레포를 클론해 루트에서 쓰면 `/feature-flow`로도 노출된다(테스트용, `.claude/agents/`에 같은 서브에이전트 사본이 있다).

시작 전 조건: 대상 프로젝트가 git 저장소이고, 미커밋 변경이 없고, `work/`가 `.gitignore`에 있어야 한다.
`init`이 어긋나면 경고하고, 마스터가 먼저 정리하도록 안내한다(라운드 diff가 여기에 의존).

비대화형으로 돌릴 때는 요청에 범위·범위 밖·완료 기준·검증 명령을 모두 적고 "spec pre-approved"라고 명시하면
인터뷰를 건너뛴다.

## 흐름

```text
사람 ↔ 마스터(메인 세션)
  0. intake  인터뷰 → 00-context.md(프로젝트 시드) + 01-spec.md(범위 밖·검증 명령 필수) → 사람 승인   ← 필수 개입
  1. plan    ff-planner  → 02-todo.md (D=개발, Q=QA 항목, 독립 그룹은 [group:X] + files:) → gate → ff-reviewer
  2. dev     ff-developer → 코드 + D 체크(근거 필수) → gate → ff-reviewer
             (독립 그룹이 2개 이상이고 첫 라운드면 worktree에서 그룹별 병렬 개발 → 병합 → merge-evidence)
  3. qa      ff-qa-tester → evidence/qa/ 증거 + Q 체크 → gate → ff-reviewer
             실패 시 CAUSE: IMPL→dev / SPEC→plan / QA→QA 다시 / ENV→마스터가 먼저 해결
  4. wiki    ff-wiki-writer → docs/wiki/ (index + architecture + decisions) → gate → ff-reviewer
```

- 같은 단계 안에서는 2라운드부터 같은 작업자에게 새 지적만 이어서 보낸다(SendMessage). 맥락과 캐시를 유지해서
  다시 탐색하지 않는다. 모델이 바뀌거나 단계가 새로 시작되면(QA 반려 후 개발 등) 새로 띄운다. 검수자는 항상 새로 띄운다.
- 반려 예산은 둘로 나뉜다: 검수자 FAIL `MAX_ROUNDS`(기본 3), 게이트 FAIL `MAX_GATE_FAILS`(기본 3).
  줄 번호 하나 틀린 게이트 실패가 검수 라운드를 깎지 않는다.

### 마스터가 먼저 처리하는 것

| 상황 | 마스터의 처리 | 사람에게 가는 경우 |
|---|---|---|
| 작업자가 `BLOCKED_ENV`/`BLOCKED_PERMISSION` | 프로젝트 안에서 안전하게 고칠 수 있으면(선언된 의존성 설치, 이 실행이 띄운 프로세스 종료, 명세에 따른 폴더·설정 생성, 허용된 명령 직접 실행) 고치고 `MASTER_FIX`(`block:`) 기록 후 다음 라운드. 반려 예산은 그대로 | 시스템 설정·자격 증명·프로젝트 밖 변경이 필요하거나, 그 단계의 `block:` 개입(기본 1회)을 이미 썼을 때 |
| 반려 상한 도달 | 마지막 검수 결과들이 서로 어긋나거나 작업자가 잘못 읽었으면 `reviews/<단계>-r<N>-master.md`에 하나의 수정 목록으로 정리하고 `MASTER_FIX`(`loop:`) 후 다음 라운드. 반려 예산 초기화, 올라간 모델은 유지 | 정리할 수 없거나 `loop:` 개입(기본 1회)을 이미 썼을 때. 예산 초과 개입은 기록되지 않고 ff.ps1이 대신 중단을 기록 |
| `NEEDS_DECISION` | 승인된 범위 안의 결정(경계 조건, 이름·구조, 명세가 열어 둔 동작)은 직접 정하고 `ff.ps1 decision`으로 `## Decisions`에 `master-decided`로 기록 | 범위·완료 기준·공개 인터페이스가 바뀌는 결정, 작업당 `MAX_DECISIONS`(기본 3)를 넘는 결정 |

**마스터의 판단도 검수를 받는다.** 모든 검수자가 사용자가 덮어쓰지 않은 `master-decided`·`master-created` 항목을
승인된 범위와 대조해 검수 결과의 `DECISIONS:` 목록에 하나씩 판정을 남기고, 벗어나면 `NEEDS_DECISION`을 낸다.
결정은 모두 `ff.ps1 decision`으로 기록되고(`events.log`에도 `DECIDED` 한 줄), 사용자 결정은 `-Kind user`로,
마스터 항목을 뒤집을 때는 `-Overrides`로 남긴다.

- **판정 대조:** 마스터가 PASS·NEEDS_DECISION·FAIL을 기록하면 `ff.ps1`이 그 라운드의 검수 파일과 대조한다. 검수
  결과와 다르거나, 검수자가 서 있는 마스터 항목 하나라도 `DECISIONS:`에서 빠뜨렸으면 기록을 거부한다.
- **2차 의견:** 검수자가 마스터 항목에 이의를 내면, 사람을 부르기 전에 한 단계 위 모델의 새 검수자에게 그 항목만
  판정받는다(항목당 1회). 2차도 이의면 사람에게, 문제없다고 하면 `upheld`로 기록하고 계속 진행한다(이 FAIL은
  반려 횟수와 모델 상향에 들어가지 않는다). 마스터는 어느 경우에도 스스로 다시 결정하지 않는다. 검수자가 마스터 결정에 이의를 제기하면 마스터는 다시 결정하지 않고
반드시 사람에게 올린다. 완료 보고에 `master-decided` 항목과 `MASTER_FIX`가 모두 나열된다.

## 서브에이전트 모델 자동 선택

평소 세션은 **Opus 5.5(노력 수준 중간)** 로 두고 스킬을 호출하면 된다. 마스터는 서브에이전트를 부를 때마다
`ff.ps1 pick-model`로 모델을 정해 호출 인자로 넘긴다(호출 인자가 에이전트 파일의 `model:`보다 우선).
상세 규칙: `skills/feature-flow/references/model-selection.md`.

| 역할 | 기본 | 위험도 high (명세 `## Risk`) | 올림 |
|---|---|---|---|
| 기획 | opus | fable | 같은 단계 2회 반려 시 한 단계 위 |
| 개발 | D 항목 1~3개면 sonnet, 그 외 opus | opus | 2회 반려, 또는 QA IMPL 반려(마지막 사용자 재개 이후) 시 한 단계 위 |
| QA / 위키 | sonnet | QA만 opus | 2회 반려 시 한 단계 위 |
| 검수자 | 작업자보다 한 단계 위 (sonnet 작업자 → opus) | 최소 opus | 작업자가 상한이면 한 단계 아래. **항상 작업자와 다른 모델** |

- 상한은 SKILL.md의 `MAX_MODEL`(기본 fable, 비용을 묶으려면 opus).
- 고른 모델은 `events.log`에 `[model=sonnet] [reviewer=opus]`처럼 남는다.
- **노력 수준은 에이전트 파일에 고정**한다(기획·개발·검수 high, QA medium, 위키 low). 서브에이전트는 세션의
  노력 수준을 물려받지 않으므로, 세션을 medium으로 둬도 기획·개발은 high로 돈다. (`effort:` 필드는 Claude Code에
  구현돼 있으나 공식 문서 표에는 아직 없다.)
- 모델은 별칭(`opus`, `sonnet`, `fable`)으로 지정하므로 새 모델이 나와도 수정할 필요가 없다.
  `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1`이 설정된 환경에서는 그 값이 모든 선택을 덮어쓴다.

## QA 방법: 모델이 고르고, 규칙은 고정

프로젝트마다 QA 수단이 다르다(테스트가 있는 곳, 빌드가 안 되는 분석용 사본, GUI, 성능 문제). 그래서 **방법은
모델이 고르고**, 무엇을 증거로 인정할지·어디에 남길지·누가 판정할지·수동 항목을 어떻게 닫을지는 고정한다.
상세: `skills/feature-flow/references/qa-methods.md`.

**모델에게 맡기는 것**
- Q 항목마다 방법 선택: `auto`(테스트·CLI·스트레스) / `ui`(WPF 같은 프로세스 하네스, CDP, FlaUI) /
  `measure`(PerfView 등 측정) / `review`(실행 불가 시 단독 컴파일·코드 검토) / `manual`.
- 하네스·러너를 영구로 둘지 일회성 스크립트로 끝낼지. 영구 무인 러너면 명세 `- ui-test:`에 올려 게이트가 실행한다.
- 환경이 안 될 때의 우회(예: 폐쇄망이라 측정 결과 추출 도구 작성).

**고정 규칙 (게이트·검수자가 강제)**
1. Q 항목마다 `  - method: <종류> - <이 방법이 왜 증명하는지>` 필수 (기획 게이트).
2. `[regression]` Q 항목 최소 1개: 변경 옆의 기존 동작이 그대로인지 (기획 게이트).
3. `[fix]` 개발 항목은 수정을 되돌리면 테스트가 실패하는 로그 `evidence/dev/revert-<n>.log` 필수 (개발 게이트).
4. 증거는 원본째 `work/<id>/evidence/qa/`에: 명령·실제 출력·종료 코드, 스크린샷, 측정 원본(전후·2회 이상).
   요약만 있거나, 메모리에서 꾸민 화면·예전 결과는 검수자가 FAIL.
5. 판정은 다른 모델의 검수자가 원본을 직접 읽고 한다(측정 해석 포함). 작업자는 스스로 채점하지 않는다.
6. 수동은 최후 수단: `manual-checklist.md`에 항목마다 `- automation tried:`가 있어야 하고(`ff.ps1 manual-check`),
   사용자 보고 `Q<n>-manual.log`(확인자·시각·환경·관찰·결과)로만 닫힌다 (QA 게이트).
7. 게이트 명령(build·test·ui-test)마다 `VERIFY_TIMEOUT_MIN`(기본 20분) 초과 시 프로세스 트리 종료 후 FAIL.
   게이트가 돌린 러너의 산출물은 `evidence/<단계>/gate-r<N>/`에 따로 저장된다.

## 자동 재개

**대상:** 사용 한도나 API 오류로 턴이 끊겼고 **Claude Code는 켜져 있는** 경우. 앱을 닫거나 크래시하면 예약도
사라지므로(세션 전용) 그때는 사람이 `resume`한다. 상세: `skills/feature-flow/references/auto-resume.md`.

- 명세 승인 직후, 그리고 사람이 `resume`할 때마다 예약을 (다시) 건다: `CronCreate`로 약 30분마다
  (`17,47 * * * *`) `/peace-skillbank:feature-flow resume <작업폴더> --auto`. id와 시각은 `schedule.txt`에.
  쉬는 중일 때만 실행되고 **7일 후 만료**된다. `CronCreate`가 없으면 `/loop 30m ...` 또는 데스크톱 예약 작업.
- 매 실행마다 `ff.ps1 auto-check`가 판정하고, 할 일을 `ACTION` 줄로 직접 알려준다.

| 판정 | 조건 | 동작 |
|---|---|---|
| STOP | 완료, 명세 미승인, `BLOCKED_*`/`NEEDS_DECISION`/`LOOP_LIMIT`/반려 상한, `PAUSE` | 예약 삭제 |
| LIMIT | 24시간 내 자동 재개 3회 (유휴 여부보다 먼저 검사) | 예약 삭제, 짧은 보고 작성 |
| WAIT | events.log나 heartbeat(`lock`)가 45분 내 갱신 (실행 중이거나 다른 세션이 진행 중) | 아무것도 안 함 |
| RESUME | 그 외 | `auto-check`가 `RESUME ... auto`를 **직접 기록**한 뒤 `NEXT`부터 진행, 사용자에게 묻지 않음 |

- 카운터는 메모가 `user`로 시작하는 `RESUME`(사람의 재개)에서만 초기화된다. 자동 재개를 반복하거나 메모를
  바꿔도 상한을 우회할 수 없다.
- 모든 `ff.ps1` 작업 호출(event, gate, pick-model 등)이 heartbeat를 갱신한다.
- 사용자가 중간에 멈추면 마스터가 `PAUSE`를 기록하고 예약을 지운다.

## 남는 기록 (`work/<id>/`)

| 파일 | 내용 |
|---|---|
| `00-context.md` | 빌드/테스트/실행 명령, 주요 폴더, 규칙. 모든 에이전트가 재탐색 대신 읽는 시드 |
| `01-spec.md` | 승인된 명세 (범위 / 범위 밖 / 완료 기준 / 검증 명령 / 위험도 / `## Decisions`) |
| `02-todo.md` | D·Q 항목과 항목별 `evidence:` 근거 |
| `reviews/<단계>-r<N>.md` | 라운드별 검수 결과 원문 (게이트 실패 포함, 첫 줄 `VERDICT:`) |
| `evidence/dev/` | 라운드별 빌드·테스트 로그, diff, 병렬 모드의 `group-X.md` |
| `evidence/qa/` | QA 항목별 증거(명령·실제 출력·종료 코드·스크린샷·측정 원본), 자동화를 시도하고도 안 된 항목만 `manual-checklist.md` |
| `settings.txt` | 이 작업의 상한 설정 (`init`이 기록, 이후 모든 호출이 사용) |
| `base.txt` / `schedule.txt` / `lock` | diff 기준 커밋 / 자동 재개 예약 / heartbeat |
| `events.log` | 단계·상태 타임라인 (`ff.ps1`만 기록) |

진행 중에는 마스터에게 그냥 물어보면 된다("개발 단계 왜 반려됐어?"). 마스터는 기억이 아니라 위 파일을 읽고 답한다.

**대상 프로젝트의 `.gitignore`에 `work/`를 추가한다.** 위키(`docs/wiki/`)는 커밋 대상이다.

## 설정 바꾸기

**플러그인 설치에서는 SKILL.md를 고치지 않는다**(업데이트 때 덮어써진다). 대상 프로젝트에
`.claude/feature-flow-settings.txt`를 만들면 `init`이 기본값 위에 적용하고, 적용된 값을 `SETTINGS` 줄에 출처와 함께
출력한다. 잘못된 키나 값이면 `init`이 거부한다.

```text
# .claude/feature-flow-settings.txt
MaxModel=opus
MaxRounds=2
VerifyTimeoutMin=30
Parallel=off
AutoResume=off
```


- 기본값은 SKILL.md 상단(`MAX_ROUNDS`, `MAX_GATE_FAILS`, `MAX_QA_CYCLES`, `MAX_FIXES`, `MAX_DECISIONS`, `MAX_MODEL`, `VERIFY_TIMEOUT_MIN`, `PARALLEL`, `AUTO_RESUME`)에 있다. 클론해서 쓸 때만 직접 고친다.
  상한 값은 마스터가 `init`에 한 번 넘기면 `work/<id>/settings.txt`에 저장되고 이후 모든 호출이 쓴다.
  이미 시작한 작업은 `settings.txt`를 고친다.
- `MaxModel=inherit`: 모델 자동 선택을 끈다. `Parallel=off`: 항상 순차 개발. `AutoResume=off`: 예약 안 함.

## 에스컬레이션에 답할 때

결정이나 수동 확인 결과를 말하고 `resume`하면 된다. 마스터가 결정을 `01-spec.md`의 `## Decisions`에, 수동 QA
결과를 `evidence/qa/Q<n>-manual.log`에 기록한 뒤 이어서 진행한다(수동 QA 결과가 있으면 그 라운드는 QA 담당자를
건너뛰고 바로 게이트와 검수로 간다). 그래서 같은 이유로 다시 멈추지 않는다.

## 한계 (정직하게)

- Claude끼리의 검수는 다른 회사 모델과의 교차 검수보다 약하다. 그래서 검수자를 항상 다른 모델로 두고, 기계적
  게이트를 함께 쓴다. **테스트가 없는 코드베이스에서는 게이트가 약해진다**. 플래너가 테스트 작성 D 항목을 먼저 넣는다.
- QA 방법은 모델이 고르므로 방법의 적절성은 검수자 판단에 달려 있다. 같은 프로세스 렌더는 실제 입력·포커스·DPI를
  보지 못하고, UI Automation과 보이는 창은 로그인된 데스크톱 세션이 필요하다. 그런 항목은 시도 기록과 함께 수동으로 넘어간다.
- 토큰 사용량이 크다(단계마다 작업자·검수자 호출). 작은 수정에는 쓰지 않는다.
- 근거 검사는 파일·줄이 **존재하는지**만 본다. 그 코드가 맞는지는 검수자가 본다.
- 병렬 개발은 첫 개발 라운드, 깨끗한 작업 트리, 파일이 겹치지 않는 그룹이 2개 이상일 때만 쓴다. worktree에 격리된
  개발자는 메인 작업 폴더에 쓸 수 없어서, 자기 worktree 안의 `work/<id>/evidence/dev/group-X.md`에 근거를 쓰고
  마스터가 복사한다. 그룹 브랜치는 현재 커밋에서 갈라졌는지 확인한 뒤 `git merge --squash`로 차례로 적용하고,
  하나라도 충돌하면 전부 되돌리고 순차로 다시 개발한다. 병렬 이후의 다음 라운드는 새 작업자로 진행한다.

## 검증

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\feature-flow-fixtures.ps1
```

`ff.ps1`의 모든 명령을 임시 프로젝트에서 양성·음성 경로로 검사한다(근거 검사·절대경로, 게이트, 예산 분리,
MASTER_FIX, 모델 선택, 자동 재개 판정, 병렬 근거 병합, diff·줄바꿈, 위키 링크 등).

실제 데스크톱 세션 시험: 스킬과 `ff-*` 서브에이전트를 프로젝트 단위로 설치한 임시 프로젝트에서 실제
서브에이전트로 전체 흐름, 실제 CronCreate 발동 자동 재개, 결정 필요 → 재개 흐름을 확인했다.
