#include "PortSupport.h"
#include <iostream>
#include <limits>
int wmain() {
    PortSupport::InitConsole();
    long l = 5; DWORD d = 7; unsigned long ul = 9;
    std::wcout << PortSupport::ToWString(l) << L"|" << PortSupport::ToWString(d) << L"|" << PortSupport::ToWString(ul) << L"\n";
    std::wcout << PortSupport::ToWString(1e15) << L"|" << PortSupport::ToWString(0.00001) << L"|" << PortSupport::ToWString(std::numeric_limits<double>::quiet_NaN()) << L"|" << PortSupport::ToWString(std::numeric_limits<double>::infinity()) << L"|" << PortSupport::ToWString(-0.0) << L"|" << PortSupport::ToWString(4.0 / 3.0) << L"|" << PortSupport::ToWString(1.5) << L"|" << PortSupport::ToWString(100.0) << L"\n";
    std::wcout << PortSupport::ToFixed(2.675, 2) << L"|" << PortSupport::ToFixed(0.125, 2) << L"|" << PortSupport::ToFixed(1.005, 2) << L"|" << PortSupport::ToFixed(0.045, 2) << L"|" << PortSupport::ToFixed(8.325, 2) << L"|" << PortSupport::ToFixed(0.5, 0) << L"|" << PortSupport::ToFixed(2.5, 0) << L"|" << PortSupport::ToFixed(-0.001, 2) << L"|" << PortSupport::ToFixed(-2.675, 2) << L"|" << PortSupport::ToFixed(1234.5678, 2) << L"|" << PortSupport::ToFixed(0.0, 2) << L"|" << PortSupport::ToFixed(99.995, 2) << L"\n";
    return 0;
}
