# PRIVATE_COLLECTION — public 메소드에 의해 반환된 private 컬렉션

- **건수**: 5  |  **심각도**: 위험  |  **트랙**: C
- **Sparrow 설명**: private 컬렉션 노출 체커는 private이 아닌 메소드에서 private으로 선언된 배열 또는 컬렉션 타입 필드의 객체가 그대로 반환되는 경우를 검출합니다.

## 지켜야 할 규칙 (무엇을 왜 검출)
이 체커는 **반환/노출 방향**만 대상으로 한다: private 이 아닌(public/internal 등) 메서드나 프로퍼티가 private 으로 선언된 **배열 또는 컬렉션 필드의 객체를 그대로 반환**하는 경우다. `get => _list;` 처럼 내부 `List<T>`/배열 참조를 노출하면 외부가 `list.Clear()`/`Add()`(또는 배열 요소 수정)로 **내부 상태를 우회 변경**할 수 있어, 클래스가 유지하려는 불변식(정렬·중복없음·개수 제한 등)이 무력화된다. 방산 코드의 상태 무결성·캡슐화 관점에서 위험. (외부 배열을 받아 private 필드에 저장하는 입력 방향은 [[PUBLIC_DATA_ASSIGNED_TO_PRIVATE_ARRAY]] 소관이다.)

## 표준 매핑 (교차참조)
- CWE: **CWE-375** (Returning a Mutable Object); 캡슐화 **CWE-497** 인접
- 무기체계 보안약점 점검 목록: **187 항목 100% 적용(설정 확정)**; 개별 항목번호는 Sparrow 체커↔표준 매핑 추출 후 기입(대기)
- 행안부 SW보안약점(2021): "캡슐화 위반/가변 객체 노출" 계열
- CERT OBJ05-J(내부 가변 표현 참조 반환 금지 — 언어 무관 개념)

## 진성 판별 기준
- private 이 아닌 프로퍼티/메서드가 private 배열/컬렉션 필드를 **그대로 반환**(`return _items;`, `get => _items;`).
- 그 컬렉션/배열의 내용·구조 불변식을 클래스가 신뢰한다.
- (입력 방향 저장은 이 체커 대상이 아님 → [[PUBLIC_DATA_ASSIGNED_TO_PRIVATE_ARRAY]].)

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
// 또는 new ReadOnlyCollection<Item>(_items)

// After (B) 방어적 복사 (스냅샷 반환)
public List<Item> GetItemsSnapshot() => new List<Item>(_items);

// 배열 필드도 동일 — 그대로 반환 대신 복사/읽기전용
private readonly int[] _codes = new int[N];
public int[] GetCodes() => (int[])_codes.Clone();       // 스냅샷 반환
```
- 변경 API가 필요하면 클래스에 `AddItem`/`RemoveItem` 등 **관문 메서드**를 두어 불변식을 통제하고, 컬렉션/배열 자체는 읽기전용 또는 스냅샷으로만 반환한다.

## 검증 확인 조건 (G2)
- 빌드 통과.
- Sparrow 재분석 시 해당 프로퍼티/메서드 PRIVATE_COLLECTION 소멸.
- 신규 검출 0 — 반환 타입 변경이 호출측 컴파일 오류·새 UNCHECKED_NULL 을 만들지 않는지(호출측 조정 포함).

## 기본 처리 분류
- [ ] 진성 → 수정 (읽기전용 노출 / 스냅샷 / 관문 메서드)
- [ ] 위양성 → 사유서 (이미 읽기전용·공유 의도 근거)
- [ ] 보류 → 사유 (호출측 파급 판단 필요 시; frontier-handoff)
