# FORWARD_NULL @ Foo.cs:88

| 필드 | 값 |
|---|---|
| ID | 5001 |
| 위험도 | 매우위험 |
| 체커 키 | FORWARD_NULL |
| 체커명 | 널 값 역참조 |
| 라인 | 88 |
| 파일명 | Foo.cs |
| 함수 | Process |

## 체커 설명
널 값 역참조 체커는 널 상수나 널이 할당된 변수를 역참조하는 경우를 검출합니다.

## 수정 대상
- 파일: `Foo.cs`
- 라인: `88`
- 지시: **이 라인은 수정 기준점(anchor)이다. 결함 제거에 필요한 최소 인접 범위까지 수정하되, 무관한 주변 코드는 임의 수정하지 않는다.**
- 대상 코드: `  88: Process(node.Value);`

## 소스 코드
> ⚠️ **수정 기준점 = 라인 88.** (아래 소스의 `TARGET LINE` 표시) 결함 제거에 필요한 최소 인접 범위(감싸는 블록·try/finally·선언부)까지는 수정 가능하며, 결함과 무관한 다른 코드는 수정하지 마십시오. 범위 제약을 수정 불가 사유로 삼지 마십시오.

```text
  86: var node = list.FirstOrDefault(n => n.Id == id);
  87: // no guard here
  88: Process(node.Value);    <<< TARGET LINE 88 - ANCHOR >>>
```
