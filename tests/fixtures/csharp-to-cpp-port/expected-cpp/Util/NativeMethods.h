// Ported from Util/NativeMethods.cs
#pragma once

namespace SampleApp::Util {

// C# P/Invoke wrappers become direct Win32 calls behind the same names.
namespace NativeMethods {

unsigned int GetTickCount();
bool ClockIsRunning();

} // namespace NativeMethods
} // namespace SampleApp::Util
