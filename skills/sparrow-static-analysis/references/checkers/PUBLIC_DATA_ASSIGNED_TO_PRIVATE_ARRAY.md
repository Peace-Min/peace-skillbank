# PUBLIC_DATA_ASSIGNED_TO_PRIVATE_ARRAY — private 배열에 저장된 public 데이터

- **건수**: 9  |  **심각도**: 위험  |  **트랙**: C
- **Sparrow 설명**: 외부 데이터를 private 배열에 저장 체커는 외부에서 접근 가능한 배열 객체를 private 배열 필드 변수에 저장하는 경우를 검출합니다.

## 지켜야 할 규칙 (무엇을 왜 검출)
이 체커는 **입력/저장 방향**만 대상으로 한다: 생성자·세터·메서드 파라미터로 받은 **외부 배열 참조를 방어적 복사 없이 그대로 private 배열 필드에 대입**하는 경우다. 배열은 참조형이라 참조만 저장하면 **호출자와 내부가 같은 배열을 공유**하게 되어, 호출자가 나중에 그 배열을 수정하면 내부 상태가 의도치 않게 바뀐다(캡슐화·불변식 위반). 방산 코드의 상태 무결성 관점에서 위험. (반대로 내부 배열/컬렉션을 그대로 **반환**해 노출하는 방향은 [[PRIVATE_COLLECTION]] 소관이다.)

## 표준 매핑 (교차참조)
- CWE: **CWE-496** (Public Data Assigned to Private Array-Typed Field); 연관 **CWE-374**(Passing Mutable Objects to an Untrusted Method)
- 무기체계 보안약점 점검 목록: **187 항목 100% 적용(설정 확정)**; 개별 항목번호는 Sparrow 체커↔표준 매핑 추출 후 기입(대기)
- 행안부 SW보안약점(2021): "private 배열에 public 데이터 저장"
- CERT OBJ06-J(Defensive copying — 언어 무관 개념): 외부 가변 객체는 방어적 복사 후 저장

## 진성 판별 기준
- 생성자/setter/메서드 파라미터로 받은 **외부 배열 참조를 복사 없이** private 배열 필드에 대입(`this._data = input;`).
- 그 필드가 이후 내부 로직의 **불변식/신뢰 대상**이다.
- (반환-노출 방향은 이 체커 대상이 아님 → [[PRIVATE_COLLECTION]].)

## 흔한 위양성 패턴
- 의도적으로 **공유(참조 전달)가 설계**인 경우(대용량 버퍼 성능 최적화, 소유권 이전) — 문서화되어 있으면 사유서. 단 방산 신뢰성 기준에선 방어복사가 기본 권고.
- 배열이 사실상 불변으로만 쓰이고 외부·내부 모두 수정 안 함(관례). → 사유서.


## LLM 판단에 필요한 필수 문맥
- public 입력 데이터가 들어오는 파라미터/프로퍼티/메서드 선언부.
- private 배열 필드 선언과 대입 코드.
- 대입 전에 `Clone`, `Array.Copy`, `ToArray` 등 방어적 복사가 있었는지.
- 입력 배열의 소유권을 호출자가 넘기는 계약인지, 공유 참조가 의도인지.
- 배열 요소가 mutable reference type인지 value type인지.

## 문맥 부족 시 보류 기준
- 대입 한 줄만 있고 입력 기원 또는 선행 복사 여부가 없으면 보류한다.
- 소유권 이전 계약이 문서화되어 있는지 알 수 없으면 `needs_context=true`로 둔다.
- 성능상 복사를 피한 의도인지, 방어적 복사가 필요한 보안 결함인지 판단할 수 없으면 보류한다.

## 추가로 요청해야 할 코드 범위
- private 배열 필드 선언부.
- 입력 파라미터가 들어오는 public API 전체.
- 대입 전후 복사/검증 코드.
- 호출자 계약 주석 또는 대표 호출부.

## 수정 패턴 (C# 예시)
```csharp
// Before — 외부 배열 참조를 그대로 저장
private int[] _buffer;
public void Init(int[] data)
{
    _buffer = data;                    // 호출자가 data 를 나중에 수정하면 내부도 바뀜
}

// After — 입력 시 방어적 복사
public void Init(int[] data)
{
    if (data == null)
    {
        _buffer = Array.Empty<int>();
        return;
    }
    _buffer = (int[])data.Clone();     // 또는 new int[data.Length] 후 Array.Copy(...)
}
```

## 검증 확인 조건 (G2)
- 빌드 통과.
- Sparrow 재분석 시 해당 필드 대입의 PUBLIC_DATA_ASSIGNED_TO_PRIVATE_ARRAY 소멸.
- 신규 검출 0 — 복사 추가가 성능 핫패스에서 문제되면 설계 재검토(로깅), 새 RESOURCE/NULL 결함 없음.

## 기본 처리 분류
- [ ] 진성 → 수정 (입력 시 방어적 복사)
- [ ] 위양성 → 사유서 (공유가 의도된 설계·불변 사용 근거)
- [ ] 보류 → 사유 (성능/소유권 트레이드오프 판단 필요 시; frontier-handoff)
