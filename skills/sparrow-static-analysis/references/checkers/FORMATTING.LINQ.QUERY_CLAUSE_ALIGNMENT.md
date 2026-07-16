# FORMATTING.LINQ.QUERY_CLAUSE_ALIGNMENT — LINQ 쿼리절 정렬

- **건수**: (실측 시 변동)  |  **심각도**: 낮음  |  **트랙**: B
- **Sparrow 설명**: LINQ문 안에서 from절 밑에 쿼리문들을 정렬해야 합니다.

> **대부분 Track A(SparrowSyntaxFix/SparrowSyntaxFix) 또는 Track B(SparrowCommentFix/SparrowCommentFix layout)가 자동 처리한다. 이 가이드는 도구가 못 고친 잔여를 LLM이 처리할 때 사용**한다.

## 지켜야 할 규칙 (무엇을 왜 검출)
LINQ 쿼리 식(query syntax)에서 `where`/`orderby`/`select` 등 후속 절은 **`from` 절과 열을 맞춰 정렬**해야 한다. **보안 결함이 아니라 스타일·가독성·표준 준수** 항목이다. 절이 들쭉날쭉하면 쿼리 구조가 한눈에 들어오지 않는다. Sparrow는 `from` 절 아래 후속 쿼리 절들이 정렬되지 않은 LINQ 문을 검출한다.

## 표준 매핑 (교차참조)
- **Rule 원문 미확보 — 확보 시 레퍼런스 보강.** 아래는 도메인 지식 기반 참고 매핑이다.
- C# Coding conventions의 LINQ 쿼리 서식(각 절을 정렬) 계열 지침.
- CWE: 스타일 항목이라 직접 매핑 없음(광의 **CWE-1078** 계열).
- 무기체계 보안약점 점검 목록: **187 항목 100% 적용**; 개별 항목번호는 Sparrow 체커↔표준 매핑 추출 후 기입(대기).

## 진성 판별 기준
- 쿼리 식이 여러 줄로 작성되었고, `where`/`orderby`/`group`/`select` 등 절의 시작 열이 `from` 절의 시작 열과 어긋나 있다.

## 이렇게 보여도 넘기지 말 것
스타일 항목이라도 **전건 수정**한다. 현재 정렬이 나름 규칙적이어도 `from` 기준으로 절을 맞춘다.
- 한 줄로 쓴 짧은 쿼리(`from x in xs select x`)는 다중 줄 정렬 대상이 아닐 수 있으므로, 규칙 정의(다중 줄 여부)를 확인한 뒤 처리한다(문맥 확보).
- 메서드 체인 구문(`xs.Where(...).Select(...)`)은 쿼리 식이 아니라 이 체커 대상이 아니다 — 대상 아님을 판정에 기록한다.
- `let`·중첩 `from`이 있으면 각 절을 같은 열에 맞추되 쿼리 의미(순서·범위)를 바꾸지 않는다.
- 현행 정렬이 의도처럼 보여도 표준은 `from` 기준 절 정렬이다 — 근거 확인 후 수정한다.

## 수정 패턴 (C# 예시)
```csharp
// Before — 후속 절이 from과 정렬되지 않음
var q = from n in numbers
          where n > 0
      orderby n
    select n;

// After — from 아래로 절 정렬
var q = from n in numbers
        where n > 0
        orderby n
        select n;
```

## 검증 확인 조건 (G2)
- 빌드 통과(net472 / C# 7.3) — 정렬(공백) 변경은 의미에 영향 없음.
- 재분석 시 해당 라인 FORMATTING.LINQ.QUERY_CLAUSE_ALIGNMENT 소멸.
- 신규 검출 0 — 절 순서를 바꾸지 않고 열 정렬만 조정했는지 확인.

## 기본 처리 분류
- [ ] 진성 → 수정 (from 기준 절 열 정렬)
- [ ] 보류 → 문맥 확보 후 수정 (단일 줄 쿼리/메서드 체인 여부 판단 불가 시 needs_context; 확보 후 반드시 수정)
