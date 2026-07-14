# UNCHECKED_NULL — 누락된 널 값 검사

- **건수**: 34  |  **심각도**: 매우위험  |  **트랙**: C
- **Sparrow 설명**: 누락된 널 값 검사 체커는 널 여부를 확인한 적이 있는 값을 후 확인 없이 역참조하는 경우를 검출합니다.

## 지켜야 할 규칙 (무엇을 왜 검출)
null 반환 가능 API의 결과나 외부 입력을 검사 없이 역참조/전달하면 `NullReferenceException` 또는 하위 계층의 잘못된 상태로 이어진다. 방산 소프트웨어의 신뢰성시험 기준에서 null 검사 누락은 **입력검증·예외처리 결함**으로 분류된다. FORWARD_NULL 과 근본 위험(CWE-476)은 같으나, 여기서는 "검사 코드 삽입"이 표준 해법이다.

## 표준 매핑 (교차참조)
- CWE: **CWE-476** (NULL Pointer Dereference); 근원이 외부 입력이면 **CWE-252**(Unchecked Return Value)와도 교차
- 무기체계 보안약점 점검 목록: **187 항목 100% 적용(설정 확정)**; 개별 항목번호는 Sparrow 체커↔표준 매핑 추출 후 기입(대기)
- 행안부 SW보안약점(2021): "널 포인터 역참조"

## 진성 판별 기준
- **방아쇠 = 이전 검사 이력**: 동일 값이 코드 앞부분에서 이미 한 번 null 검사를 받은 이력이 있어(예: `if (x == null) { ... }` / `if (x != null) { ... }`) 분석기가 그 값을 nullable 로 인지하는데, **이후 다른 경로/라인에서 재검사 없이 역참조**한다. (FORWARD_NULL 과 유사하나, "앞선 null 검사 이력"이 방아쇠라는 점이 핵심.)
- 재역참조 지점에 도달하는 경로에 그 값을 확정적으로 non-null 로 만드는 대입/재검사가 **없다**.
- 값 자체가 null 가능함이 앞선 검사로 이미 드러나 있음(외부 API·반환값·역직렬화 결과 등이 그런 검사의 대상이 되었을 수 있음).

## 흔한 위양성 패턴
- 직전에 non-null 대입이 있으나 분석기가 흐름을 못 이음.
- `as` 뒤 곧바로 `is`/`!= null` 이 아닌 **다른 형태의 검증**(예: 별도 헬퍼 `EnsureNotNull`)을 통과 — 분석기가 헬퍼의 계약을 모름.
- 프레임워크가 non-null 을 보증하는 잘 알려진 속성(예: `sender`가 관례상 non-null). → 위양성 사유서.


## LLM 판단에 필요한 필수 문맥
- 같은 값에 대한 앞선 null 검사 이력과 이후 역참조 지점.
- 검사 이후 재대입, alias, out/ref 전달, 컬렉션 조회 등 값이 바뀔 수 있는 코드.
- null 검사를 수행하는 헬퍼 메서드의 계약.
- 역참조가 null 검사 분기 밖에서 실행 가능한지.

## 문맥 부족 시 보류 기준
- 이전 null 검사와 검출 역참조가 모두 보이지 않으면 보류한다.
- 검사 헬퍼 또는 guard 메서드의 효과를 알 수 없으면 `needs_context=true`로 둔다.
- 재대입/alias로 null 가능성이 사라졌는지 판단할 수 없으면 보류한다.

## 추가로 요청해야 할 코드 범위
- 검출 라인을 포함하는 전체 메서드.
- 같은 변수의 선언, 모든 대입, null 검사, 역참조 지점.
- guard/helper 메서드 구현부.
- 관련 필드/프로퍼티 초기화 코드.

## 수정 패턴 (C# 예시)
```csharp
// Before — 캐스팅/조회 결과 무검사
var ctrl = sender as MyControl;
ctrl.Refresh();                       // as 실패 시 null → NRE

var val = dict["key"];                // 키 없으면 KeyNotFound/…
Use(val);

// After (A) as + null 가드
var ctrl = sender as MyControl;
if (ctrl == null) return;
ctrl.Refresh();

// After (B) 패턴 매칭 (C# 7.x, net472 OK)
if (sender is MyControl ctrl)
    ctrl.Refresh();

// After (C) TryGetValue 로 검사와 조회 결합
if (dict.TryGetValue("key", out var val))
    Use(val);
```

## 검증 확인 조건 (G2)
- 빌드 통과.
- Sparrow 재분석 시 해당 라인 UNCHECKED_NULL 검출 소멸.
- 신규 검출 0 (추가한 분기가 EMPTY_CATCH/데드코드/새 NULL_RETURN 유발하지 않음).

## 기본 처리 분류
- [ ] 진성 → 수정 (위 패턴)
- [ ] 위양성 → 사유서 (non-null 보장 근거)
- [ ] 보류 → 사유 (판단 불가 시 지어내지 않음; frontier-handoff)
