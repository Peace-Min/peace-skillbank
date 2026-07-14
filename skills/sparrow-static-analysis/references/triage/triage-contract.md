# Track C 트리아지 파이프라인 계약 (triage-contract)

Sparrow(파수) 정적분석 **Track C**(의미/자원/널 계열, 사람·모델 판단이 필요한 체커) 항목을
"결정론 기계작업"과 "LLM/사람 판단"으로 **엄격히 분리**해 처리하는 파이프라인의 사양서다.

> 핵심 원칙: **판단 없는 기계적 작업 = 결정론 툴(.ps1). 판단만 LLM/사람.**
> 스크립트는 절대 진성/위양성을 스스로 판정하지 않는다. 스크립트는 매칭·조립·집계·게이트만 한다.

---

## 0. 대상과 전제

- 대상 코드베이스: **C# / .NET Framework 4.7.2**. 문서·프롬프트·수정 예시의 C#는 **C# 7.3** 문법만
  사용한다(`using (...) { }` 블록, using 선언 금지, switch 식 금지, nullable 참조형 금지).
- 실제 처리 대상은 **Track A/B 적용 후 잔여 항목**이다(A=결정론 자동수정, B=반자동). Track C는 그 나머지.
- 입력 산출물은 `SparrowXlsExport.exe`가 Sparrow 결과 `.xls`에서 뽑은:
  - `items/{ID}_{체커키}_{파일}_{라인}.md` — 항목별 md
  - `index.csv` — **UTF-8 with BOM**, 헤더 `md_file,ID,체커 키,위험도,파일명,라인,이슈 상태,체커명`
  - `checkers.md` — 체커별 요약
- 체커 가이드: `references/checkers/<체커키>.md` (Track C 13종). **파일명 == 체커 키(verbatim)**.
  각 가이드 섹션: `## 지켜야 할 규칙` · `## 표준 매핑` · `## 진성 판별 기준` ·
  `## 흔한 위양성 패턴` · `## 수정 패턴 (C# 예시)` · `## 검증 확인 조건 (G2)` · `## 기본 처리 분류`.

> **체커 키 조인은 index.csv의 `체커 키` 컬럼(verbatim, 무제한 길이)** 을 쓴다.
> 항목 md의 **파일명(`_`로 40자 절단·치환된 sanitized 이름)** 이 아니다.

---

## 1. 파이프라인 (단계별 = 결정론 / 판단 / 사람)

```
 [입력]  items/*.md  +  index.csv   (SparrowXlsExport 산출물)
    │
    ▼  ── [결정론] Run-Triage.ps1 prepare ─────────────────────────────
    │      index.csv 각 행의 `체커 키`로  references/checkers/<체커키>.md 사전조회.
    │      가이드 있음 → 요청 조립 requests/{ID}_{체커키}.md = 프롬프트 + 가이드 + 항목 (self-contained).
    │      가이드 없음 → unresolved.csv 기록 후 skip (Track A/B 소관 또는 무가이드).
    │      worklist.csv(상태=TODO) + 빈 verdicts/ 디렉터리 생성.
    │
    ▼  ── [판단] LLM 또는 사람 ───────────────────────────────────────
    │      requests/{...}.md 하나를 읽고 triage-prompt 규칙대로 판정.
    │      근거는 **반드시 가이드의 진성판별/위양성 기준에서** 인용.
    │      출력 = verdict JSON 하나 → verdicts/{ID}.json.
    │      확신 없으면 지어내지 말고 verdict=보류.
    │      소스 문맥 부족은 needs_context=true + missing_context로 기록.
    │      자료는 충분하지만 로컬 모델 판단이 어려운 경우만 needs_frontier=true.
    │
    ▼  ── [결정론] Run-Triage.ps1 collect ─────────────────────────────
    │      verdicts/*.json 검증(키·enum·조건부 필드) → triage-ledger.csv(원장) 집계.
    │      by-checker/<체커>.md = 그 체커의 진성 수정목록(커밋 단위 후보)+위양성/보류.
    │      형식 위반 verdict → invalid.csv.
    │
    ▼  ── [사람 + OSTES 코드측] 수정 적용 ─────────────────────────────
    │      진성 항목만 가이드 수정패턴대로 실제 코드 수정(= OSTES 레포측 작업).
    │      체커 단위로 묶어 G0~G3 게이트 통과 후 커밋.
    │
    ▼  ── [게이트 G0~G3] ──────────────────────────────────────────────
           G2 재검사는 사람이 Sparrow GUI로 재스캔 → 새 xls 공급 → Compare-Sparrow.ps1.
```

### 무엇이 결정론 / 판단 / 사람인가 (명확히)

| 단계 | 주체 | 성격 |
|---|---|---|
| 체커키 → 가이드 사전조회, 요청 조립 | `Run-Triage.ps1 prepare` | **결정론** (판단 0) |
| 진성/위양성/보류 판정, 수정 코드 작성 | LLM 또는 사람 | **판단** |
| verdict 검증·원장 집계·커밋단위 묶기 | `Run-Triage.ps1 collect` | **결정론** |
| 실제 코드 수정 적용 / 빌드 / 재스캔 | **OSTES 코드측(사람/개발자)** | 사람 |
| G2 재스캔용 새 xls 생성(Sparrow GUI) | **사람** | 사람 |
| before/after xls 비교·검출소멸 판정 | `Compare-Sparrow.ps1` | **결정론** |
| G3 최종 승인 | **사람** | 사람 |

---

## 2. Verdict JSON 스키마 (판정 1건 = JSON 1개)

키는 아래를 **정확히** 사용한다. `collect`가 이 스키마로 검증한다.

```json
{
  "id": "string", "checker": "string", "file": "string", "line": "string",
  "verdict": "진성|위양성|보류",
  "rationale": "가이드 기준을 인용한 판정 근거",
  "fix": { "lines": "string", "before": "C# 코드", "after": "C# 코드" },
  "false_positive_reason": "위양성일 때만, 가이드의 위양성 패턴 인용",
  "hold_reason": "보류일 때만",
  "needs_context": false,
  "missing_context": ["필요한 추가 문맥"],
  "needs_frontier": false,
  "cwe": "CWE-476", "weapon_item": "미매핑(187 추출 후 기입)"
}
```

조건부 필드(collect가 강제):
- `verdict = 진성` ⇒ `fix.before` / `fix.after` 채움. `false_positive_reason` / `hold_reason`은 빈값.
- `verdict = 위양성` ⇒ `false_positive_reason` 채움(가이드 위양성 패턴 인용). `fix`는 비움.
- `verdict = 보류` ⇒ `hold_reason` 채움. 소스 문맥 부족이면 `needs_context=true` 및 `missing_context` 채움.
  자료는 충분하지만 상위 모델 판단이 필요한 경우만 `needs_frontier=true`. `fix`는 비움.

---

## 3. G0~G3 게이트 체크리스트

체커 단위로 수정·커밋하기 전, 각 체커 배치에 대해 순서대로 통과시킨다.

- **G0 — diff 스코프**: 이번 커밋의 변경 파일이 **해당 체커가 가리키는 파일들로만** 한정.
  다른 체커/무관 파일이 섞이면 실패(트리아지 격리 원칙). (사람이 `git diff --name-only`로 확인.)
- **G1 — 빌드 통과**: 수정 후 net472 솔루션 빌드 성공(경고 증가 없음 권장). (OSTES 코드측.)
- **G2 — 검출 소멸 + 신규 0**: 사람이 Sparrow GUI로 **재스캔** → 새 `.xls` 산출 →
  `Compare-Sparrow.ps1 -Before <원본.xls> -After <재스캔.xls> -Checker <체커키>`가 **PASS**.
  PASS 조건 = 그 체커 after-count **0(검출 소멸)** AND **신규 검출 0(전체)**.
- **G3 — 사람 승인**: 진성 판정·수정·위양성 사유서를 사람이 최종 검토·승인 후 커밋.

> 커밋은 **체커 단위**로. 커밋 메시지 예: `sparrow(C): FORWARD_NULL n건 수정 (CWE-476)`.

---

## 4. 사용 워크스루

전제: `SparrowXlsExport.exe`로 이미 `out\index.csv` + `out\items\`가 만들어져 있음.
경로는 예시이며 환경에 맞게 바꾼다. (스크립트는 이 `triage/` 폴더에 있음.)

```powershell
# 1) [결정론] 요청 조립 — 특정 체커·심각도만 골라 최대 N건
.\Run-Triage.ps1 prepare `
    -Index    C:\Work\sparrow\out\index.csv `
    -ItemsDir C:\Work\sparrow\out\items `
    -GuidesDir ..\checkers `
    -Out      C:\Work\sparrow\triage `
    -Checker  FORWARD_NULL `
    -Severity 매우위험,높음 `
    -Max      50
#  → triage\requests\{ID}_FORWARD_NULL.md (self-contained),
#    triage\worklist.csv, triage\unresolved.csv, 빈 triage\verdicts\

# 2) [판단] 사람 또는 LLM이 requests\*.md 를 읽고 판정 → triage\verdicts\{ID}.json
#    (needs_context=true 이면 먼저 missing_context를 보강하고, needs_frontier=true 인 항목만 상위 모델에 이관)

# 3) [결정론] verdict 수거·검증·집계
.\Run-Triage.ps1 collect `
    -VerdictsDir C:\Work\sparrow\triage\verdicts `
    -Worklist    C:\Work\sparrow\triage\worklist.csv `
    -Out         C:\Work\sparrow\triage
#  → triage\triage-ledger.csv(원장), triage\by-checker\<체커>.md, triage\invalid.csv

# 4) [사람/OSTES] 진성만 가이드 수정패턴대로 실제 코드 수정 → 빌드(G1) → 체커단위 커밋

# 5) [사람] Sparrow GUI 재스캔으로 after.xls 생성 후 G2 게이트
.\Compare-Sparrow.ps1 `
    -Before C:\Work\sparrow\before.xls `
    -After  C:\Work\sparrow\after.xls `
    -Checker FORWARD_NULL `
    -Exe    C:\Users\CEO\Desktop\dotnet-gcdump-offline\sparrow-xlsexport\win-x64\SparrowXlsExport.exe
#  → 체커별 before/after 표 + PASS/FAIL (exit 0=PASS). PASS면 G3 승인 후 커밋 확정.
```

`prepare`/`collect`는 **멱등**하다(재실행 시 산출물을 깨끗이 덮어씀; `verdicts/`는 입력이라 보존).

---

## 5. 표준 매핑 메모

- 무기체계 보안약점 점검 목록 **187 항목은 CWE 기반**이며 **100% 적용(설정 확정)**.
- 따라서 매핑 기준은 **CWE**다(각 체커 가이드의 `## 표준 매핑` 참조; 예 FORWARD_NULL=CWE-476,
  RESOURCE_LEAK=CWE-772). verdict JSON의 `cwe`에 이를 기입한다.
- **187 항목번호(weapon_item)** 는 Sparrow 체커 ↔ 표준 매핑 추출이 끝난 뒤 기입한다.
  그전까지 verdict의 `weapon_item`은 `미매핑(187 추출 후 기입)`으로 둔다.

---

## 6. 파일 목록 (이 폴더)

- `triage-contract.md` — 본 사양서(앵커).
- `triage-prompt.md` — 판단 단계용 프롬프트 템플릿(`{{GUIDE}}`/`{{ITEM}}` 자리표시자 + JSON 스키마).
- `Run-Triage.ps1` — 결정론 오케스트레이터(`prepare`/`collect`).
- `Compare-Sparrow.ps1` — G2 게이트 툴(before/after xls 비교).
- `fixtures/` — 합성 픽스처 + `run-validate.ps1`(파이프라인 자체 검증).

### 검증 한계

- `Compare-Sparrow.ps1`은 **실제 Sparrow `.xls` 2개(전/후)** 가 있어야 스모크 테스트가 된다.
  `fixtures/run-validate.ps1`은 xls가 없으므로 Compare-Sparrow를 **건너뛴다**(문서화된 한계).
  Compare-Sparrow는 실제 재스캔 xls가 확보되면 별도로 스모크한다.
