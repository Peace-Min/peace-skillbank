// Ported from Models/Device.cs
#include "Models/Device.h"

#include "PortSupport.h"
#include "Util/StringHelpers.h"

namespace SampleApp::Models {

Device::Device(int id, std::wstring name, DeviceKind kind)
    : id_(id), name_(std::move(name)), kind_(kind), lastSeenTick_(std::nullopt)
{
    // C# threw ArgumentNullException when name == null; std::wstring cannot be null, so no check.
}

std::wstring Device::Describe() const
{
    const std::wstring seen = lastSeenTick_.has_value()
        ? PortSupport::ToWString(*lastSeenTick_)
        : std::wstring(L"never");
    return L"[" + Util::StringHelpers::PadId(id_) + L"] " + name_
        + L" (" + DeviceKindToString(kind_) + L") seen=" + seen;
}

std::wstring Device::ToString() const
{
    return Describe();
}

} // namespace SampleApp::Models
