// Ported from Models/Device.cs
#pragma once

#include <optional>
#include <string>

#include "Models/DeviceKind.h"

namespace SampleApp::Models {

class Device {
public:
    Device(int id, std::wstring name, DeviceKind kind);

    [[nodiscard]] int Id() const noexcept { return id_; }

    [[nodiscard]] const std::wstring& Name() const noexcept { return name_; }
    void SetName(std::wstring value) { name_ = std::move(value); }

    [[nodiscard]] DeviceKind Kind() const noexcept { return kind_; }
    void SetKind(DeviceKind value) noexcept { kind_ = value; }

    [[nodiscard]] const std::optional<int>& LastSeenTick() const noexcept { return lastSeenTick_; }
    void SetLastSeenTick(std::optional<int> value) noexcept { lastSeenTick_ = value; }

    [[nodiscard]] bool IsOnline() const noexcept { return lastSeenTick_.has_value(); }

    [[nodiscard]] std::wstring Describe() const;

    // C# ToString() override.
    [[nodiscard]] std::wstring ToString() const;

private:
    int id_ = 0;
    std::wstring name_;
    DeviceKind kind_ = DeviceKind::Unknown;
    std::optional<int> lastSeenTick_;
};

} // namespace SampleApp::Models
