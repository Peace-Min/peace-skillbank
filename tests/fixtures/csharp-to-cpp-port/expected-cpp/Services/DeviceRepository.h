// Ported from Services/DeviceRepository.cs
#pragma once

#include <functional>
#include <memory>
#include <unordered_map>
#include <vector>

#include "Models/Device.h"
#include "Models/DeviceKind.h"
#include "Services/Logger.h"

namespace SampleApp::Services {

class DeviceRepository {
public:
    // C# event EventHandler<Device> DeviceAdded -> subscribe with a callback.
    using DeviceAddedHandler = std::function<void(const std::shared_ptr<Models::Device>&)>;

    // C# constructor took a Logger that must not be null.
    explicit DeviceRepository(std::shared_ptr<Logger> logger);

    [[nodiscard]] int Count() const noexcept { return static_cast<int>(devices_.size()); }

    void SubscribeDeviceAdded(DeviceAddedHandler handler);

    void Add(std::shared_ptr<Models::Device> device);

    // Returns nullptr when not found (C# returned null).
    [[nodiscard]] std::shared_ptr<Models::Device> Find(int id) const;

    [[nodiscard]] std::vector<std::shared_ptr<Models::Device>> FindByKind(Models::DeviceKind kind) const;

    // TODO(port): was async Task<int>; runs synchronously.
    int RefreshAsync(int tick);

private:
    // C# List<Device> + Dictionary<int, Device> share the same instances -> shared_ptr.
    std::vector<std::shared_ptr<Models::Device>> devices_;
    std::unordered_map<int, std::shared_ptr<Models::Device>> byId_;
    std::shared_ptr<Logger> logger_;
    std::vector<DeviceAddedHandler> deviceAdded_;
};

} // namespace SampleApp::Services
