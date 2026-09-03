// Ported from Util/StringHelpers.cs
#pragma once

#include <string>
#include <vector>

namespace SampleApp::Util {

// C# static class -> namespace of free functions (no instances possible).
namespace StringHelpers {

std::wstring PadId(int id);
std::wstring JoinLines(const std::vector<std::wstring>& lines);
bool IsBlank(const std::wstring& value);

} // namespace StringHelpers
} // namespace SampleApp::Util
