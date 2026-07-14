# NULL_RETURN_STD — 표준 계약 위반 null 반환 (null return, std)

- **건수**: 6  |  **심각도**: 매우위험  |  **트랙**: C
- **Sparrow 설명**: **표준 라이브러리/오버라이드 계약상 non-null 이 기대되는 위치**에서 null 을 반환한다(NULL_RETURN 의 특수형). 대표적으로 `ToString()`, `IEnumerable` 반환, `object.Equals` 협력 메서드, 팩토리·프로퍼티 getter 등 프레임워크·관례가 non-null 을 전제하는 계약을 어긴다.

## 지켜야 할 규칙 (무엇을 왜 검출)
프레임워크는 특정 반환이 non-null 임을 암묵 계약으로 삼는다(예: `ToString()`은 절대 null 이 아니어야 하며 문자열 포매팅·로깅·바인딩이 이를 신뢰). 이 계약을 깨면 **호출측이 방어할 수 없는 위치**에서 NRE가 터진다 — 일반 NULL_RETURN 보다 파급이 크고 재현이 어렵다.

## 표준 매핑 (교차참조)
- CWE: **CWE-476**; 계약 위반 관점 **CWE-573**(Improper Following of Specification)
- 무기체계 보안약점 점검 목록: 미매핑 (187 확보 시 "널 포인터 역참조" 계열)
- CERT-C/행안부/OWASP: 행안부 "널 포인터 역참조"; .NET Framework Design Guidelines(ToString/컬렉션 non-null 관례)

## 진성 판별 기준
- 반환 위치가 **오버라이드/구현/관례상 non-null 계약**: `ToString()`, `GetEnumerator()`/`IEnumerable<T>` 반환, 잘 알려진 팩토리/`Parse` 계열, non-nullable 로 소비되는 프로퍼티.
- 그 경로에서 `return null;` 이 존재.

## 흔한 위양성 패턴
- 계약이 실제로는 nullable 로 문서화된 커스텀 인터페이스(표준처럼 보이나 아님) — 사유서.
- 분석기가 오버라이드 대상 계약을 오인. 드묾.

## 수정 패턴 (C# 예시)
```csharp
// Before — ToString 이 null 반환 가능
public override string ToString()
{
    return _name;                 // _name 이 null 이면 계약 위반
}

// After — non-null 보장
public override string ToString()
{
    return _name ?? string.Empty; // 컬렉션이면 Enumerable.Empty<T>()
}
```
- 문자열 계약 → `string.Empty`(또는 의미 있는 대체값). 열거 계약 → `Enumerable.Empty<T>()`. "정말 없음이 오류" → 계약을 지키되 상류에서 상태 검증.

## 검증 확인 조건 (G2)
- 빌드 통과.
- Sparrow 재분석 시 해당 위치 NULL_RETURN_STD 소멸.
- 신규 검출 0.

## 기본 처리 분류
- [ ] 진성 → 수정 (계약 준수 대체값)
- [ ] 위양성 → 사유서 (해당 계약이 실제 nullable 근거)
- [ ] 보류 → 사유 (계약 판정 불가 시; frontier-handoff)
