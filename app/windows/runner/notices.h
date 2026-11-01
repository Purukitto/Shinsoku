#ifndef RUNNER_NOTICES_H_
#define RUNNER_NOTICES_H_

#include <windows.h>

#include <string>

// Windows toasts for an app without package identity: it registers itself
// under HKCU\Software\Classes\AppUserModelId, and clicks reach a COM callback
// this process registers while it runs. Dart builds the toast XML
// (lib/src/services/desktop_notices.dart).
namespace notices {

// Registers the app and its click callback. A click posts |message| to
// |window|, with the clicked toast's or button's arguments as a heap
// std::wstring* in lparam for the receiver to delete.
bool Init(HWND window, UINT message);

// Shows a toast, replacing an earlier one with the same |tag|.
bool Show(const std::wstring& xml, const std::wstring& tag);

void Shutdown();

}  // namespace notices

#endif  // RUNNER_NOTICES_H_
