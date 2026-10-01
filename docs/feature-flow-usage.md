# feature-flow 사용 가이드

요청 하나를 **인터뷰 → 명세 → 기획 → 개발 → QA → 위키**까지 에이전트 워크플로로 끝까지 진행하는 스킬이다.
다른 회사 모델(Codex 등) 없이 **Claude 세션만으로** 돌아간다. 교차 모델 검수 대신 아래 네 겹의 견제를 쓴다.

1. **기계적 게이트**: 매 라운드 빌드·테스트를 실제로 돌리고, `ff.ps1 check-todo`가 체크된 TODO마다
   실재하는 `파일:줄` 근거가 있는지 검사한다. 실패하면 검수자 AI까지 가지 않고 반려한다.
2. **맥락 분리**: 검수자는 새 서브에이전트로 뜨고, 작업자의 설명이 아니라 명세·diff·근거 파일만 받는다.
3. **다른 모델**: 작업자는 세션 모델(`inherit`), 검수자는 `sonnet`.
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

## 흐름

```text
사람 ↔ 마스터(메인 세션)
  0. intake  인터뷰 → 00-context.md(프로젝트 시드) + 01-spec.md(범위 밖 필수) → 사람 승인   ← 필수 개입
  1. plan    ff-planner  → 02-todo.md (D=개발, Q=QA 항목)        → ff-reviewer
  2. dev     ff-developer → 코드 + D 체크(근거 필수) → [게이트] → ff-reviewer
  3. qa      ff-qa-tester → evidence/qa/ 증거 + Q 체크 → [게이트] → ff-reviewer
             실패 시 CAUSE: IMPL→dev / SPEC→plan / ENV→사람
  4. wiki    ff-wiki-writer → docs/wiki/ (index + architecture + decisions) → ff-reviewer
```

각 단계는 검수자가 `PASS`할 때까지 최대 `MAX_ROUNDS`(기본 3) 반복한다. 같은 지적이 연속 두 번 나오거나
상한을 넘으면 `LOOP_LIMIT`으로 멈추고 사람에게 보고한다. `BLOCKED_ENV`/`BLOCKED_PERMISSION`/`NEEDS_DECISION`도 즉시 보고한다.

## 남는 기록 (`work/<id>/`)

| 파일 | 내용 |
|---|---|
| `00-context.md` | 빌드/테스트/실행 명령, 주요 폴더, 규칙 — 모든 에이전트가 재탐색 대신 읽는 시드 |
| `01-spec.md` | 승인된 명세 (범위 / 범위 밖 / 완료 기준 / 검증 명령) |
| `02-todo.md` | D·Q 항목과 항목별 `evidence:` 근거 |
| `reviews/<단계>-r<N>.md` | 라운드별 검수 결과 원문 (게이트 실패 포함) |
| `evidence/dev/` | 라운드별 빌드·테스트 로그, diff |
| `evidence/qa/` | QA 항목별 증거(로그·스크린샷), 자동화 불가 시 `manual-checklist.md` |
| `events.log` | 단계·상태 타임라인 (`ff.ps1`만 기록) |

진행 중에는 마스터에게 그냥 물어보면 된다("개발 단계 왜 반려됐어?"). 마스터는 기억이 아니라 위 파일을 읽고 답한다.

**대상 프로젝트의 `.gitignore`에 `work/`를 추가한다.** 위키(`docs/wiki/`)는 커밋 대상이다.

## 설정 바꾸기

- 반복 상한: `skills/feature-flow/SKILL.md` 상단 `MAX_ROUNDS`, `MAX_QA_CYCLES`.
- 단계별 모델: `agents/ff-*.md`의 `model:` (`inherit` / `opus` / `sonnet` / `haiku`).
- 폐쇄망 qwen 등 약한 로컬 모델: 게이트웨이가 모든 별칭을 같은 모델로 매핑하므로 모델 다양성은 사라진다.
  `MAX_ROUNDS = 2`로 낮추고, 기계적 게이트(빌드·테스트·check-todo)를 핵심 견제로 삼는다.

## 한계 (정직하게)

- 같은 회사 모델끼리의 검수는 Codex↔Claude 교차 검수보다 약하다. **테스트가 없는 코드베이스에서는
  게이트가 약해진다** — 기획 단계에서 테스트 작성 D 항목을 먼저 넣도록 플래너에 지시되어 있다.
- GUI·하드웨어처럼 자동으로 구동할 수 없는 대상은 QA가 결과를 지어내지 않고 `BLOCKED_ENV` +
  수동 체크리스트를 낸다.
- 토큰 사용량이 크다(단계마다 작업자·검수자 호출). 작은 수정에는 쓰지 않는다.
- `check-todo`는 근거 파일·줄이 **존재하는지**만 본다. 그 코드가 맞는지는 검수자가 본다.

## 다른 LLM에서

`skills/feature-flow/references/model-agnostic-prompt.md` 참고. 역할 파일(`agents/ff-*.md`)을 새 대화의
시스템 지시로 붙이고, 게이트는 `ff.ps1`로 돌린다.

## 검증

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\feature-flow-fixtures.ps1
```

`ff.ps1`의 init/event/check-todo/status를 임시 프로젝트에서 양성·음성 경로로 검사한다
(근거 없는 체크, 없는 파일, 범위 밖 줄 번호, 산문만 있는 근거, 루프 상한, RESUME 리셋 등).
