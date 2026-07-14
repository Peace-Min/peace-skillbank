# NULL_RETURN — null 반환 (null return)

- **건수**: 18  |  **심각도**: 매우위험  |  **트랙**: C
- **Sparrow 설명**: 메서드가 `null` 을 반환하며, 그 반환값이 호출측에서 검사 없이 역참조될 수 있는(또는 실제로 되는) 경로가 존재한다. 반환 계약이 "항상 객체"인데 특정 경로에서 null 을 흘려보내는 지점을 잡는다. 사실상 CWE-476 결함의 **생산자 쪽**.

## 지켜야 할 규칙 (무엇을 왜 검출)
null 을 반환하는 메서드는 모든 호출측에 null 검사 부담을 전가한다. 한 곳이라도 빠지면 NRE로 이어진다(FORWARD_NULL/UNCHECKED_NULL 의 근원). 방산 코드에서는 "없음"을 null 대신 **빈 컬렉션·Try패턴·명시적 예외**로 표현해 계약을 분명히 하는 것이 신뢰성 기준에 부합한다.

## 표준 매핑 (교차참조)
- CWE: **CWE-476** (역참조 경로) / 설계 관점 **CWE-393**(Return of Wrong Status Code) 인접
- 무기체계 보안약점 점검 목록: 미매핑 (187 확보 시 "널 포인터 역참조" 계열)
- CERT-C/행안부/OWASP: 행안부 "널 포인터 역참조"(호출측 결함과 연동)

## 진성 판별 기준
- 메서드 시그니처/의미상 반환값이 **참조형 객체이며 호출측이 곧바로 사용**한다(컬렉션·문자열·엔티티).
- 반환 경로 중 `return null;` 이 있고, 호출측 다수가 null 검사를 하지 않는다.
- "없음/실패"를 나타내려는 의도지만 그 신호가 null 이라 계약이 모호하다.

## 흔한 위양성 패턴
- 반환 타입이 nullable 이 **의도된 계약**이고 **모든 호출측이 null 을 정상 처리**(예: 캐시 조회 `TryGet` 스타일) — 이땐 결함 아님, 위양성 사유서.
- 인터페이스 구현상 null 반환이 규약(예: `IComparer`가 아닌 팩토리에서 "해당 없음" 의미) — 문서화되어 있으면 사유서.

## 수정 패턴 (C# 예시)
```csharp
// Before — 컬렉션을 null 로 반환
public List<Item> GetItems(int id)
{
    if (!Exists(id)) return null;      // 호출측마다 null 검사 강요
    return _repo.Load(id);
}

// After (A) 빈 컬렉션 반환 (컬렉션은 null 대신 empty 가 표준)
public List<Item> GetItems(int id)
{
    if (!Exists(id)) return new List<Item>();   // 또는 Array.Empty<Item>()
    return _repo.Load(id);
}

// After (B) 단일 객체는 Try 패턴으로 "없음"을 계약에 노출
public bool TryGetItem(int id, out Item item)
{
    item = Exists(id) ? _repo.LoadOne(id) : null;
    return item != null;
}
```
- 컬렉션 → **빈 컬렉션**. 단일 객체에서 "없음"이 정상 → **Try 패턴** 또는 (net472라면) `Nullable`/명시적 결과객체. "없어선 안 됨" → **예외**.

## 검증 확인 조건 (G2)
- 빌드 통과.
- Sparrow 재분석 시 해당 메서드 NULL_RETURN 소멸 **및 연동 FORWARD_NULL/UNCHECKED_NULL 동반 감소** 확인.
- 신규 검출 0 (반환 계약 변경이 호출측에 새 경고를 만들지 않는지).

## 기본 처리 분류
- [ ] 진성 → 수정 (빈 컬렉션/Try/예외 중 계약에 맞게)
- [ ] 위양성 → 사유서 (nullable 이 의도된 계약이고 호출측 전수 검사)
- [ ] 보류 → 사유 (호출측 전수 파악 불가 시; frontier-handoff)
