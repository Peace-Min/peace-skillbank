# FORWARD_NULL — 널 역참조

- **건수**: 47  |  **심각도**: 매우위험  |  **트랙**: C
- **Sparrow 설명**: 널 값 역참조 체커는 널 상수나 널이 할당된 변수를 역참조하는 경우를 검출합니다.

## 지켜야 할 규칙 (무엇을 왜 검출)
null 이 될 수 있는 값을 검사 없이 역참조하면 `NullReferenceException`으로 프로세스가 중단된다. 방산 상주/제어 소프트웨어에서 이는 **가용성 결함(운용 중 크래시)**이며, 예외가 상위에서 삼켜지면 오동작이 은폐된다. 특히 Sparrow가 지목하는 FORWARD_NULL은 "이 경로에서는 null 이 실제로 성립함"을 데이터플로로 추적한 결과라 위양성률이 상대적으로 낮다.

## 표준 매핑 (교차참조)
- CWE: **CWE-476** (NULL Pointer Dereference)
- 무기체계 보안약점 점검 목록: **187 항목 100% 적용(설정 확정)**; 개별 항목번호는 Sparrow 체커↔표준 매핑 추출 후 기입(대기)
- 행안부 SW보안약점(2021): "널 포인터 역참조"

## 진성 판별 기준
- 역참조 지점에 도달하는 **경로 중 하나라도** 해당 참조가 null 이 되는 흐름이 존재한다.
- null 근원이 명확: (1) 앞에 `if (x == null) { ... }` 후 else/이후 라인에서 `x.` 사용, (2) `Find/FirstOrDefault/as/GetXxx` 등 **null 반환 가능 API**의 결과를 무검사 사용, (3) `out`/딕셔너리 `TryGetValue` 실패 경로.
- 역참조 전에 그 변수를 확정적으로 non-null 로 만드는 대입/검사가 **없다**.

## 흔한 위양성 패턴
- 앞선 로직상 절대 null 이 아님이 보장되지만 Sparrow가 경로를 과대추정 (예: 바로 위에서 `new`로 생성 후 조건 분기 안에서만 사용).
- `Debug.Assert(x != null)` / 계약(Code Contracts) / 프레임워크 보장(예: 특정 이벤트 인자)이 non-null 을 보장하나 분석기가 인식 못 함.
- 이 경우 코드 수정 대신 **위양성 사유서**(근거: 어느 라인에서 non-null 이 확정되는지).

## 수정 패턴 (C# 예시)
```csharp
// Before — null 반환 가능 결과를 무검사 역참조
var node = list.FirstOrDefault(n => n.Id == id);
Process(node.Value);            // node 가 null 이면 NRE

// After (A) 가드 후 조기 반환/분기
var node = list.FirstOrDefault(n => n.Id == id);
if (node == null) return;       // 또는 로깅 후 continue/throw 명시
Process(node.Value);

// After (B) null 조건 연산자 + 기본값 (역참조를 회피)
Process(node?.Value ?? defaultValue);
```
- 반환값이 "없을 수 있음"이 정상 의미면 (A)로 흐름을 명시적으로 갈라 처리. 없어선 안 되는 값이면 `throw new InvalidOperationException(...)`로 계약을 드러낸다(조용한 무시 금지).

## 검증 확인 조건 (G2)
- 빌드 통과 (net472 솔루션 빌드).
- Sparrow 재분석 시 **해당 파일/라인 FORWARD_NULL 검출 소멸**.
- 신규 검출 0 (특히 가드 추가로 인한 UNREACHABLE/데드코드, 새 NULL_RETURN 없음).

## 기본 처리 분류
- [ ] 진성 → 수정 (위 패턴)
- [ ] 위양성 → 사유서 (어느 라인에서 non-null 확정인지 근거)
- [ ] 보류 → 사유 (null 근원이 외부 경로라 판단 불가 시 지어내지 않음; frontier-handoff)
