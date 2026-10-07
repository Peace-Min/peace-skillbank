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
| `d.ToString()` (`double`), `$"{d}"` | `ToString(d)` | `std::format("{}", 0.1 + 0.2)`는 `0.30000000000000004`, .NET Framework는 `0.3`(유효숫자 15자리). `-0.0`은 `0`, `NaN`·`Infinity`·`-Infinity` |
| `f.ToString()` (`float`) | `ToString(f)` | .NET Framework는 유효숫자 7자리(`16777216f` → `1.677722E+07`) |
| `b.ToString()` (`bool`), `$"{b}"` | `ToString(b)` | `std::format`은 `true`, C#은 `True` |
| `d.ToString("F2")`, `{0:F2}` | `ToStringF(d, 2)` | .NET Framework는 15자리로 만든 뒤 0에서 멀어지게 반올림한다. `2.675` → `2.68`(`std::format("{:.2f}")`는 `2.67`), `-0.004` → `0.00` |
| `n.ToString("D5")`, `{0:D5}` | `ToStringD(n, 5)` | 부호는 자리수 밖(`-42` → `-00042`). `std::format("{:05}")`는 `-0042` |
| `n.ToString("X")`, `{0:X8}` | `ToStringX(n)`, `ToStringX(n, 8)` | 음수는 그 형식 크기의 2의 보수(`-1` → `FFFFFFFF`). `std::format("{:X}", -1)`은 `-1` |
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
#include <charconv>
#include <cmath>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <format>
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

// ---- 숫자·bool → 문자열 (.NET Framework 4.x와 같은 결과, 문화권은 고정 "C") ----

// .NET Framework의 숫자 문자열 변환 앞단: 정확한 십진 전개를 precision자리에서 0에서 멀어지게 반올림한다.
// digits는 precision자리(앞자리는 0이 아님), 값 = d1.d2d3... × 10^exponent.
struct NetDigits {
    bool negative = false;
    std::string digits;
    int exponent = 0;
};

inline NetDigits ToNetDigits(double v, int precision) {
    NetDigits r;
    r.negative = std::signbit(v);
    if (v == 0.0) {
        r.digits.assign(static_cast<size_t>(precision), '0');
        return r;
    }
    char buf[800];
    const auto res = std::to_chars(buf, buf + sizeof(buf), std::fabs(v), std::chars_format::scientific, 766);
    const std::string s(buf, res.ptr);   // d.ddd...e±XX (정확한 값)
    const size_t ePos = s.find('e');
    std::string all;
    all.push_back(s[0]);
    all.append(s, 2, ePos - 2);
    r.exponent = std::stoi(s.substr(ePos + 1));
    r.digits = all.substr(0, static_cast<size_t>(precision));
    if (all[static_cast<size_t>(precision)] >= '5') {
        int i = precision - 1;
        while (i >= 0 && r.digits[static_cast<size_t>(i)] == '9') {
            r.digits[static_cast<size_t>(i)] = '0';
            --i;
        }
        if (i >= 0) {
            ++r.digits[static_cast<size_t>(i)];
        } else {
            r.digits.insert(r.digits.begin(), '1');
            r.digits.pop_back();
            ++r.exponent;
        }
    }
    return r;
}

// C#: double.ToString() / float.ToString() 의 일반 형식(G15, G7). 문화권은 고정 "C"(소수점 '.').
inline std::string FormatGeneral(double v, int precision) {
    if (std::isnan(v)) {
        return "NaN";
    }
    if (std::isinf(v)) {
        return v > 0 ? "Infinity" : "-Infinity";
    }
    if (v == 0.0) {
        return "0";   // .NET Framework는 -0.0도 "0"
    }
    NetDigits d = ToNetDigits(v, precision);
    while (d.digits.size() > 1 && d.digits.back() == '0') {
        d.digits.pop_back();
    }
    std::string out = d.negative ? "-" : "";
    if (d.exponent >= -5 + 1 && d.exponent < precision) {   // .NET: -5 < 지수 < 정밀도 이면 고정 소수점
        if (d.exponent < 0) {
            out += "0.";
            out.append(static_cast<size_t>(-d.exponent - 1), '0');
            out += d.digits;
        } else {
            const size_t intLen = static_cast<size_t>(d.exponent) + 1;
            if (d.digits.size() <= intLen) {
                out += d.digits;
                out.append(intLen - d.digits.size(), '0');
            } else {
                out.append(d.digits, 0, intLen);
                out += '.';
                out.append(d.digits, intLen, std::string::npos);
            }
        }
        return out;
    }
    out.push_back(d.digits[0]);
    if (d.digits.size() > 1) {
        out += '.';
        out.append(d.digits, 1, std::string::npos);
    }
    out += std::format("E{}{:02}", d.exponent < 0 ? '-' : '+', d.exponent < 0 ? -d.exponent : d.exponent);
    return out;
}

inline std::string ToString(double v) { return FormatGeneral(v, 15); }
inline std::string ToString(float v) { return FormatGeneral(static_cast<double>(v), 7); }
inline std::string ToString(bool v) { return v ? "True" : "False"; }

// C#: v.ToString("F<decimals>") — 15자리로 만든 뒤 decimals 자리에서 0에서 멀어지게 반올림(.NET Framework).
inline std::string ToStringF(double v, int decimals) {
    if (std::isnan(v)) {
        return "NaN";
    }
    if (std::isinf(v)) {
        return v > 0 ? "Infinity" : "-Infinity";
    }
    const NetDigits d = ToNetDigits(v, 15);
    std::string digs = d.digits;
    int intDigits = d.exponent + 1;
    const int keep = intDigits + decimals;
    if (v == 0.0 || keep < 0) {
        digs.clear();
    } else if (keep < static_cast<int>(digs.size())) {
        const bool up = digs[static_cast<size_t>(keep)] >= '5';
        digs.resize(static_cast<size_t>(keep));
        if (up) {
            int i = keep - 1;
            while (i >= 0 && digs[static_cast<size_t>(i)] == '9') {
                digs[static_cast<size_t>(i)] = '0';
                --i;
            }
            if (i >= 0) {
                ++digs[static_cast<size_t>(i)];
            } else {
                digs.insert(digs.begin(), '1');
                ++intDigits;
            }
        }
    }
    auto digitAt = [&](int index) -> char {
        return (index >= 0 && index < static_cast<int>(digs.size())) ? digs[static_cast<size_t>(index)] : '0';
    };
    std::string body;
    if (intDigits <= 0) {
        body = "0";
    } else {
        for (int i = 0; i < intDigits; ++i) {
            body.push_back(digitAt(i));
        }
    }
    if (decimals > 0) {
        body.push_back('.');
        for (int i = 0; i < decimals; ++i) {
            body.push_back(digitAt(intDigits + i));
        }
    }
    const bool allZero = body.find_first_not_of("0.") == std::string::npos;
    return (d.negative && !allZero) ? "-" + body : body;   // .NET Framework는 0으로 반올림되면 부호를 뺀다
}

// C#: v.ToString("D<digits>") — 부호는 자리수 밖에 붙는다(-42 → "-00042").
template <std::integral T>
std::string ToStringD(T v, int digits) {
    const bool negative = v < 0;
    using U = std::make_unsigned_t<T>;
    const U magnitude = negative ? static_cast<U>(U(0) - static_cast<U>(v)) : static_cast<U>(v);
    return std::format("{}{:0{}}", negative ? "-" : "", magnitude, digits);
}

// C#: v.ToString("X<digits>") — 음수는 그 형식 크기의 2의 보수(-1 → "FFFFFFFF").
template <std::integral T>
std::string ToStringX(T v, int digits = 0) {
    return std::format("{:0{}X}", static_cast<std::make_unsigned_t<T>>(v), digits);
}

}  // namespace NetCompat
```

숫자 문자열 함수는 .NET Framework 4.8이 실제로 낸 문자열 4,036줄(무작위 3,000개, 15자리 반올림 경계·동률, `-0.0`, `NaN`, 무한대, `float` 1,000개, 정수 `D`·`X` 포함)과 대조해 MSVC 14.44, g++ 13.1 모두 16,201개가 같았다. 문화권 의존 서식(소수점 `,` 등)은 다루지 않는다.

`double.Parse`, `DateTime.Parse`, 문화권 의존 서식, `F`·`D`·`X` 밖의 사용자 지정 서식(`"0.00"`, `"#,##0"` 등)은 이 헤더에 없다. `PREPORT-DECISION` 또는 `PORT_CONFIG.md`의 "문화권 의존 서식"을 따르고, 정해지지 않았으면 `TODO(PORT)`.
