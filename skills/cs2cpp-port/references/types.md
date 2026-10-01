# 타입 매핑

## 1. 기본형

| C# | C++ | 주의 |
|---|---|---|
| `bool` | `bool` | |
| `byte` | `uint8_t` | |
| `sbyte` | `int8_t` | |
| `short` | `int16_t` | |
| `ushort` | `uint16_t` | |
| `int` | `int32_t` | |
| `uint` | `uint32_t` | |
| `long` | `int64_t` | **`long` 쓰지 말 것 (MSVC는 32비트)** |
| `ulong` | `uint64_t` | |
| `float` | `float` | |
| `double` | `double` | |
| `char` | `char16_t` (문자 코드로 쓸 때) / `char` (ASCII 바이트로만 쓸 때) | C# char는 UTF-16 코드 단위 |
| `decimal` | 변환하지 않음 | 정리 단계의 결정(`PREPORT-DECISION`)을 따른다. 전문에 들어가면 C# `decimal`의 16바이트 표현을 그대로 재현해야 한다 |
| `object` | 변환하지 않음 | 실제 들어가는 타입을 확인해 구체 타입으로. 불명확하면 TODO |
| `IntPtr` | `intptr_t` / 포인터 | |

`int.MaxValue` → `std::numeric_limits<int32_t>::max()` (`<limits>`).

## 2. 수치 의미 차이

| 상황 | C# | C++ | 처리 |
|---|---|---|---|
| 부호 있는 정수 overflow | 감싸짐(unchecked) | **미정의 동작** | 감싸짐에 의존하면 unsigned로 계산 후 캐스트, 또는 `int64_t`로 계산. `TODO(PORT-BUG?)` 표시 |
| 시프트 수 ≥ 비트 수 | 마스킹(`x << 33` = `x << 1`, int 기준) | 미정의 동작 | 시프트 수를 `& 31`(64비트는 `& 63`) 해서 C#과 같게 |
| 정수 0 나누기 | `DivideByZeroException` | 미정의 동작(프로세스 종료) | C#에 try/catch가 있으면 나누기 전 0 검사 후 `throw NetCompat::DivideByZeroException()` |
| `int`와 `uint` 섞인 비교·연산 | 둘 다 `long`으로 승격 (`-1 < 1u`는 참) | 부호 없는 쪽으로 변환 (`-1 < 1u`는 **거짓**) | 둘 다 `static_cast<int64_t>` |
| 음수 값 왼쪽 시프트 `-1 << 3` | 정의됨 | C++17 미정의 동작 | `static_cast<int32_t>(static_cast<uint32_t>(x) << n)` |
| `Math.Abs(int.MinValue)` | `OverflowException` | 미정의 동작 | 원본이 이 값을 받을 수 있으면 검사 후 `NetCompat::OverflowException` |
| `Math.Round(x)` | 은행가 반올림(2.5→2) | `std::round`는 2.5→3 | `NetCompat::MathRound(x)` |
| `Math.Round(x, MidpointRounding.AwayFromZero)` | 0에서 멀어짐 | | `std::round(x)` |
| `Math.Round(x, n)` | 은행가 반올림 n자리 | | `std::nearbyint(x * p) / p` (p = 10^n), `TODO(PORT): 부동소수 오차 확인` |
| `Convert.ToInt32(double)` | 은행가 반올림, 범위 밖 `OverflowException` | | `NetCompat::ConvertToInt32(x)` |
| `(int)doubleValue` | 0 방향 절삭 (범위 밖·NaN은 정의되지 않은 값) | 0 방향 절삭 (범위 밖·NaN은 **미정의 동작**) | `static_cast<int32_t>(x)`. 범위 밖 값이 올 수 있으면 보고 |
| `checked { }` / `checked(x + y)` | 넘침이면 `OverflowException` | | 넘침 검사 후 `NetCompat::OverflowException` |
| `float.ToString()` | 유효숫자 7자리 | | 로그용 `%.7g` |
| `(short)intValue` 좁히기 | 하위 비트 | MSVC 하위 비트 | `static_cast<int16_t>(x)` 동일 |
| `byte + byte` | `int` | `int` (정수 승격) | 대입 시 `static_cast` 명시 |
| 음수 `%` | 부호는 피제수 | 같음 | 동일 |
| `double.ToString()` | 15자리 유효숫자, NaN은 `NaN`, 무한대는 `Infinity`·`-Infinity` | printf는 `nan`, `inf` | 로그용이면 `%.15g`. 값 비교·전문·파일에 쓰면 TODO |

## 2-1. 바이트·메모리 API (`System.Memory`, `Unsafe`, `BinaryPrimitives`)

| C# | C++ |
|---|---|
| `Span<byte>` / `ReadOnlySpan<byte>` (버퍼 일부를 가리킴) | `uint8_t*` + 길이, 또는 `std::vector<uint8_t>&` + 시작 위치 |
| `MemoryMarshal.Write(span, ref value)` / `Read<T>(span)` | `std::memcpy(dst, &value, sizeof(T))` / `std::memcpy(&value, src, sizeof(T))` (호스트 바이트 순서 = little-endian) |
| `Unsafe.SizeOf<T>()` | `sizeof(T)` — `T`가 C# `bool`이면 C#도 1. C# struct면 `StructLayout`과 C++ 구조체 배치가 같은지 확인 후 `static_assert(sizeof(T) == N)` |
| `BinaryPrimitives.ReverseEndianness(x)` | 바이트 뒤집기 헬퍼 (`ByteStream.h`의 Big/Little 처리로 대신하면 그것을 쓴다) |
| `BinaryPrimitives.WriteUInt16BigEndian(span, v)` 등 | `ByteWriter(ByteOrder::Big).WriteU16(v)` 또는 바이트 단위 직접 기록 |
| `unsafe` 포인터 캐스트 `*(int*)p` | `std::memcpy`로 읽기 (정렬·엄격한 별칭 규칙 위반 방지) |

## 3. 문자열

| C# | C++ |
|---|---|
| `string` | `std::string` (UTF-8) |
| `null` 문자열 | 빈 문자열과 구분해야 하면 `std::optional<std::string>`, 아니면 `std::string` |
| `s.Length` | `s.size()` — **바이트 수**. 한글이 섞이면 C# 글자 수와 다름. 길이로 로직 분기하면 TODO |
| `s == t` | `s == t` (값 비교, 동일) |
| `string.IsNullOrEmpty(s)` | `s.empty()` (optional이면 `!s || s->empty()`) |
| `s.Substring(i, n)` | `s.substr(i, n)` — 범위를 넘으면 C#은 `ArgumentOutOfRangeException`, `substr`는 잘라 냄. 넘을 수 있으면 먼저 검사 후 `NetCompat::ArgumentOutOfRangeException` |
| `s.IndexOf(x)` 결과 `-1` | `s.find(x)` 결과 `std::string::npos` |
| `s.Contains(x)` | `s.find(x) != std::string::npos` |
| `s.StartsWith(p)` | `s.compare(0, p.size(), p) == 0` |
| `s.Trim()` | 직접 헬퍼 `Trim()` 작성 (공백 `" \t\r\n"`) |
| `s.Split(',')` | 직접 헬퍼 `Split(const std::string&, char)` → `std::vector<std::string>` |
| `s.ToUpper()` | ASCII만이면 `std::toupper(static_cast<unsigned char>(c))` 루프 |
| `int.Parse(s)` (`short`·`long`·`uint` 등도) | `NetCompat::ParseInteger<int32_t>(s)` — `std::stoi`는 `"12abc"`를 12로 읽어 C#과 다름 |
| `int.TryParse(s, out v)` | `NetCompat::TryParseInteger<int32_t>(s, v)` (실패 시 `v = 0`) |
| `double.Parse` | 정리 단계의 결정(`PREPORT-DECISION`)을 따른다. 정해지지 않았으면 `TODO(PORT)` |
| `"Count: " + n` (문자열 + 숫자·bool·enum) | `StrFormat("Count: %d", n)` — `+`로 옮기면 포인터 연산이 된다 |
| `const string X = "..."` | `static constexpr const char* X = "...";` (`constexpr std::string`은 C++17에서 불가) |
| `StringBuilder` | `std::string` + `append` / `+=` |
| 바이트로 바꾸는 문자열(`Encoding.XXX`) | 바이트 변환 지점에서만 원본 인코딩으로 변환 (`serialization.md` 4절) |
| `s.Split(',')` 빈 항목 | C#은 빈 항목을 남김 (`"a,b,"` → 3개). 헬퍼도 같게 |

## 4. 컬렉션

| C# | C++ | 주의 |
|---|---|---|
| `T[]` (고정 길이) | `std::array<T, N>` (길이 상수) / `std::vector<T>` | **배열은 참조형.** 인자로 받아 수정하면 `std::vector<T>&` |
| `byte[]` | `std::vector<uint8_t>` | |
| `List<T>` | `std::vector<T>` | `List` 자체도 참조형. T가 C# class면 idioms.md 2절 소유 규칙. **원소 주소·반복자를 들고 있는 동안 추가하면 무효화** |
| `Dictionary<K,V>` | `std::unordered_map<K,V>` | C#은 삭제가 없으면 **삽입 순서**로 순회한다. 순회 결과가 출력·전문·처리 순서에 영향을 주면 삽입순 `std::vector<std::pair<K,V>>` + 검색용 `std::unordered_map<K, size_t>`로 옮기고, `Remove` 뒤 재삽입이 있으면 `TODO(PORT)`. `std::map`은 키 정렬 순서라 다르다 |
| `foreach (var kv in dict)` | `for (const auto& kv : m)` — `kv.Key`/`kv.Value` → `kv.first`/`kv.second` | 순서 주의는 위 행 |
| `SortedDictionary<K,V>` | `std::map<K,V>` | `string` 키는 C#이 문화권 비교라 순서가 다를 수 있음 → 보고 |
| `HashSet<T>` | `std::unordered_set<T>` | 삭제가 없으면 C#은 삽입 순서로 순회. 순서가 결과에 영향을 주면 `Dictionary` 행과 같게 |
| `Queue<T>` | `std::queue<T>` / `std::deque<T>` | |
| `Stack<T>` | `std::stack<T>` | |
| `ConcurrentQueue<T>`, `ConcurrentDictionary<K,V>` | `std::recursive_mutex`로 감싼 `std::deque`/`std::unordered_map` (`concurrency.md` 4절). `TryDequeue` → 잠금 안에서 비었는지 보고 꺼냄, `TryAdd`/`GetOrAdd`/`AddOrUpdate` → 잠금 안에서 `find` 후 처리 | C# 열거는 순간 스냅샷이다. 잠금 안에서 복사본을 만들어 순회 |
| `dict[k]` (읽기, 없으면 예외) | `NetCompat::DictAt(dict, k)` | `operator[]`는 없으면 **새로 삽입**. `at()`은 예외 형식이 다름 |
| `list[i]` / `array[i]` | `NetCompat::ListAt(v, i)` / `ArrayAt(v, i)` | `v[i]`는 범위 밖이면 미정의 동작 |
| `dict[k] = v` (쓰기) | `dict[k] = v` | |
| `dict.TryGetValue(k, out v)` | `auto it = dict.find(k); if (it != dict.end()) { ... it->second ... }` | |
| `list.Count` | `list.size()` (`size_t`) | 부호 비교 경고 → 인덱스는 `size_t` |
| `foreach` 중 컬렉션 수정 | C#은 예외, C++은 미정의 동작 | 수정이 있으면 복사본을 순회하거나 인덱스 루프 |

## 5. 시간

| C# | C++ (`<chrono>`) |
|---|---|
| `Stopwatch` | `std::chrono::steady_clock` 기반 `Stopwatch` 클래스 (concurrency.md 5절) |
| `sw.ElapsedMilliseconds` (`long`) | `int64_t` 밀리초 |
| `TimeSpan` | `std::chrono::milliseconds` (정밀도가 더 필요하면 `microseconds`) |
| `DateTime.UtcNow` | `std::chrono::system_clock::now()` |
| `DateTime.Now` (로컬) | `system_clock::now()` + 표시할 때 `localtime_s` |
| `DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()` | `std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count()` |
| `DateTime.Ticks` (100ns, 0001-01-01 기준) | Unix 100ns 값 + `621355968000000000` |
| `dt.ToString("HH:mm:ss.fff")` | `localtime_s` + `snprintf` 헬퍼 |
| `Thread.Sleep(ms)` | `std::this_thread::sleep_for(std::chrono::milliseconds(ms))` |

경과 시간 계산에는 항상 `steady_clock`, 시각(몇 시 몇 분) 표시에는 `system_clock`.

## 6. 열거형

| C# | C++ |
|---|---|
| `enum E { A, B }` | `enum class E : int32_t { A, B };` |
| `enum E : byte` | `enum class E : uint8_t` |
| 값 명시 `A = 0x10` | 그대로 |
| `[Flags] enum` | `enum class` + `operator|`, `operator&` 정의, 검사는 `(static_cast<uint32_t>(v) & bit) != 0` |
| `e.ToString()` (이름 문자열) | 이름 표 함수 `const char* ToString(E)`를 `switch`로 작성. 로그 외 용도면 보고 |
| `Enum.Parse` | 정리 단계에서 보고된 위치. 사람이 정한 방식을 따른다 |
| `(int)e` | `static_cast<int32_t>(e)` |

## 7. Nullable

| C# | C++ |
|---|---|
| `int?` | `std::optional<int32_t>` |
| `x.HasValue` / `x.Value` | `x.has_value()` / `*x` |
| `x ?? d` (값형) | `x.value_or(d)` |
| `obj?.Method()` (참조형) | `if (obj) { obj->Method(); }` |
| `obj ?? other` (참조형) | `obj ? obj : other` |
