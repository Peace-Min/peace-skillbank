# .NET Framework 4.7.2 null-return reference for Track C

이 문서는 `NULL_RETURN_STD` 판단 시 로컬 Claude가 우선 참조할 정적 계약표다. 목적은 "표준 라이브러리 호출 결과가 null 일 수 있는가"를 빠르게 판정하는 것이며, 여기 없는 API는 결함 단정 대신 `needs_context=true`로 보류한다.

## 판정 원칙

- API 계약상 "없음", "찾지 못함", "현재 컨텍스트 없음"을 null 로 표현하는 경우만 `NULL_RETURN_STD` 후보로 본다.
- 실패해도 non-null sentinel 객체를 반환하는 API는 null-return 후보가 아니다.
- `Nullable<T>.Value`처럼 null 반환이 아니라 예외를 던지는 API는 이 체커의 대표 후보가 아니다.
- 입력값이 항상 유효하다는 상위 계약이 코드/주석으로 증명되면 그 근거를 판정에 남기고, 증명되지 않으면 반환을 지역변수로 받아 null 검사를 추가해 수정한다.

## 대표 null-return 후보

| API | null 조건 | 판단 시 필요한 추가 문맥 |
|---|---|---|
| `Type.GetType(string)` | 이름으로 타입을 찾지 못함 | 타입명이 상수/검증된 값인지, 결과 사용 전 null 검사 여부 |
| `Assembly.GetType(string)` | 어셈블리에서 타입을 찾지 못함 | 어셈블리와 타입명 보장 계약 |
| `Assembly.GetEntryAssembly()` | 관리 진입점이 없는 컨텍스트 | WPF/테스트/비관리 호스트 여부 |
| `Attribute.GetCustomAttribute(...)` | 지정 attribute 없음 | attribute 필수 보장 여부 |
| `MemberInfo.GetCustomAttribute(...)` 계열 | 지정 attribute 없음 | reflection 대상과 attribute 등록 보장 |
| `XmlNode.SelectSingleNode(...)` | XPath 매치 없음 | XML schema/노드 존재 보장 |
| `XmlDocument.SelectSingleNode(...)` | XPath 매치 없음 | XML schema/노드 존재 보장 |
| `NameValueCollection.Get(string)` | 키가 없고 null 값과 구분 불가 | 키 존재 보장, `AllKeys`/검증 여부 |
| `ConfigurationManager.GetSection(string)` | 섹션 없음 | app.config/web.config 섹션 등록 보장 |
| `HttpContext.Current` | 현재 요청 컨텍스트 없음 | ASP.NET 요청 스레드인지, background thread인지 |
| `Marshal.PtrToStringAnsi(IntPtr)` | 포인터가 `IntPtr.Zero` | 포인터 생성/검증 지점 |
| `Marshal.PtrToStringUni(IntPtr)` | 포인터가 `IntPtr.Zero` | 포인터 생성/검증 지점 |
| `Marshal.PtrToStringAuto(IntPtr)` | 포인터가 `IntPtr.Zero` | 포인터 생성/검증 지점 |
| `DataRowExtensions.Field<T>` where `T` is nullable/reference | DB null 을 null 로 변환 가능 | 컬럼 null 허용 여부, `IsNull` 검사 여부 |
| `Enumerable.FirstOrDefault<T>` for reference/nullable `T` | 시퀀스가 비어 있음 | 시퀀스 non-empty 보장 여부 |
| `Enumerable.SingleOrDefault<T>` for reference/nullable `T` | 시퀀스가 비어 있음 | 시퀀스 cardinality 보장 여부 |
| `Enumerable.LastOrDefault<T>` for reference/nullable `T` | 시퀀스가 비어 있음 | 시퀀스 non-empty 보장 여부 |
| `List<T>.Find(Predicate<T>)` for reference/nullable `T` | 매치 없음 | 매치 보장 여부 |
| `Dictionary<TKey,TValue>.TryGetValue` output for reference/nullable `TValue` | 반환값 false일 때 out 값 default(null 가능) | bool 결과 확인 여부 |

## null-return 후보가 아닌 대표 혼동 사례

| API/패턴 | 이유 |
|---|---|
| `Regex.Match(...)` | 실패해도 null 이 아니라 `Match.Success == false`인 `Match` 객체를 반환한다. |
| `Nullable<T>.Value` | 값이 없으면 null 반환이 아니라 `InvalidOperationException`을 던진다. |
| `Activator.CreateInstance(Type)` | `Type` 인자가 null 이면 일반적으로 예외 경로이며, null 반환 계약으로 보지 않는다. 다만 인자로 넘긴 `Type.GetType(...)` 결과가 null 인지는 별도 검사 대상이다. |
| `Enumerable.First<T>` / `Single<T>` / `Last<T>` | 비어 있으면 null 이 아니라 예외를 던진다. |

## Claude 판단 규칙

- 표에 있는 API라도 검출 항목의 실제 overload와 generic type을 확인한다.
- reference type 또는 nullable value type이 아닌 `FirstOrDefault<int>` 같은 값 타입 기본값은 null 역참조가 아니므로 이 체커로 단정하지 않는다.
- 표에 없는 API는 공식 계약이 요청 패키지에 포함되지 않는 한 `보류`, `needs_context=true`로 둔다.
