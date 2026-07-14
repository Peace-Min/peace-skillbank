# NULL_RETURN_STD — 표준 라이브러리의 널 반환 값 역참조

- **건수**: 6  |  **심각도**: 매우위험  |  **트랙**: C
- **Sparrow 설명**: 표준 라이브러리 널 반환 값 역참조 체커는 C# 표준 라이브러리 메소드 중에서 널을 반환할 가능성이 있는 메소드의 반환 값을 확인 없이 역참조하는 경우를 검출합니다.

## 지켜야 할 규칙 (무엇을 왜 검출)
C# 표준 라이브러리(BCL)에는 **실패/부재 시 null 을 반환**하는 메서드가 많다(문서화된 계약). 이런 메서드의 반환값을 null 검사 없이 곧바로 역참조하면 `NullReferenceException`으로 프로세스가 중단된다. 이는 NULL_RETURN 의 **BCL 특수형**(소비측 결함)으로, 반환이 null 일 수 있음이 라이브러리 계약에 이미 명시되어 있으므로 위양성률이 낮고 지적의 근거가 분명하다. 방산 상주/제어 소프트웨어에서 이는 가용성 결함이다.

## 표준 매핑 (교차참조)
- CWE: **CWE-476** (NULL Pointer Dereference)
- 무기체계 보안약점 점검 목록: **187 항목 100% 적용(설정 확정)**; 개별 항목번호는 Sparrow 체커↔표준 매핑 추출 후 기입(대기)
- 행안부 SW보안약점(2021): "널 포인터 역참조"
- .NET Framework Design Guideline: BCL 메서드의 "없으면 null" 반환 계약을 소비측이 검사해야 함

## 진성 판별 기준
- **null 반환 가능한 BCL 메서드의 결과를 무검사 역참조**한다. 대표 예:
  - `Type.GetType(name)` / `Assembly.GetType(name)` — 형식을 못 찾으면 null
  - `Assembly.GetEntryAssembly()` — 관리 진입점이 없으면 null
  - `Marshal.PtrToStringAnsi(...)` / `Marshal.PtrToStringUni(...)` — 포인터가 널이면 null
  - `XmlNode.SelectSingleNode(...)` — 매치 없으면 null
  - `HttpContext.Current` — 요청 컨텍스트 밖이면 null
  - `Regex.Match(...)` 후 실패한 `Match`(성공 여부 미확인 상태로 사용)
  - `ConfigurationManager.GetSection(...)` — 섹션 없으면 null
  - `Nullable<T>` 관련(`.Value` 무검사 접근 등) — "없으면 null" 계약 메서드 전반
- 반환을 받은 뒤 `!= null` / `?.` / `??` / 패턴검사(`is T t`) 중 **어느 것도 없이** `.멤버`·인덱싱·메서드 호출로 역참조한다.

## 흔한 위양성 패턴
- 입력이 항상 유효해 해당 BCL 메서드가 실제로는 null 을 반환하지 않음이 상위 계약으로 보장되지만, 분석기가 보수적으로 판단 → 위양성 사유서(어느 근거로 null 이 불가능한지 명시).
- 앞선 검증(예: 존재 확인/형식 등록 보장) 이후라 non-null 이 확정되나 분석기가 흐름을 못 이음.

## 수정 패턴 (C# 예시)
```csharp
// Before — BCL 메서드의 널 가능 반환을 무검사 역참조
var t = Type.GetType(typeName);
var inst = Activator.CreateInstance(t);   // t 가 null이면 NRE

// After — 반환을 지역변수로 받아 null 검사 후 사용
var t = Type.GetType(typeName);
if (t == null) return null;               // 또는 예외/로깅으로 정책 명시
var inst = Activator.CreateInstance(t);

// 또는 null 조건/병합 연산자로 역참조 회피
var name = Assembly.GetEntryAssembly()?.GetName().Name ?? "unknown";
```
- 원칙: **BCL 반환을 지역변수로 받아 null 검사 후 사용**하거나 `?.`/`??` 로 역참조를 회피한다. "없으면 오류"면 `throw`/로깅으로 계약을 드러낸다.

## 검증 확인 조건 (G2)
- 빌드 통과.
- Sparrow 재분석 시 해당 라인 NULL_RETURN_STD 소멸.
- 신규 검출 0 (추가한 가드가 데드코드/EMPTY_CATCH/새 NULL 결함을 만들지 않는지).

## 기본 처리 분류
- [ ] 진성 → 수정 (BCL 반환 null 검사 / `?.`·`??`)
- [ ] 위양성 → 사유서 (입력 보장으로 null 불가한 근거)
- [ ] 보류 → 사유 (BCL 반환 계약·입력 보장 판단 불가 시; frontier-handoff)
