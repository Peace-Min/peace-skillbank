# FORWARD_NULL — 널 역참조

- **건수**: 47  |  **심각도**: 매우위험  |  **트랙**: C
- **Sparrow 설명**: 널 값 역참조 체커는 널 상수나 널이 할당된 변수를 역참조하는 경우를 검출합니다.

## 지켜야 할 규칙 (무엇을 왜 검출)
null 이 될 수 있는 값을 검사 없이 역참조하면 `NullReferenceException`으로 프로세스가 중단된다. 방산 상주/제어 소프트웨어에서 이는 **가용성 결함(운용 중 크래시)**이며, 예외가 상위에서 삼켜지면 오동작이 은폐된다. 특히 Sparrow가 지목하는 FORWARD_NULL은 "이 경로에서는 null 이 실제로 성립함"을 데이터플로로 추적한 결과라 오검출률이 상대적으로 낮다.

## 표준 매핑 (교차참조)
- CWE: **CWE-476** (NULL Pointer Dereference)
- 무기체계 보안약점 점검 목록: **187 항목 100% 적용(설정 확정)**; 개별 항목번호는 Sparrow 체커↔표준 매핑 추출 후 기입(대기)
- 행안부 SW보안약점(2021): "널 포인터 역참조"

## 진성 판별 기준
- 역참조 지점에 도달하는 **경로 중 하나라도** 해당 참조가 null 이 되는 흐름이 존재한다.
- null 근원이 명확: (1) 앞에 `if (x == null) { ... }` 후 else/이후 라인에서 `x.` 사용, (2) `Find/FirstOrDefault/as/GetXxx` 등 **null 반환 가능 API**의 결과를 무검사 사용, (3) `out`/딕셔너리 `TryGetValue` 실패 경로.
- 역참조 전에 그 변수를 확정적으로 non-null 로 만드는 대입/검사가 **없다**.

## 이렇게 보여도 넘기지 말 것
아래처럼 "null 아님"으로 보여도 **스킵하지 말고**, 실제 파일을 열어 확정 여부를 확인한 뒤 처리한다(전건 수정).
- 앞선 로직상 절대 null 이 아님이 보장되는 듯 보이지만 Sparrow가 경로를 과대추정한 것처럼 보임 (예: 바로 위에서 `new`로 생성 후 조건 분기 안에서만 사용) — 실제 흐름에서 non-null 이 **확정**되면, 그 확정 라인이 스니펫에 보이지 않을 수 있으니 파일을 열어 확인한다. 확정이 코드로 드러나지 않으면 방어 가드를 추가해 수정한다.
- `Debug.Assert(x != null)` / 계약(Code Contracts) / 프레임워크 보장(예: 특정 이벤트 인자)이 non-null 을 보장하는 것처럼 보이나 분석기가 인식 못 하는 경우 — `Debug.Assert` 는 릴리스에서 제거되므로 가드로 인정하지 않는다. 런타임 가드(`if (x == null) ...`)를 추가해 수정한다.
- 확정 근거가 스니펫 밖(외부 경로)이라 지금 판단이 불가하면 `verdict=보류` + `needs_context=true`로 두고, 문맥 확보 후 반드시 수정한다.


## LLM 판단에 필요한 필수 문맥
- null 값이 만들어지는 지점부터 역참조 지점까지의 메서드 내부 흐름.
- 선행 null 검사, early return, throw, 재대입 여부.
- null 가능 값을 반환하는 호출 메서드의 계약 또는 본문.
- 조건문/루프/분기별로 역참조가 실행 가능한지.

## 문맥 부족 시 보류 기준
- 검출 라인만 있고 null 근원 또는 선행 가드가 없으면 진성 단정 금지.
- 같은 변수에 대한 재대입/검증 헬퍼의 효과를 알 수 없으면 `needs_context=true`로 둔다.
- Sparrow가 지목한 경로가 소스 조각에서 재현되지 않으면 보류한다.

## 추가로 요청해야 할 코드 범위
- 검출 라인을 포함하는 전체 메서드.
- null 가능 값을 반환하거나 할당하는 호출 대상 메서드.
- 관련 필드/프로퍼티 선언부와 초기화 코드.
- 필요 시 호출자 1단계와 입력 파라미터 보장 조건.

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
- [ ] 보류 → 문맥 확보 후 수정 (null 근원이 외부 경로라 판단 불가 시 needs_context; 지어내지 않고 문맥 확보 후 반드시 수정; frontier-handoff)
