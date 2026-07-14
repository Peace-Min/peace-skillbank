# UNCHECKED_NULL — null 미검사 사용 (unchecked null)

- **건수**: 34  |  **심각도**: 매우위험  |  **트랙**: C
- **Sparrow 설명**: null 을 반환/산출할 수 있는 값을 **검사 없이** 곧바로 사용한다. FORWARD_NULL 이 "앞 경로에서 null 이 성립됨"을 추적한다면, UNCHECKED_NULL 은 "null 가능 소스(외부 API·반환값·역직렬화 결과 등)를 검사 없이 사용"하는 지점 자체를 지목한다.

## 지켜야 할 규칙 (무엇을 왜 검출)
null 반환 가능 API의 결과나 외부 입력을 검사 없이 역참조/전달하면 `NullReferenceException` 또는 하위 계층의 잘못된 상태로 이어진다. 방산 소프트웨어의 신뢰성시험 기준에서 null 검사 누락은 **입력검증·예외처리 결함**으로 분류된다. FORWARD_NULL 과 근본 위험(CWE-476)은 같으나, 여기서는 "검사 코드 삽입"이 표준 해법이다.

## 표준 매핑 (교차참조)
- CWE: **CWE-476** (NULL Pointer Dereference); 근원이 외부 입력이면 **CWE-252**(Unchecked Return Value)와도 교차
- 무기체계 보안약점 점검 목록: 미매핑 (187 확보 시 "널 포인터 역참조" 항목)
- CERT-C/행안부/OWASP: 행안부 "널 포인터 역참조"; CERT EXP34-C

## 진성 판별 기준
- 사용 지점의 값이 **문서/시그니처상 null 가능**: `Find`, `FirstOrDefault`, `SingleOrDefault`, `as` 캐스팅, `GetService`, `ConfigurationManager[...]`, `Request[...]`, `TryGetValue` out, 역직렬화/파싱 결과.
- 사용 전 `!= null` / `?.` / `??` / 패턴검사(`is T t`) 중 **어느 것도 없음**.
- non-null 을 보장하는 상위 계약이 코드상 없다.

## 흔한 위양성 패턴
- 직전에 non-null 대입이 있으나 분석기가 흐름을 못 이음.
- `as` 뒤 곧바로 `is`/`!= null` 이 아닌 **다른 형태의 검증**(예: 별도 헬퍼 `EnsureNotNull`)을 통과 — 분석기가 헬퍼의 계약을 모름.
- 프레임워크가 non-null 을 보증하는 잘 알려진 속성(예: `sender`가 관례상 non-null). → 위양성 사유서.

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
