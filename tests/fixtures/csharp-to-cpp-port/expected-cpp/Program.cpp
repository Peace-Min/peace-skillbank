// Ported from Program.cs
#include <algorithm>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

#include "PortSupport.h"
#include "Models/Device.h"
#include "Models/DeviceKind.h"
#include "Services/DeviceRepository.h"
#include "Services/Logger.h"
#include "Util/NativeMethods.h"
#include "Util/StringHelpers.h"

using namespace SampleApp::Models;
using namespace SampleApp::Services;
using namespace SampleApp::Util;

// C# static int Main(string[] args) -> wmain so args arrive as UTF-16 like .NET strings.
int wmain(int argc, wchar_t* argv[])
{
    PortSupport::InitConsole();

    DeviceKind filter = DeviceKind::Sensor;
    if (argc > 1 && !StringHelpers::IsBlank(argv[1])) {
        if (!TryParseDeviceKind(argv[1], filter)) {
            std::wcout << L"unknown kind: " << argv[1] << L'\n';
            return 2;
        }
    }

    {   // using (var logger = new Logger(null)) { ... } -> scoped RAII
        auto logger = std::make_shared<Logger>(L"");   // Logger: SHARED (constructor parameter)
        DeviceRepository repo(logger);                  // DeviceRepository: SINGLE owner -> plain value
        std::vector<std::wstring> added;
        repo.SubscribeDeviceAdded([&added](const std::shared_ptr<Device>& device) {
            added.push_back(device->Name());
        });

        repo.Add(std::make_shared<Device>(3, L"thermo-b", DeviceKind::Sensor));
        repo.Add(std::make_shared<Device>(1, L"valve-1", DeviceKind::Actuator));
        repo.Add(std::make_shared<Device>(2, L"thermo-a", DeviceKind::Sensor));
        repo.Add(std::make_shared<Device>(7, L"edge-gw", DeviceKind::Gateway));

        auto joined = StringHelpers::JoinLines(added);
        std::replace(joined.begin(), joined.end(), L'\n', L',');
        std::wcout << L"added: " << joined << L'\n';
        std::wcout << L"count: " << PortSupport::ToWString(repo.Count()) << L'\n';
        std::wcout << L"장치 수: " << PortSupport::ToWString(repo.Count()) << L'\n';

        const int touched = repo.RefreshAsync(42);  // .GetAwaiter().GetResult() -> plain call (was async)
        std::wcout << L"touched: " << PortSupport::ToWString(touched) << L'\n';

        for (const auto& d : repo.FindByKind(filter)) {
            std::wcout << d->Describe() << L'\n';
        }

        const auto missing = repo.Find(99);
        std::wcout << L"find(99): " << (missing == nullptr ? std::wstring(L"null") : missing->Name()) << L'\n';
        std::wcout << L"online(2): " << PortSupport::ToWString(repo.Find(2)->IsOnline()) << L'\n';
        std::wcout << L"ratio: " << PortSupport::ToWString(repo.Count() / 8.0) << L'\n';
        std::wcout << L"ratio2: " << PortSupport::ToFixed(repo.Count() / 3.0, 2) << L'\n';
        std::wcout << L"clock: " << (NativeMethods::ClockIsRunning() ? L"running" : L"stopped") << L'\n';
        std::wcout << L"log lines: " << PortSupport::ToWString(logger->Count()) << L'\n';
    }

    return 0;
}
