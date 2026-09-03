// Ported from Models/DeviceKind.cs
#pragma once

#include <string>

namespace SampleApp::Models {

enum class DeviceKind {
    Unknown = 0,
    Sensor = 1,
    Actuator = 2,
    Gateway = 3
};

// C# Enum.ToString() equivalent: returns the enumerator name.
std::wstring DeviceKindToString(DeviceKind kind);

// C# Enum.TryParse(text, ignoreCase: true, out kind) equivalent.
bool TryParseDeviceKind(const std::wstring& text, DeviceKind& kind);

} // namespace SampleApp::Models
