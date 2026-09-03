// Ported from Services/Logger.cs
#pragma once

#include <fstream>
#include <string>

namespace SampleApp::Services {

// C# sealed class : IDisposable -> RAII: the destructor does what Dispose() did.
class Logger {
public:
    explicit Logger(const std::wstring& path);
    ~Logger() noexcept;

    Logger(const Logger&) = delete;
    Logger& operator=(const Logger&) = delete;

    [[nodiscard]] int Count() const noexcept { return count_; }

    void Log(const std::wstring& message);

private:
    std::ofstream writer_;     // StreamWriter -> UTF-8 narrow stream; not open when logging to the console
    bool toFile_ = false;
    int count_ = 0;
};

} // namespace SampleApp::Services
