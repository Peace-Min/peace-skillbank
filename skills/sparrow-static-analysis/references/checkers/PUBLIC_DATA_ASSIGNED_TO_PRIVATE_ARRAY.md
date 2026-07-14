# PUBLIC_DATA_ASSIGNED_TO_PRIVATE_ARRAY — 외부 배열 참조를 내부 필드에 저장 (mutable exposure)

- **건수**: 9  |  **심각도**: 위험  |  **트랙**: C
- **Sparrow 설명**: 외부에서 전달받은 배열(또는 외부에 반환한 배열)의 **참조를 그대로 private 배열 필드에 대입**한다. 방어적 복사 없이 참조를 공유하면 외부 코드가 내부 상태를 몰래 변경할 수 있다(불변식 파괴).

## 지켜야 할 규칙 (무엇을 왜 검출)
배열은 참조형이라 필드에 참조만 저장하면 **호출자와 내부가 같은 배열을 공유**한다. 호출자가 나중에 그 배열을 수정하면 내부 상태가 의도치 않게 바뀐다(캡슐화·불변식 위반). 반대로 내부 배열 참조를 그대로 반환해도 외부가 내부를 변경할 수 있다. 방산 코드의 상태 무결성 관점에서 위험.

## 표준 매핑 (교차참조)
- CWE: **CWE-496** (Public Data Assigned to Private Array-Typed Field); 연관 **CWE-374**(Passing Mutable Objects to an Untrusted Method), **CWE-375**(Returning a Mutable Object)
- 무기체계 보안약점 점검 목록: 미매핑 (187 확보 시 "잘못된 세션/객체 참조·캡슐화" 계열 검토)
- CERT-C/행안부/OWASP: CERT OBJ06-J(Defensive copying); 행안부 "private 배열에 public 데이터 저장"

## 진성 판별 기준
- 생성자/setter/메서드 파라미터로 받은 **배열 참조를 복사 없이** private 배열 필드에 대입(`this._data = input;`).
- 또는 private 배열 필드를 **그대로 반환**(`return _data;`)해 외부가 내부를 수정 가능.
- 그 필드가 이후 내부 로직의 **불변식/신뢰 대상**이다.

## 흔한 위양성 패턴
- 의도적으로 **공유(참조 전달)가 설계**인 경우(대용량 버퍼 성능 최적화, 소유권 이전) — 문서화되어 있으면 사유서. 단 방산 신뢰성 기준에선 방어복사가 기본 권고.
- 배열이 사실상 불변으로만 쓰이고 외부·내부 모두 수정 안 함(관례). → 사유서.

## 수정 패턴 (C# 예시)
```csharp
// Before — 외부 배열 참조 공유
private int[] _buffer;
public void Init(int[] data)
{
    _buffer = data;                    // 호출자가 data 를 나중에 수정하면 내부도 바뀜
}
public int[] GetBuffer() => _buffer;   // 외부가 내부를 수정 가능

// After — 입력/출력 모두 방어적 복사
public void Init(int[] data)
{
    _buffer = (int[])data.Clone();     // 또는 new int[data.Length]; Array.Copy(...)
}
public int[] GetBuffer() => (int[])_buffer.Clone();
// 또는 읽기전용 노출: ReadOnlyCollection / IReadOnlyList 로 반환
```

## 검증 확인 조건 (G2)
- 빌드 통과.
- Sparrow 재분석 시 해당 필드 대입/반환의 PUBLIC_DATA_ASSIGNED_TO_PRIVATE_ARRAY 소멸.
- 신규 검출 0 — 복사 추가가 성능 핫패스에서 문제되면 설계 재검토(로깅), 새 RESOURCE/NULL 결함 없음.

## 기본 처리 분류
- [ ] 진성 → 수정 (입력/출력 방어적 복사 또는 읽기전용 래핑)
- [ ] 위양성 → 사유서 (공유가 의도된 설계·불변 사용 근거)
- [ ] 보류 → 사유 (성능/소유권 트레이드오프 판단 필요 시; frontier-handoff)
