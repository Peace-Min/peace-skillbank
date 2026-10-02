# feature-flow 사용 가이드

요청 하나를 **인터뷰 → 명세 → 기획 → 개발 → QA → 위키**까지 에이전트 워크플로로 끝까지 진행하는 스킬이다.
다른 회사 모델(Codex 등) 없이 **Claude 세션만으로** 돌아간다. 교차 모델 검수 대신 아래 네 겹의 견제를 쓴다.

1. **기계적 게이트**: 검수자 AI를 부르기 전에 스크립트로 먼저 거른다. 실패하면 검수자까지 가지 않고 반려한다.

   | 단계 | 게이트 |
   |---|---|
   | plan | `check-todo -FormatOnly` (D·Q 항목 존재, ID 중복 없음, evidence 줄) |
   | dev | 빌드·테스트 실제 실행 + `check-todo -Prefix D`(체크마다 실재하는 `파일:줄`) + `diff`(기준 커밋 대비, 새 파일 포함) |
   | qa | 테스트 재실행 + `check-todo -Prefix Q -AllowOpen`(실패 항목은 증거 파일이 있어야 검수자에게 넘어감) |
   | wiki | `wiki-check` (index 존재, 모든 상대 링크 연결) |
2. **맥락 분리**: 검수자는 새 서브에이전트로 뜨고, 작업자의 설명이 아니라 명세·diff·근거 파일만 받는다.
3. **모델 분리**: 마스터가 호출마다 `pick-model`로 모델을 고른다(아래 "서브에이전트 모델 자동 선택").
   검수자는 해당 단계 작업자보다 약하지 않게 맞추므로, 작은 작업에서는 둘 다 sonnet일 수 있다
   (이때는 1·2·4번이 견제를 맡는다).
4. **읽기 전용 검수자**: `ff-reviewer`는 `Read, Grep, Glob`만 가진다. 지적만 하고 수정은 작업자가 한다.

## 호출

플러그인 설치 시(권장, 대상 프로젝트에서 실행):

```text
/peace-skillbank:feature-flow 로그인 5회 실패 시 계정 잠금 기능 추가
```

중단된 작업 이어가기:

```text
/peace-skillbank:feature-flow resume work/20261001-1530-로그인-5회-실패-시-계정-잠금
```

이 레포를 클론해 루트에서 쓰면 `/feature-flow`로도 노출된다(테스트용).

비용이 큰 워크플로라서 description을 "명시적으로 끝까지 진행을 요청할 때만, 작은 한 파일 수정에는 쓰지 않음"으로
좁혔다. 확실하게 쓰려면 슬래시 커맨드로 호출한다.

시작 전 조건: 대상 프로젝트가 git 저장소이고, 미커밋 변경이 없고, `work/`가 `.gitignore`에 있어야 한다.
`init`이 셋 중 하나라도 어긋나면 경고하고, 마스터가 먼저 정리하도록 안내한다(라운드 diff가 여기에 의존).

비대화형으로 돌릴 때는 요청에 범위·범위 밖·완료 기준·검증 명령을 모두 적고 "spec pre-approved"라고 명시하면
인터뷰를 건너뛴다.

## 흐름

```text
사람 ↔ 마스터(메인 세션)
  0. intake  인터뷰 → 00-context.md(프로젝트 시드) + 01-spec.md(범위 밖 필수) → 사람 승인   ← 필수 개입
  1. plan    ff-planner  → 02-todo.md (D=개발, Q=QA 항목)        → ff-reviewer
  2. dev     ff-developer → 코드 + D 체크(근거 필수) → [게이트] → ff-reviewer
  3. qa      ff-qa-tester → evidence/qa/ 증거 + Q 체크 → [게이트] → ff-reviewer
             실패 시 CAUSE: IMPL→dev / SPEC→plan / QA→QA 다시 / ENV→사람
  4. wiki    ff-wiki-writer → docs/wiki/ (index + architecture + decisions) → ff-reviewer
```

각 단계는 검수자가 `PASS`할 때까지 최대 `MAX_ROUNDS`(기본 3) 반복한다. 같은 지적이 연속 두 번 나오거나
상한을 넘으면 `LOOP_LIMIT`으로 멈추고 사람에게 보고한다. `BLOCKED_ENV`/`BLOCKED_PERMISSION`/`NEEDS_DECISION`도 즉시 보고한다.

## 서브에이전트 모델 자동 선택

평소 세션은 **Opus 5.5(노력 수준 중간)** 로 두고 스킬을 호출하면 된다. 마스터는 서브에이전트를 부를 때마다
`ff.ps1 pick-model`로 모델을 정해 호출 인자로 넘긴다(호출 인자가 에이전트 파일의 `model:`보다 우선).
상세 규칙: `skills/feature-flow/references/model-selection.md`.

| 역할 | 기본 | 위험도 high (명세 `## Risk`) | 올림 |
|---|---|---|---|
| 기획 | opus | fable | 같은 단계 2회 반려 시 한 단계 위 |
| 개발 | D 항목 1~3개면 sonnet, 그 외 opus | opus | 2회 반려, 또는 QA IMPL 반려(마지막 사용자 재개 이후) 시 한 단계 위 |
| QA / 위키 | sonnet | QA만 opus | 2회 반려 시 한 단계 위 |
| 검수자 | sonnet | opus | 해당 단계 작업자 모델보다 약하지 않게 맞춤 (예: 개발자가 opus로 오르면 검수자도 opus) |

- 상한은 SKILL.md의 `MAX_MODEL`(기본 fable, 비용을 묶으려면 opus).
- 고른 모델은 `events.log`에 `[model=sonnet] [reviewer=opus]`처럼 남는다.
- **노력 수준은 에이전트 파일에 고정**한다(기획·개발·검수 high, QA medium, 위키 low). 서브에이전트는 세션의
  노력 수준을 물려받지 않으므로, 세션을 medium으로 둬도 기획·개발은 high로 돈다. (`effort:` 필드는 Claude Code에
  구현돼 있으나 공식 문서 표에는 아직 없다.)
- 모델은 별칭(`opus`, `sonnet`, `fable`)으로 지정하므로 새 모델이 나와도 수정할 필요가 없다.
  `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1`이 설정된 환경에서는 그 값이 모든 선택을 덮어쓴다.

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
| WAIT | events.log나 마스터 heartbeat(`lock`)가 45분 내 갱신 (실행 중이거나 다른 세션이 진행 중) | 아무것도 안 함 |
| RESUME | 그 외 | `auto-check`가 `RESUME ... auto`를 **직접 기록**한 뒤 `NEXT`부터 진행, 사용자에게 묻지 않음 |

- 카운터는 메모가 `user`로 시작하는 `RESUME`(사람의 재개)에서만 초기화된다. `auto`나 다른 메모는 초기화하지
  않고 24시간 한도에 포함된다. 그래서 자동 재개를 반복하거나 메모를 바꿔도 상한을 우회할 수 없다.
- `NEXT`는 RESUME 기록을 건너뛰고 마지막 실제 진행 기록 기준으로 계산된다(명세 승인 직후·QA 반려 직후 재개도 정확).
- 사용자가 중간에 멈추면 마스터가 `PAUSE`를 기록하고 예약을 지운다. 45분 뒤 멋대로 재개하지 않는다.
- 같은 세션에서 대화 중일 때 예약이 실행되면 첫 줄에 `[feature-flow] auto resume of <작업폴더>`가 나온다.
- 한계: 서브에이전트 한 번이 heartbeat 없이 45분 넘게 돌면 유휴로 보일 수 있다.

## 남는 기록 (`work/<id>/`)

| 파일 | 내용 |
|---|---|
| `00-context.md` | 빌드/테스트/실행 명령, 주요 폴더, 규칙 — 모든 에이전트가 재탐색 대신 읽는 시드 |
| `01-spec.md` | 승인된 명세 (범위 / 범위 밖 / 완료 기준 / 검증 명령) |
| `02-todo.md` | D·Q 항목과 항목별 `evidence:` 근거 |
| `reviews/<단계>-r<N>.md` | 라운드별 검수 결과 원문 (게이트 실패 포함) |
| `evidence/dev/` | 라운드별 빌드·테스트 로그, diff |
| `evidence/qa/` | QA 항목별 증거(로그·스크린샷), 자동화 불가 시 `manual-checklist.md` |
| `base.txt` | 라운드 diff의 기준 커밋 |
| `schedule.txt` | 자동 재개 예약 id와 시각 |
| `lock` | 마스터 heartbeat 시각 (자동 재개가 실행 중인지 판단) |
| `events.log` | 단계·상태 타임라인 (`ff.ps1`만 기록). QA 반려는 `sendback=IMPL/SPEC`로 남아 재개 후에도 횟수가 유지됨 |

진행 중에는 마스터에게 그냥 물어보면 된다("개발 단계 왜 반려됐어?"). 마스터는 기억이 아니라 위 파일을 읽고 답한다.

**대상 프로젝트의 `.gitignore`에 `work/`를 추가한다.** 위키(`docs/wiki/`)는 커밋 대상이다.

## 설정 바꾸기

- 반복 상한·모델 상한: `skills/feature-flow/SKILL.md` 상단 `MAX_ROUNDS`, `MAX_QA_CYCLES`, `MAX_MODEL`.
  마스터가 `init`에 한 번 넘기면 작업 폴더의 `settings.txt`에 저장되고, 이후 모든 `ff.ps1` 호출(예약 실행 포함)이
  그 값을 쓴다. 이미 시작한 작업의 값은 `work/<id>/settings.txt`에서 바꾼다.
- `MAX_MODEL = inherit`: 모델 자동 선택을 끈다. 모델을 넘기지 않고 에이전트 파일의 `model:`을 쓴다.
- `AUTO_RESUME = off`: 자동 재개 예약을 걸지 않는다.
- 단계별 모델: `ff.ps1 pick-model`이 호출마다 결정(규칙은 `references/model-selection.md`, 상한은 `MAX_MODEL`).
  `agents/ff-*.md`의 `model:`은 pick-model 없이 부를 때의 기본값, `effort:`는 에이전트별 고정 노력 수준.

## 에스컬레이션에 답할 때

막힘·결정 필요로 멈추면 결정이나 수동 확인 결과를 말하고 `resume`하면 된다. 마스터가 결정을 `01-spec.md`의
`## Decisions`에, 수동 QA 결과를 `evidence/qa/Q<n>-manual.log`에 기록한 뒤 이어서 진행한다(수동 QA 결과가 있으면
그 라운드는 QA 담당자를 건너뛰고 바로 검사와 검수로 간다). 그래서 같은 이유로 다시 멈추지 않는다.

## 한계 (정직하게)

- 같은 회사 모델끼리의 검수는 Codex↔Claude 교차 검수보다 약하다. **테스트가 없는 코드베이스에서는
  게이트가 약해진다** — 기획 단계에서 테스트 작성 D 항목을 먼저 넣도록 플래너에 지시되어 있다.
- GUI·하드웨어처럼 자동으로 구동할 수 없는 대상은 QA가 결과를 지어내지 않고 `BLOCKED_ENV` +
  수동 체크리스트를 낸다.
- 토큰 사용량이 크다(단계마다 작업자·검수자 호출). 작은 수정에는 쓰지 않는다.
- `check-todo`는 근거 파일·줄이 **존재하는지**만 본다. 그 코드가 맞는지는 검수자가 본다.
  (기능시험에서 실제로 확인: 근거 위치가 엉뚱한 D 항목을 게이트는 통과시켰고 검수자가 FAIL로 잡았다.)
- 개발은 순차 실행이다(병렬 worktree 개발은 이번 버전에 없음).

## 다른 LLM에서

`skills/feature-flow/references/model-agnostic-prompt.md` 참고. 역할 파일(`agents/ff-*.md`)을 새 대화의
시스템 지시로 붙이고, 게이트는 `ff.ps1`로 돌린다.

## 검증

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\feature-flow-fixtures.ps1
```

`ff.ps1`의 init/event/check-todo/status를 임시 프로젝트에서 양성·음성 경로로 검사한다
(빈 줄 포함 줄 수, 근거 없는 체크, 없는 파일, 범위 밖 줄 번호, 산문만 있는 근거, plan 형식 게이트,
QA 실패 항목 증거, 루프 상한·QA 반려 상한, RESUME 리셋, NEXT 안내, git diff(새 파일 포함·work 제외), 위키 링크 검사).
줄바꿈만 바뀐 파일 감지(dev diff 게이트), 작업 폴더 밖 `evidence/` 거부, 모델 선택, 자동 재개 판정도 포함한다.

**실제 데스크톱 세션 시험(2026-10-02):** 스킬과 `ff-*` 서브에이전트를 프로젝트 단위로 설치한 임시 Python
프로젝트에서 실제 서브에이전트로 기획→개발→QA→위키를 끝까지 돌렸고(모델 선택 규칙대로 opus/sonnet 지정, 검수자
읽기 전용 확인, CronCreate 예약 생성·삭제), 개발 중 중단시킨 작업이 **실제 CronCreate 일회성 예약 발동**으로
`auto-check` → 자동 재개 → `done PASS`까지 진행되는 것을 확인했다. 서브에이전트 안에서 실제 모델·노력 수준이
무엇이었는지는 관찰할 수 없었다.
