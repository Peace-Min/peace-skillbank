// Ported from Services/DeviceRepository.cs
#include "Services/DeviceRepository.h"

#include <algorithm>
#include <chrono>
#include <stdexcept>
#include <thread>

#include "PortSupport.h"

namespace SampleApp::Services {

using Models::Device;
using Models::DeviceKind;

DeviceRepository::DeviceRepository(std::shared_ptr<Logger> logger)
    : logger_(std::move(logger))
{
    if (logger_ == nullptr) {
        throw std::invalid_argument("logger");  // ArgumentNullException(nameof(logger))
    }
}

void DeviceRepository::SubscribeDeviceAdded(DeviceAddedHandler handler)
{
    deviceAdded_.push_back(std::move(handler));
}

void DeviceRepository::Add(std::shared_ptr<Device> device)
{
    if (byId_.find(device->Id()) != byId_.end()) {
        throw std::logic_error("duplicate id " + std::to_string(device->Id()));  // InvalidOperationException
    }
    devices_.push_back(device);
    byId_[device->Id()] = device;
    logger_->Log(L"added " + device->Name());
    // DeviceAdded?.Invoke(this, device)
    for (const DeviceAddedHandler& handler : deviceAdded_) {
        handler(device);
    }
}

std::shared_ptr<Device> DeviceRepository::Find(int id) const
{
    auto it = byId_.find(id);
    return it != byId_.end() ? it->second : nullptr;
}

std::vector<std::shared_ptr<Device>> DeviceRepository::FindByKind(DeviceKind kind) const
{
    // .Where(d => d.Kind == kind)
    std::vector<std::shared_ptr<Device>> result;
    std::copy_if(devices_.begin(), devices_.end(), std::back_inserter(result),
        [kind](const std::shared_ptr<Device>& d) { return d->Kind() == kind; });
    // .OrderBy(d => d.Name, StringComparer.Ordinal)  (OrderBy is a stable sort)
    std::stable_sort(result.begin(), result.end(),
        [](const std::shared_ptr<Device>& a, const std::shared_ptr<Device>& b) {
            return a->Name() < b->Name();  // std::wstring operator< is ordinal
        });
    return result;  // .ToList()
}

int DeviceRepository::RefreshAsync(int tick)
{
    std::this_thread::sleep_for(std::chrono::milliseconds(1));  // await Task.Delay(1)
    int touched = 0;
    for (const std::shared_ptr<Device>& d : devices_) {
        if (d->Kind() != DeviceKind::Unknown) {
            d->SetLastSeenTick(tick);
            touched++;
        }
    }
    logger_->Log(L"refreshed " + PortSupport::ToWString(touched));
    return touched;
}

} // namespace SampleApp::Services
