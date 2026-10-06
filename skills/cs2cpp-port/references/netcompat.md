# NetCompat.h — .NET과 같은 의미로 동작하는 호환 함수

C++ 표준 함수가 .NET과 **비슷하지만 다르게** 동작하는 곳은 이 헤더의 함수만 쓴다. 함수마다 .NET과 같은 결과·같은 예외를 내도록 만들었다. 가장 하위 공용 프로젝트에 한 번만 둔다.

| C# | C++ (`NetCompat::`) | 표준 함수를 쓰면 생기는 차이 |
|---|---|---|
| `dict[key]` (읽기) | `DictAt(dict, key)` | `map[key]`는 없는 키를 **새로 넣음**. `at()`은 `std::out_of_range`(형식 다름) |
| `list[i]` | `ListAt(vec, i)` | `vec[i]`는 범위 밖이면 미정의 동작 |
| `array[i]` | `ArrayAt(vec_or_array, i)` | 같음 (`std::vector<bool>`에는 쓰지 않는다) |
| `int.Parse(s)` 등 | `ParseInteger<int32_t>(s)` | `std::stoi("12abc")`는 12를 반환 (C#은 `FormatException`) |
| `int.TryParse(s, out v)` | `TryParseInteger<int32_t>(s, v)` | 실패 시 `v = 0` (C#과 같음) |
| `Math.Round(x)` | `MathRound(x)` | `std::round(2.5)`는 3 (C#은 2) |
| `Convert.ToInt32(double)` | `ConvertToInt32(x)` | 반올림 방식과 범위 밖 예외 |
| `throw new FormatException(...)` 등 | `throw NetCompat::FormatException(...)` | 아래 표 |
| `catch (FormatException)` | `catch (const NetCompat::FormatException&)` | 상속 관계가 .NET과 같아 잡히는 범위가 같음 |
| `catch (Exception)` | `catch (const std::exception&)` | |

예외 형식 (.NET 상속 관계 그대로):

```
std::runtime_error
 └ Exception
    └ SystemException
       ├ FormatException
       ├ ArgumentException ─ ArgumentNullException, ArgumentOutOfRangeException
       ├ ArithmeticException ─ OverflowException, DivideByZeroException
       ├ InvalidOperationException ─ ObjectDisposedException
       ├ KeyNotFoundException
       ├ IndexOutOfRangeException
       ├ NotSupportedException
       ├ NotImplementedException
       ├ TimeoutException
       └ IOException ─ EndOfStreamException
```

원본이 던지는 다른 예외 형식이 있으면 같은 방식으로 이 헤더에 추가한다.

```cpp
// NetCompat.h
#pragma once
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <string>
#include <type_traits>

namespace NetCompat {

// ---- 예외 (.NET 형식 이름·상속 관계 그대로) ----
class Exception : public std::runtime_error {
public:
    explicit Exception(const std::string& message) : std::runtime_error(message) {}
};
#define NETCOMPAT_EXCEPTION(Name, Base)                                         \
    class Name : public Base {                                                  \
    public:                                                                     \
        explicit Name(const std::string& message = #Name) : Base(message) {}    \
    };
NETCOMPAT_EXCEPTION(SystemException, Exception)
NETCOMPAT_EXCEPTION(FormatException, SystemException)
NETCOMPAT_EXCEPTION(ArgumentException, SystemException)
NETCOMPAT_EXCEPTION(ArgumentNullException, ArgumentException)
NETCOMPAT_EXCEPTION(ArgumentOutOfRangeException, ArgumentException)
NETCOMPAT_EXCEPTION(ArithmeticException, SystemException)
NETCOMPAT_EXCEPTION(OverflowException, ArithmeticException)
NETCOMPAT_EXCEPTION(DivideByZeroException, ArithmeticException)
NETCOMPAT_EXCEPTION(InvalidOperationException, SystemException)
NETCOMPAT_EXCEPTION(ObjectDisposedException, InvalidOperationException)
NETCOMPAT_EXCEPTION(KeyNotFoundException, SystemException)
NETCOMPAT_EXCEPTION(IndexOutOfRangeException, SystemException)
NETCOMPAT_EXCEPTION(NotSupportedException, SystemException)
NETCOMPAT_EXCEPTION(NotImplementedException, SystemException)
NETCOMPAT_EXCEPTION(TimeoutException, SystemException)
NETCOMPAT_EXCEPTION(IOException, SystemException)
NETCOMPAT_EXCEPTION(EndOfStreamException, IOException)
#undef NETCOMPAT_EXCEPTION

// ---- 인덱서 ----
// C#: dict[key] 읽기. 없으면 KeyNotFoundException.
template <typename Map, typename Key>
auto DictAt(Map& m, const Key& key) -> decltype((m.find(key)->second)) {
    auto it = m.find(key);
    if (it == m.end()) {
        throw KeyNotFoundException("The given key was not present in the dictionary.");
    }
    return it->second;
}

// C#: list[i]. 범위 밖이면 ArgumentOutOfRangeException.
template <typename Vec>
auto ListAt(Vec& v, int64_t index) -> decltype((v[0])) {
    if (index < 0 || static_cast<uint64_t>(index) >= static_cast<uint64_t>(v.size())) {
        throw ArgumentOutOfRangeException("index");
    }
    return v[static_cast<size_t>(index)];
}

// C#: array[i]. 범위 밖이면 IndexOutOfRangeException.
template <typename Arr>
auto ArrayAt(Arr& a, int64_t index) -> decltype((a[0])) {
    if (index < 0 || static_cast<uint64_t>(index) >= static_cast<uint64_t>(a.size())) {
        throw IndexOutOfRangeException("Index was outside the bounds of the array.");
    }
    return a[static_cast<size_t>(index)];
}

// ---- 정수 파싱 (NumberStyles.Integer: 앞뒤 공백, 부호 하나, 10진 숫자) ----
inline bool IsNetWhite(char c) {
    return c == ' ' || (c >= '\t' && c <= '\r');
}

// 성공하면 true. 실패하면 overflow로 원인을 알려 준다(형식 오류가 넘침보다 우선, .NET과 같음).
template <typename T>
bool TryParseInteger(const std::string& s, T& out, bool& overflow) {
    static_assert(std::is_integral<T>::value, "integer only");
    overflow = false;
    size_t b = 0;
    size_t e = s.size();
    while (e > b && s[e - 1] == '\0') {   // .NET Framework는 끝의 '\0'을 허용한다
        --e;
    }
    while (b < e && IsNetWhite(s[b])) {
        ++b;
    }
    while (e > b && IsNetWhite(s[e - 1])) {
        --e;
    }
    if (b == e) {
        return false;
    }
    bool negative = false;
    size_t i = b;
    if (s[i] == '+' || s[i] == '-') {
        negative = (s[i] == '-');
        ++i;
    }
    if (i == e) {
        return false;
    }
    using U = unsigned long long;
    const U maxPositive = static_cast<U>(std::numeric_limits<T>::max());
    const U limit = (negative && std::is_signed<T>::value) ? maxPositive + 1 : maxPositive;
    U magnitude = 0;
    bool tooBig = false;
    for (; i < e; ++i) {
        const char c = s[i];
        if (c < '0' || c > '9') {
            return false;
        }
        const U digit = static_cast<U>(c - '0');
        if (!tooBig) {
            if (magnitude > (limit - digit) / 10) {
                tooBig = true;
            } else {
                magnitude = magnitude * 10 + digit;
            }
        }
    }
    if (tooBig) {
        overflow = true;
        return false;
    }
    if (negative) {
        if constexpr (!std::is_signed<T>::value) {
            if (magnitude != 0) {
                overflow = true;
                return false;
            }
            out = 0;
            return true;
        } else {   // 부호 없는 형식에는 단항 '-'를 만들지 않는다 (MSVC C4146)
            out = (magnitude == 0) ? T(0) : static_cast<T>(-static_cast<T>(magnitude - 1) - 1);
            return true;
        }
    }
    out = static_cast<T>(magnitude);
    return true;
}

// C#: T.TryParse(s, out v). 실패하면 v = 0.
template <typename T>
bool TryParseInteger(const std::string& s, T& out) {
    bool overflow = false;
    T value = 0;
    if (TryParseInteger(s, value, overflow)) {
        out = value;
        return true;
    }
    out = 0;
    return false;
}

// C#: T.Parse(s). 형식 오류 FormatException, 범위 밖 OverflowException.
template <typename T>
T ParseInteger(const std::string& s) {
    bool overflow = false;
    T value = 0;
    if (!TryParseInteger(s, value, overflow)) {
        if (overflow) {
            throw OverflowException("Value was either too large or too small.");
        }
        throw FormatException("Input string was not in a correct format.");
    }
    return value;
}

// ---- 반올림 ----
// C#: Math.Round(x) — 짝수 쪽 반올림(기본 반올림 모드 FE_TONEAREST 전제. fesetround를 바꾸지 않는다).
inline double MathRound(double x) {
    return std::nearbyint(x);
}

// C#: Convert.ToInt32(double) — 짝수 쪽 반올림, 범위 밖·NaN이면 OverflowException.
inline int32_t ConvertToInt32(double x) {
    const double r = std::nearbyint(x);
    if (!(r >= -2147483648.0 && r <= 2147483647.0)) {
        throw OverflowException("Value was either too large or too small for an Int32.");
    }
    return static_cast<int32_t>(r);
}

}  // namespace NetCompat
```

`double.Parse`, `DateTime.Parse`, 문화권 의존 서식은 이 헤더에 없다. `PREPORT-DECISION` 또는 `PORT_CONFIG.md`의 "문화권 의존 서식"을 따르고, 정해지지 않았으면 `TODO(PORT)`.
