// Ported from Util/NativeMethods.cs
#include "Util/NativeMethods.h"

#include "PortSupport.h"  // brings in <windows.h>

namespace SampleApp::Util::NativeMethods {

unsigned int GetTickCount()
{
    // [DllImport("kernel32.dll")] static extern uint GetTickCount(); -> direct Win32 call.
    return static_cast<unsigned int>(::GetTickCount());
}

bool ClockIsRunning()
{
    return GetTickCount() > 0;
}

} // namespace SampleApp::Util::NativeMethods
