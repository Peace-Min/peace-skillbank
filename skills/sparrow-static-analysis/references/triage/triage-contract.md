# Track C 작업 패키지 계약

Sparrow(파수) 정적분석 **Track C** 항목을 폐쇄망 LLM/사람이 실제 소스 수정에 바로 사용할 수 있도록
결정론적으로 패키징하는 사양이다.

> 핵심 원칙: GUI/스크립트는 판단하지 않는다. XLS를 안정적으로 분해하고, 체커 가이드와 항목을 합쳐
> self-contained 수정 요청 md를 만든다. 기본 워크플로우는 요청 md를 실제 소스 수정 작업으로 바로 연결한다.

---

## 0. 대상과 전제

- 대상 코드베이스: C# / .NET Framework 4.7.2.
- 수정 예시는 C# 7.3 문법만 사용한다.
  - `using (...) { }` 블록 문법 사용.
  - using 선언, switch 식, nullable reference type 문법 금지.
- 실제 처리 대상은 Track A/B 적용 후 잔여 항목이다.
- 체커 가이드는 `references/checkers/<체커키>.md`를 사용한다.
- GUI 기준 최종 산출물은 `requests/`뿐이다. `items/`, `index.csv`, `checkers.md`, `worklist.csv`, `unresolved.csv`는 내부/스크립트 검증용 보조 산출물이며 폐쇄망 LLM에게 넘기지 않는다.

---

## 1. 기본 파이프라인

```text
[입력] Sparrow 결과 xls/xlsx
   |
   v
[결정론] 통합 GUI Track C
   - requests/<체커>/<ID>_<체커>.md
   - requests/<체커>/_작업지침.md
   |
   v
[LLM/사람] requests md를 읽고 실제 소스 수정
   - 수정 가능: Before/After 기준으로 실제 코드 수정
   - 문맥 필요: 필요한 파일/심볼/호출부/예외 후보를 확보한 뒤 재작업
   |
   v
[사람] 빌드 + Sparrow 재분석 + Compare-Sparrow로 검출 감소 확인
```

## 2. 산출물 의미

- `requests/`: LLM/사람에게 전달할 self-contained 수정 요청. GUI가 생성하는 유일한 정상 산출물이다.
- `requests/<체커>/_작업지침.md`: 체커 단위 처리 기준.

CLI와 테스트 스크립트는 재현성 확인을 위해 `items/`, `index.csv`, `checkers.md`, `worklist.csv`, `unresolved.csv`를 만들 수 있다. 이 파일들은 파서/prepare 검증용이며 LLM에게 넘기는 기본 입력이 아니다.

## 3. 요청 md 처리 기준

각 `requests/<체커>/<ID>_<체커>.md`는 다음을 포함한다.

- 체커 가이드 전문.
- Sparrow 검출 항목 전문.
- 프로젝트 공통 처리 정책.
- 체커별 프로젝트 의무.

LLM/사람은 요청 md를 읽고 다음 형식의 Markdown 수정 지시를 작성한다.

- `수정 가능`: 실제 소스에서 적용할 최소 Before/After를 작성한다.
- `문맥 필요`: 지금 수정할 수 없는 이유와 필요한 추가 문맥을 쓴다.

false-positive skip은 없다. `문맥 필요`는 스킵이 아니라 문맥 확보 후 수정해야 하는 대기 상태다.

## 4. 게이트

- G0 diff 스코프: 해당 체커가 가리키는 파일 중심으로 변경한다.
- G1 빌드: net472 솔루션 빌드 성공.
- G2 Sparrow 재분석: 대상 체커 검출 감소/소멸과 신규 검출 여부 확인.
- G3 사람 승인: 수정 의도, 영향 범위, 잔여 문맥 필요 항목을 확인한 뒤 커밋.

## 5. 도구

- 통합 GUI: `tools/Run-SparrowRunnerGui.cmd`
- XLS CLI: `tools/SparrowXlsExport`
- 요청 조립 스크립트: `references/triage/Run-Triage.ps1 prepare`
- 재분석 비교: `references/triage/Compare-Sparrow.ps1`
