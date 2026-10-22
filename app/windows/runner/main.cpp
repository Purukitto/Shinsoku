#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <algorithm>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  // Launched by the startup entry (see autostart_service.dart).
  const bool autostart =
      std::find(command_line_arguments.begin(), command_line_arguments.end(),
                "--autostart") != command_line_arguments.end();

  // One copy per user session: two would run two engines over the same
  // download files. Opening the app again brings the running copy forward;
  // a startup launch while it already runs just exits.
  HANDLE single_instance =
      ::CreateMutexW(nullptr, FALSE, L"Local\\xyz.purukitto.shinsoku");
  if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND running = FlutterWindow::FindRunning();
    if (running && !autostart) {
      DWORD pid = 0;
      ::GetWindowThreadProcessId(running, &pid);
      ::AllowSetForegroundWindow(pid);
      ::PostMessageW(running, FlutterWindow::ShowMessage(), 0, 0);
    }
    ::CloseHandle(single_instance);
    return EXIT_SUCCESS;
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, autostart);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"shinsoku", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  ::CloseHandle(single_instance);
  return EXIT_SUCCESS;
}
