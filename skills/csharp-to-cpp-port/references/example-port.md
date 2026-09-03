C# input `Config/AppSettings.cs` (properties, `double`/`bool` formatting, `Dictionary`, `lock`, `IDisposable`, file output):

```csharp
using System;
using System.Collections.Generic;
using System.IO;

namespace Demo.Config
{
    public class AppSettings : IDisposable
    {
        private readonly object _sync = new object();
        private readonly Dictionary<string, int> _limits = new Dictionary<string, int>();
        private readonly StreamWriter _log;

        public string Name { get; set; }
        public double Threshold { get; set; }
        public bool Enabled { get; set; }

        public AppSettings(string name, string logPath)
        {
            Name = name;
            Threshold = 0.5;
            Enabled = true;
            _log = new StreamWriter(logPath, false);
        }

        public void SetLimit(string key, int value)
        {
            lock (_sync)
            {
                _limits[key] = value;
                _log.WriteLine("limit " + key + "=" + value);
            }
        }

        public int GetLimit(string key)
        {
            lock (_sync)
            {
                int found;
                return _limits.TryGetValue(key, out found) ? found : -1;
            }
        }

        public override string ToString()
        {
            return $"{Name}: threshold={Threshold} enabled={Enabled} limits={_limits.Count}";
        }

        public void Dispose()
        {
            _log.Flush();
            _log.Dispose();
        }
    }
}
```

Correct output (agent mode: these two files are created with the file tool; paste mode: this exact text is the reply):

// FILE: Config/AppSettings.h
```cpp
// Ported from Config/AppSettings.cs
#pragma once

#include <fstream>
#include <mutex>
#include <string>
#include <unordered_map>

namespace Demo::Config {

// C# class : IDisposable -> RAII: the destructor does what Dispose() did.
class AppSettings {
public:
    AppSettings(const std::wstring& name, const std::wstring& logPath);
    ~AppSettings() noexcept;

    AppSettings(const AppSettings&) = delete;
    AppSettings& operator=(const AppSettings&) = delete;

    [[nodiscard]] const std::wstring& Name() const noexcept { return name_; }
    void SetName(const std::wstring& value) { name_ = value; }

    [[nodiscard]] double Threshold() const noexcept { return threshold_; }
    void SetThreshold(double value) { threshold_ = value; }

    [[nodiscard]] bool Enabled() const noexcept { return enabled_; }
    void SetEnabled(bool value) { enabled_ = value; }

    void SetLimit(const std::wstring& key, int value);
    [[nodiscard]] int GetLimit(const std::wstring& key);

    // C# ToString() override.
    [[nodiscard]] std::wstring ToString() const;

private:
    std::recursive_mutex sync_;                       // lock (_sync): Monitor is re-entrant
    std::unordered_map<std::wstring, int> limits_;
    std::ofstream log_;                               // StreamWriter -> UTF-8 narrow stream
    std::wstring name_;
    double threshold_ = 0.0;
    bool enabled_ = false;
};

} // namespace Demo::Config
```

// FILE: Config/AppSettings.cpp
```cpp
// Ported from Config/AppSettings.cs
#include "Config/AppSettings.h"

#include "PortSupport.h"

namespace Demo::Config {

AppSettings::AppSettings(const std::wstring& name, const std::wstring& logPath)
    : log_(PortSupport::OpenTextFile(logPath)), name_(name), threshold_(0.5), enabled_(true)
{
}

AppSettings::~AppSettings() noexcept
{
    // C# Dispose(): flush + dispose the StreamWriter.
    log_.flush();
    log_.close();
}

void AppSettings::SetLimit(const std::wstring& key, int value)
{
    std::lock_guard<std::recursive_mutex> guard(sync_);
    limits_[key] = value;
    PortSupport::WriteLine(log_, L"limit " + key + L"=" + PortSupport::ToWString(value));
}

int AppSettings::GetLimit(const std::wstring& key)
{
    std::lock_guard<std::recursive_mutex> guard(sync_);
    const auto found = limits_.find(key);
    return found != limits_.end() ? found->second : -1;
}

std::wstring AppSettings::ToString() const
{
    // $"{Name}: threshold={Threshold} enabled={Enabled} limits={_limits.Count}"
    return name_ + L": threshold=" + PortSupport::ToWString(threshold_)
        + L" enabled=" + PortSupport::ToWString(enabled_)
        + L" limits=" + PortSupport::ToWString(static_cast<int>(limits_.size()));
}

} // namespace Demo::Config
```
