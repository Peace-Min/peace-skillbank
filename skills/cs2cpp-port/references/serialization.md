# 직렬화 · 메시지 · 문자 인코딩

목차: 1. 원본에서 읽을 것 · 2. ByteWriter/ByteReader · 3. 메시지 기반 클래스와 팩토리 · 4. 문자 인코딩 · 5. VisitFields (B안 전용)

## 1. 원본에서 먼저 읽을 것

바이트 순서, 헤더 구성, 문자열 인코딩은 이 스킬에 없다. **변환하는 C# 코드에서 읽고 그대로 따른다.**

| 읽을 것 | C# 원본에서 찾는 곳 | C++에서 |
|---|---|---|
| 바이트 순서 | `Endianness` 설정, `BitConverter.IsLittleEndian` 분기, `IPAddress.HostToNetworkOrder`, `Array.Reverse` | `ByteWriter`/`ByteReader` 생성자에 `ByteOrder::Big` 또는 `ByteOrder::Little` |
| 필드 순서·크기 | 메시지 클래스의 `Write(writer)`/`Read(reader)` 본문 | 같은 순서, 같은 크기로 한 줄씩 |
| 문자열 인코딩 | `Encoding.Default` / `Encoding.UTF8` / `Encoding.ASCII` / `Encoding.GetEncoding(n)` | 4절 변환 함수 |
| 문자열·bool·배열 기록 형식 | 직렬화 도구 클래스(Writer/Reader)의 `Write(string)`, `Write(bool)` 구현 | 원본대로. 도구 클래스 소스가 없으면 `TODO(PORT): 문자열 기록 형식 확인` |

C#의 `BinaryWriter`는 문자열 앞에 7비트 가변 길이를 붙이고 bool을 1바이트로 쓴다. 프로젝트 자체 Writer는 다를 수 있으니 구현을 확인한다.

## 2. ByteWriter / ByteReader

구조체 `memcpy`, `#pragma pack` 구조체 통째 송신은 쓰지 않는다. 필드 하나씩 C#의 `Write`/`Read` 순서대로 옮긴다.

```cpp
// ByteStream.h
#pragma once
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

enum class ByteOrder { Big, Little };

// C#: 직렬화 Writer. 바이트 순서는 원본 설정을 그대로 넘긴다.
class ByteWriter {
public:
    explicit ByteWriter(ByteOrder order) : mOrder(order) {}

    void WriteU8(uint8_t v) { mBuf.push_back(v); }
    void WriteI8(int8_t v) { mBuf.push_back(static_cast<uint8_t>(v)); }
    void WriteU16(uint16_t v) { WriteInt(v); }
    void WriteI16(int16_t v) { WriteInt(static_cast<uint16_t>(v)); }
    void WriteU32(uint32_t v) { WriteInt(v); }
    void WriteI32(int32_t v) { WriteInt(static_cast<uint32_t>(v)); }
    void WriteU64(uint64_t v) { WriteInt(v); }
    void WriteI64(int64_t v) { WriteInt(static_cast<uint64_t>(v)); }
    void WriteF32(float v) {
        uint32_t u = 0;
        std::memcpy(&u, &v, sizeof(u));
        WriteInt(u);
    }
    void WriteF64(double v) {
        uint64_t u = 0;
        std::memcpy(&u, &v, sizeof(u));
        WriteInt(u);
    }
    void WriteBytes(const uint8_t* p, size_t n) { mBuf.insert(mBuf.end(), p, p + n); }
    void WriteZeros(size_t n) { mBuf.insert(mBuf.end(), n, 0); }   // 예약 필드 채우기

    size_t Size() const { return mBuf.size(); }
    const std::vector<uint8_t>& Buffer() const { return mBuf; }
    // 길이 필드를 나중에 채울 때
    void PatchU16(size_t offset, uint16_t v) {
        const uint8_t hi = static_cast<uint8_t>(v >> 8);
        const uint8_t lo = static_cast<uint8_t>(v);
        mBuf[offset] = (mOrder == ByteOrder::Big) ? hi : lo;
        mBuf[offset + 1] = (mOrder == ByteOrder::Big) ? lo : hi;
    }

private:
    template <typename U>
    void WriteInt(U v) {
        for (size_t i = 0; i < sizeof(U); ++i) {
            const size_t shift = (mOrder == ByteOrder::Big) ? (sizeof(U) - 1 - i) * 8 : i * 8;
            mBuf.push_back(static_cast<uint8_t>(v >> shift));
        }
    }
    ByteOrder mOrder;
    std::vector<uint8_t> mBuf;
};

// C#: 직렬화 Reader. 길이가 모자라면 false를 반환하고 값은 바꾸지 않는다.
// C#은 이 경우 예외를 던진다 → 원본의 catch 동작(버림/로그)을 호출부에서 같게 만든다.
class ByteReader {
public:
    ByteReader(const uint8_t* p, size_t n, ByteOrder order) : mData(p), mSize(n), mOrder(order) {}

    bool ReadU8(uint8_t& v) { return ReadInt(v); }
    bool ReadI8(int8_t& v) { return ReadSigned<uint8_t>(v); }
    bool ReadU16(uint16_t& v) { return ReadInt(v); }
    bool ReadI16(int16_t& v) { return ReadSigned<uint16_t>(v); }
    bool ReadU32(uint32_t& v) { return ReadInt(v); }
    bool ReadI32(int32_t& v) { return ReadSigned<uint32_t>(v); }
    bool ReadU64(uint64_t& v) { return ReadInt(v); }
    bool ReadI64(int64_t& v) { return ReadSigned<uint64_t>(v); }
    bool ReadF32(float& v) {
        uint32_t u = 0;
        if (!ReadInt(u)) {
            return false;
        }
        std::memcpy(&v, &u, sizeof(v));
        return true;
    }
    bool ReadF64(double& v) {
        uint64_t u = 0;
        if (!ReadInt(u)) {
            return false;
        }
        std::memcpy(&v, &u, sizeof(v));
        return true;
    }
    bool ReadBytes(uint8_t* out, size_t n) {
        if (Remaining() < n) {
            return false;
        }
        std::memcpy(out, mData + mPos, n);
        mPos += n;
        return true;
    }
    bool Skip(size_t n) {
        if (Remaining() < n) {
            return false;
        }
        mPos += n;
        return true;
    }

    size_t Position() const { return mPos; }
    size_t Remaining() const { return mSize - mPos; }

private:
    template <typename U>
    bool ReadInt(U& v) {
        if (Remaining() < sizeof(U)) {
            return false;
        }
        U r = 0;
        for (size_t i = 0; i < sizeof(U); ++i) {
            const size_t shift = (mOrder == ByteOrder::Big) ? (sizeof(U) - 1 - i) * 8 : i * 8;
            r = static_cast<U>(r | (static_cast<U>(mData[mPos + i]) << shift));
        }
        mPos += sizeof(U);
        v = r;
        return true;
    }
    template <typename U, typename S>
    bool ReadSigned(S& v) {
        U u = 0;
        if (!ReadInt(u)) {
            return false;
        }
        v = static_cast<S>(u);
        return true;
    }

    const uint8_t* mData;
    size_t mSize;
    ByteOrder mOrder;
    size_t mPos = 0;
};
```

C# `Read`/`Write` 메서드 대응:

| C# | C++ |
|---|---|
| `writer.Write((ushort)x)` | `w.WriteU16(x)` |
| `writer.Write(floatValue)` | `w.WriteF32(v)` |
| `x = reader.ReadUInt16()` | `if (!r.ReadU16(x)) return false;` |
| `public override void Write(XxxWriter writer)` | `void Write(ByteWriter& w) const override` |
| `public override void Read(XxxReader reader)` | `bool Read(ByteReader& r) override` (실패 시 false) |
| `byte[] Reserved = new byte[4]` | `std::array<uint8_t, 4> Reserved{};` + `WriteBytes(Reserved.data(), 4)` |
| `new MemoryStream(buffer, offset, count)` + Reader | `ByteReader r(buffer + offset, count, order);` |

## 3. 메시지 기반 클래스와 팩토리

정리된 C#(`input-contract.md` 1절)에는 클래스마다 **명시 `Write`/`Read`**, **가상 속성(`AttrMsgId`)**, **팩토리 표**가 있다. 그것을 1:1로 옮긴다. 필드 순서는 C# 명시 코드의 문장 순서 그대로다.

```cpp
// MsgFactory.h (형태 예시 — 이름과 필드는 정리된 C#을 옮긴다)
#pragma once
#include <cstdint>
#include <functional>
#include <memory>
#include <unordered_map>
#include "ByteStream.h"

class MessageBase {
public:
    virtual ~MessageBase() = default;
    virtual uint16_t GetAttrMsgId() const = 0;        // C#: AttrMsgId
    virtual void Write(ByteWriter& w) const = 0;      // C#: 생성된 Write
    virtual bool Read(ByteReader& r) = 0;             // C#: 생성된 Read (길이 부족이면 false)
};

// C#: MsgFactory 표
using MsgCreator = std::function<std::shared_ptr<MessageBase>()>;

inline const std::unordered_map<uint16_t, MsgCreator>& GetMsgFactoryTable() {
    static const std::unordered_map<uint16_t, MsgCreator> table = {
        // { 0x0001, [] { return std::make_shared<Msg_0001>(); } },
        // 정리된 C# 표의 항목을 순서대로 하나도 빠짐없이
    };
    return table;
}

inline std::shared_ptr<MessageBase> CreateMsg(uint16_t msgId) {
    const auto& table = GetMsgFactoryTable();
    auto it = table.find(msgId);
    if (it == table.end()) {
        return nullptr;   // 정리된 C# MsgFactory.Create와 같은 결과로
    }
    return it->second();
}
```

표 항목 수를 보고에 적는다.

**원본에 자체 Writer/Reader 클래스가 있으면** 같은 이름의 C++ 클래스로 옮기고, 내부에서 `ByteWriter`/`ByteReader`를 쓴다. 메서드 이름·오버로드도 원본과 같게 둔다. 원본 Reader가 길이 부족에서 예외를 던지면 C++ Reader도 `ByteReader`의 `false`를 받는 즉시 같은 이름의 예외(`NetCompat::EndOfStreamException` 등)를 던진다. 호출부마다 `false` 처리를 새로 만들지 않기 위해서다.

**C# `Write(expr)` 오버로드는 식의 정적 형식으로 정해진다.** `writer.Write(a + b)`에서 `a`, `b`가 `byte`면 식은 `int`라 4바이트가 기록된다. C++에서도 같은 크기의 함수(`WriteI32`)를 고른다.

## 4. 문자 인코딩

내부는 UTF-8 `std::string`. **C# 원본이 바이트로 바꾸는 지점(`Encoding.XXX.GetBytes`/`GetString`, Writer의 문자열 기록)에서만** 원본과 같은 코드페이지로 바꾼다. 로그·콘솔은 UTF-8.

| C# | 코드페이지 |
|---|---|
| `Encoding.Default` (.NET Framework) | `CP_ACP` — 실행 PC의 ANSI 코드페이지. 한국어 Windows면 949. `PORT_CONFIG.md`에 번호가 있으면 그 번호 |
| `Encoding.UTF8` | 변환 없음 (내부가 UTF-8) |
| `Encoding.ASCII` | 변환 없음. C#은 0x7F 초과 문자를 `?`로 바꾸므로 한글이 들어가면 보고 |
| `Encoding.GetEncoding(949)` 등 | 그 번호 |
| `Encoding.Unicode` (UTF-16LE) | `ToWide(s, CP_UTF8)` 후 `wchar_t` 바이트를 little-endian으로 기록 |

```cpp
// TextEncoding.h
#pragma once
#include <string>
#include "Win32.h"

namespace TextEncoding {

inline std::wstring ToWide(const std::string& s, UINT codePage) {
    if (s.empty()) {
        return std::wstring();
    }
    const int n = MultiByteToWideChar(codePage, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
    if (n <= 0) {
        return std::wstring();
    }
    std::wstring w(static_cast<size_t>(n), L'\0');
    MultiByteToWideChar(codePage, 0, s.data(), static_cast<int>(s.size()), &w[0], n);
    return w;
}

inline std::string FromWide(const std::wstring& w, UINT codePage) {
    if (w.empty()) {
        return std::string();
    }
    const int n = WideCharToMultiByte(codePage, 0, w.data(), static_cast<int>(w.size()), nullptr, 0, nullptr, nullptr);
    if (n <= 0) {
        return std::string();
    }
    std::string s(static_cast<size_t>(n), '\0');
    WideCharToMultiByte(codePage, 0, w.data(), static_cast<int>(w.size()), &s[0], n, nullptr, nullptr);
    return s;
}

// C#: Encoding.Default.GetBytes / GetString
inline std::string Utf8ToAnsi(const std::string& utf8) { return FromWide(ToWide(utf8, CP_UTF8), CP_ACP); }
inline std::string AnsiToUtf8(const std::string& ansi) { return FromWide(ToWide(ansi, CP_ACP), CP_UTF8); }

}  // namespace TextEncoding
```


## 5. VisitFields (B안 전용: C# 리플렉션을 그대로 두고 C++ 코드를 직접 생성할 때)

C#에 명시 `Write`/`Read`가 있으면(A안) 이 절은 쓰지 않는다. B안이면 C# 생성기가 클래스마다 아래 `VisitFields`를 출력한다. 필드 목록이 한 곳뿐이라 `Write`와 `Read`의 순서가 어긋날 수 없다.

```cpp
// FieldVisit.h
#pragma once
#include <array>
#include <cstddef>
#include <cstdint>
#include <type_traits>
#include "ByteStream.h"

// 기록 방문자. 형식별 기록 방식은 C# 원본 Writer의 형식 분기와 같게 맞춘다.
struct FieldWriter {
    ByteWriter& w;
    void operator()(uint8_t v) { w.WriteU8(v); }
    void operator()(int8_t v) { w.WriteI8(v); }
    void operator()(uint16_t v) { w.WriteU16(v); }
    void operator()(int16_t v) { w.WriteI16(v); }
    void operator()(uint32_t v) { w.WriteU32(v); }
    void operator()(int32_t v) { w.WriteI32(v); }
    void operator()(uint64_t v) { w.WriteU64(v); }
    void operator()(int64_t v) { w.WriteI64(v); }
    void operator()(float v) { w.WriteF32(v); }
    void operator()(double v) { w.WriteF64(v); }
    void operator()(bool v) { w.WriteU8(v ? 1 : 0); }   // TODO(PORT): 원본 bool 기록 형식 확인
    template <size_t N>
    void operator()(const std::array<uint8_t, N>& a) { w.WriteBytes(a.data(), N); }
    template <typename E, typename = std::enable_if_t<std::is_enum<E>::value>>
    void operator()(E e) { (*this)(static_cast<std::underlying_type_t<E>>(e)); }
};

// 판독 방문자. 한 번 실패하면 이후 필드는 읽지 않는다.
struct FieldReader {
    ByteReader& r;
    bool ok = true;
    void operator()(uint8_t& v) { ok = ok && r.ReadU8(v); }
    void operator()(int8_t& v) { ok = ok && r.ReadI8(v); }
    void operator()(uint16_t& v) { ok = ok && r.ReadU16(v); }
    void operator()(int16_t& v) { ok = ok && r.ReadI16(v); }
    void operator()(uint32_t& v) { ok = ok && r.ReadU32(v); }
    void operator()(int32_t& v) { ok = ok && r.ReadI32(v); }
    void operator()(uint64_t& v) { ok = ok && r.ReadU64(v); }
    void operator()(int64_t& v) { ok = ok && r.ReadI64(v); }
    void operator()(float& v) { ok = ok && r.ReadF32(v); }
    void operator()(double& v) { ok = ok && r.ReadF64(v); }
    void operator()(bool& v) {
        uint8_t b = 0;
        if (ok && r.ReadU8(b)) {
            v = (b != 0);
        } else {
            ok = false;
        }
    }
    template <size_t N>
    void operator()(std::array<uint8_t, N>& a) { ok = ok && r.ReadBytes(a.data(), N); }
    template <typename E, typename = std::enable_if_t<std::is_enum<E>::value>>
    void operator()(E& e) {
        std::underlying_type_t<E> u{};
        (*this)(u);
        if (ok) {
            e = static_cast<E>(u);
        }
    }
};
```

```cpp
// 생성기 출력 예
struct StatusMsg : MessageBase {
    uint16_t Id = 0;
    double Lat = 0.0;
    std::array<uint8_t, 4> Reserved{};

    template <typename Self, typename V>
    static void VisitFields(Self& s, V& v) { v(s.Id); v(s.Lat); v(s.Reserved); }   // C# 속성 캐시 순서

    uint16_t GetAttrMsgId() const override { return 0x0101; }
    void Write(ByteWriter& w) const override { FieldWriter fw{w}; VisitFields(*this, fw); }
    bool Read(ByteReader& r) override { FieldReader fr{r}; VisitFields(*this, fr); return fr.ok; }
};
```
