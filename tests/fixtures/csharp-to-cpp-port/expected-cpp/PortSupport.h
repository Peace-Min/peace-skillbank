// PortSupport.h - fixed helpers shared by every ported unit.
// Copied to <CppRoot>\PortSupport.h by make-unit-prompt.ps1. Do not edit per unit; do not re-declare.
// Every helper here exists because a naive C++ equivalent silently differs from .NET Framework behaviour.
#pragma once

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <filesystem>
#include <fstream>
#include <io.h>
#include <iomanip>
#include <sstream>
#include <string>

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>

namespace PortSupport {

// UTF-16 (std::wstring, same as .NET string) <-> UTF-8 bytes (files, sockets, narrow APIs).
inline std::string ToUtf8(const std::wstring& text)
{
    if (text.empty()) return std::string();
    const int size = ::WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
    std::string out(static_cast<size_t>(size), '\0');
    ::WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), &out[0], size, nullptr, nullptr);
    return out;
}

inline std::wstring FromUtf8(const std::string& bytes)
{
    if (bytes.empty()) return std::wstring();
    const int size = ::MultiByteToWideChar(CP_UTF8, 0, bytes.data(), static_cast<int>(bytes.size()), nullptr, 0);
    std::wstring out(static_cast<size_t>(size), L'\0');
    ::MultiByteToWideChar(CP_UTF8, 0, bytes.data(), static_cast<int>(bytes.size()), &out[0], size);
    return out;
}

namespace detail {
// .NET Framework "G15"/"G7" spelling: NaN, Infinity, -Infinity, no negative zero, E+NN exponent.
inline std::wstring FormatGeneral(double value, int significant)
{
    if (std::isnan(value)) return L"NaN";
    if (std::isinf(value)) return value < 0 ? L"-Infinity" : L"Infinity";
    if (value == 0.0) return L"0";
    std::wostringstream out;
    out << std::defaultfloat << std::setprecision(significant) << value;
    std::wstring s = out.str();
    const size_t e = s.find(L'e');
    if (e != std::wstring::npos) {
        // C++ prints 1e+15 / 1e-05; .NET prints 1E+15 / 1E-05.
        s[e] = L'E';
    }
    if (s == L"-0") s = L"0";
    return s;
}

// Digits of |value| as .NET Framework sees them: 15 significant decimal digits, then rounded
// half away from zero at `decimals` fractional digits (Framework rounds the decimal, not the binary).
inline std::wstring FormatFixedFramework(double value, int decimals)
{
    if (std::isnan(value)) return L"NaN";
    if (std::isinf(value)) return value < 0 ? L"-Infinity" : L"Infinity";
    if (decimals < 0) decimals = 0;
    if (decimals > 15) decimals = 15;
    const bool negative = value < 0;
    const double mag = negative ? -value : value;
    char buf[64];
    std::snprintf(buf, sizeof(buf), "%.14e", mag);   // d.dddddddddddddde+XX : 15 significant digits
    std::string mant(buf);
    const size_t epos = mant.find('e');
    int exp10 = std::atoi(mant.c_str() + epos + 1);
    std::string digits;
    for (size_t i = 0; i < epos; ++i) if (mant[i] >= '0' && mant[i] <= '9') digits.push_back(mant[i]);
    // digits = 15 digits, value = 0.d1d2... * 10^(exp10+1)
    int intLen = exp10 + 1;                          // digits before the decimal point (may be <= 0)
    std::string all = digits;
    if (intLen <= 0) { all.insert(0, static_cast<size_t>(-intLen), '0'); intLen = 0; }
    while (static_cast<int>(all.size()) < intLen + decimals + 1) all.push_back('0');
    // round half away from zero at position intLen+decimals
    const size_t cut = static_cast<size_t>(intLen + decimals);
    bool roundUp = all[cut] >= '5';
    std::string kept = all.substr(0, cut);
    if (roundUp) {
        int i = static_cast<int>(kept.size()) - 1;
        while (i >= 0) { if (kept[i] == '9') { kept[i] = '0'; --i; } else { kept[i]++; break; } }
        if (i < 0) { kept.insert(0, 1, '1'); ++intLen; }
    }
    std::string intPart = kept.substr(0, static_cast<size_t>(intLen));
    std::string fracPart = kept.substr(static_cast<size_t>(intLen));
    // strip leading zeros of the integer part
    size_t nz = intPart.find_first_not_of('0');
    intPart = (nz == std::string::npos) ? "0" : intPart.substr(nz);
    std::string result = intPart;
    if (decimals > 0) result += "." + fracPart;
    bool allZero = result.find_first_not_of("0.") == std::string::npos;
    std::wstring w(result.begin(), result.end());
    if (negative && !allZero) w.insert(0, 1, L'-');   // Framework never prints -0.00
    return w;
}
} // namespace detail

// .NET Framework double.ToString() is "G15"; float.ToString() is "G7"; bool prints True/False.
inline std::wstring ToWString(double value) { return detail::FormatGeneral(value, 15); }
inline std::wstring ToWString(float value) { return detail::FormatGeneral(static_cast<double>(value), 7); }
inline std::wstring ToWString(bool value) { return value ? L"True" : L"False"; }
inline std::wstring ToWString(int value) { return std::to_wstring(value); }
inline std::wstring ToWString(unsigned int value) { return std::to_wstring(value); }
inline std::wstring ToWString(long value) { return std::to_wstring(value); }
inline std::wstring ToWString(unsigned long value) { return std::to_wstring(value); }
inline std::wstring ToWString(long long value) { return std::to_wstring(value); }
inline std::wstring ToWString(unsigned long long value) { return std::to_wstring(value); }
inline std::wstring ToWString(const std::wstring& value) { return value; }
inline std::wstring ToWString(const wchar_t* value) { return std::wstring(value); }

// C# ToString("F2"): .NET Framework rounds the 15-digit decimal half away from zero (2.675 -> "2.68").
inline std::wstring ToFixed(double value, int decimals) { return detail::FormatFixedFramework(value, decimals); }

// Text files: write UTF-8 bytes through a narrow stream (a std::wofstream silently drops non-ASCII).
inline std::ofstream OpenTextFile(const std::wstring& path, bool append = false)
{
    return std::ofstream(std::filesystem::path(path), append ? (std::ios::out | std::ios::app) : (std::ios::out | std::ios::trunc));
}
inline void WriteLine(std::ofstream& file, const std::wstring& line)
{
    file << ToUtf8(line) << '\n';
}
inline std::ifstream OpenTextFileForRead(const std::wstring& path)
{
    return std::ifstream(std::filesystem::path(path));
}
inline bool ReadLine(std::ifstream& file, std::wstring& line)
{
    std::string bytes;
    if (!std::getline(file, bytes)) return false;
    if (!bytes.empty() && bytes.back() == '\r') bytes.pop_back();
    line = FromUtf8(bytes);
    return true;
}

// Call once at the top of wmain: std::wcout / std::wcerr then emit UTF-8 like Console.WriteLine.
// HAZARD: after this call any NARROW write to stdout (std::cout, printf, puts, fputs, fwrite, putchar)
// silently discards that output and everything written afterwards. Use std::wcout only.
inline void InitConsole()
{
    ::_setmode(::_fileno(stdout), _O_U8TEXT);
    ::_setmode(::_fileno(stderr), _O_U8TEXT);
}

} // namespace PortSupport
