// Ported from Models/DeviceKind.cs
#include "Models/DeviceKind.h"

#include <cwctype>

namespace SampleApp::Models {

std::wstring DeviceKindToString(DeviceKind kind)
{
    switch (kind) {
    case DeviceKind::Sensor:   return L"Sensor";
    case DeviceKind::Actuator: return L"Actuator";
    case DeviceKind::Gateway:  return L"Gateway";
    case DeviceKind::Unknown:
    default:                   return L"Unknown";
    }
}

bool TryParseDeviceKind(const std::wstring& text, DeviceKind& kind)
{
    std::wstring lower;
    lower.reserve(text.size());
    for (wchar_t ch : text) {
        lower.push_back(static_cast<wchar_t>(std::towlower(ch)));
    }
    if (lower == L"unknown")  { kind = DeviceKind::Unknown;  return true; }
    if (lower == L"sensor")   { kind = DeviceKind::Sensor;   return true; }
    if (lower == L"actuator") { kind = DeviceKind::Actuator; return true; }
    if (lower == L"gateway")  { kind = DeviceKind::Gateway;  return true; }
    // Enum.TryParse also accepts the numeric value as text ("2").
    bool digits = !lower.empty();
    for (wchar_t ch : lower) { if (!std::iswdigit(ch)) { digits = false; break; } }
    if (digits) {
        const int value = std::stoi(lower);
        if (value >= 0 && value <= 3) { kind = static_cast<DeviceKind>(value); return true; }
    }
    return false;
}

} // namespace SampleApp::Models
