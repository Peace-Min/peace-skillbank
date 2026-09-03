// Ported from Services/Logger.cs
#include "Services/Logger.h"

#include <iostream>

#include "PortSupport.h"

namespace SampleApp::Services {

Logger::Logger(const std::wstring& path)
{
    if (!path.empty()) {
        writer_ = PortSupport::OpenTextFile(path);
        toFile_ = true;
    }
}

Logger::~Logger() noexcept
{
    // C# Dispose(): flush + dispose the StreamWriter.
    if (toFile_) {
        writer_.flush();
        writer_.close();
    }
}

void Logger::Log(const std::wstring& message)
{
    // string.Format("LOG {0}: {1}", _count, message)
    const std::wstring line = L"LOG " + PortSupport::ToWString(count_) + L": " + message;
    count_++;
    if (toFile_) {
        PortSupport::WriteLine(writer_, line);
    } else {
        std::wcout << line << L'\n';
    }
}

} // namespace SampleApp::Services
