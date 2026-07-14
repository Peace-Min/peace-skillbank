# PRIVATE_COLLECTION — 내부 컬렉션 참조 노출 (private collection exposure)

- **건수**: 5  |  **심각도**: 위험  |  **트랙**: C
- **Sparrow 설명**: private 컬렉션 필드(`List<T>`, `Dictionary<,>`, 배열 등)의 **참조를 그대로 외부에 노출**(public getter/반환)하거나, 외부 컬렉션 참조를 복사 없이 내부 필드로 받는다. 외부가 내부 컬렉션을 직접 add/remove/수정할 수 있어 캡슐화가 깨진다. PUBLIC_DATA_ASSIGNED_TO_PRIVATE_ARRAY 의 일반 컬렉션판.

## 지켜야 할 규칙 (무엇을 왜 검출)
`get => _list;` 처럼 내부 `List<T>` 참조를 노출하면 외부가 `list.Clear()`/`Add()`로 **내부 상태를 우회 변경**한다. 클래스가 유지하려는 불변식(정렬·중복없음·개수 제한 등)이 무력화된다. 방산 코드의 상태 무결성·캡슐화 관점에서 위험.

## 표준 매핑 (교차참조)
- CWE: **CWE-375** (Returning a Mutable Object) / 입력측 **CWE-374**(Passing Mutable Objects); 캡슐화 **CWE-497** 인접
- 무기체계 보안약점 점검 목록: 미매핑 (187 확보 시 "캡슐화 위반/가변 객체 노출" 계열)
- CERT-C/행안부/OWASP: CERT OBJ05-J(내부 표현 노출 금지), OBJ06-J(방어적 복사)

## 진성 판별 기준
- public 프로퍼티/메서드가 private 컬렉션 필드를 **그대로 반환**(`return _items;`, `get => _items;`).
- 또는 파라미터로 받은 컬렉션 참조를 **복사 없이** 내부 필드에 저장.
- 그 컬렉션의 내용/구조 불변식을 클래스가 신뢰한다.

## 흔한 위양성 패턴
- 이미 `ReadOnlyCollection<T>`/`IReadOnlyList<T>`/`IEnumerable<T>` 로 노출해 외부 변경 불가(분석기가 래핑을 놓친 경우) → 사유서.
- 내부적으로도 불변으로만 쓰이고 공유가 의도된 설계 → 사유서.
- DTO/레코드류로 캡슐화 요구가 없는 순수 데이터 홀더.

## 수정 패턴 (C# 예시)
```csharp
// Before — 내부 List 참조 노출
private readonly List<Item> _items = new List<Item>();
public List<Item> Items => _items;          // 외부가 Add/Clear 가능

// After (A) 읽기전용 래핑 (변경 불가 노출)
public IReadOnlyList<Item> Items => _items;             // net472 지원
// 또는 새 ReadOnlyCollection<Item>(_items)

// After (B) 방어적 복사 (스냅샷 반환)
public List<Item> GetItemsSnapshot() => new List<Item>(_items);

// 입력측 — 복사해서 저장
public void SetItems(IEnumerable<Item> items)
{
    _items.Clear();
    _items.AddRange(items ?? Enumerable.Empty<Item>());
}
```
- 변경 API가 필요하면 클래스에 `AddItem`/`RemoveItem` 메서드를 두어 **불변식을 관문화**하고, 컬렉션 자체는 읽기전용으로만 노출.

## 검증 확인 조건 (G2)
- 빌드 통과.
- Sparrow 재분석 시 해당 프로퍼티/메서드 PRIVATE_COLLECTION 소멸.
- 신규 검출 0 — 반환 타입 변경이 호출측 컴파일 오류·새 UNCHECKED_NULL 을 만들지 않는지(호출측 조정 포함).

## 기본 처리 분류
- [ ] 진성 → 수정 (읽기전용 노출 / 스냅샷 / 관문 메서드)
- [ ] 위양성 → 사유서 (이미 읽기전용·공유 의도 근거)
- [ ] 보류 → 사유 (호출측 파급 판단 필요 시; frontier-handoff)
