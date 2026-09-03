// Ported from Util/StringHelpers.cs
#include "Util/StringHelpers.h"

#include <cwctype>

#include "PortSupport.h"

namespace SampleApp::Util::StringHelpers {

std::wstring PadId(int id)
{
    std::wstring text = PortSupport::ToWString(id);
    if (text.size() < 4) {
        text.insert(0, 4 - text.size(), L'0');
    }
    return text;
}

std::wstring JoinLines(const std::vector<std::wstring>& lines)
{
    std::wstring result;
    bool first = true;
    for (const std::wstring& line : lines) {
        if (!first) result.push_back(L'\n');
        result += line;
        first = false;
    }
    return result;
}

bool IsBlank(const std::wstring& value)
{
    for (wchar_t ch : value) {
        if (!std::iswspace(ch)) return false;
    }
    return true;
}

} // namespace SampleApp::Util::StringHelpers
