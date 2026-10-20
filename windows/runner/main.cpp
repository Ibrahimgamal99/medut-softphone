#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <algorithm>
#include <string>

#include "flutter_window.h"
#include "utils.h"

// One Medut per user session: a second launch (a tel:/sip: link, the Start
// menu, the command line) hands its arguments to the running one and exits.
static bool HandOverToRunningInstance(const std::vector<std::string>& args) {
  HWND existing = ::FindWindowW(L"MEDUT_PHONE_WINDOW", nullptr);
  if (existing == nullptr) return false;
  std::string text;
  for (const auto& a : args) text += a + "\n";
  COPYDATASTRUCT data{};
  data.dwData = FlutterWindow::kOpenArgs;
  data.cbData = static_cast<DWORD>(text.size());
  data.lpData = text.data();
  // Let it come to the front: Windows only allows that to the foreground app.
  DWORD pid = 0;
  ::GetWindowThreadProcessId(existing, &pid);
  ::AllowSetForegroundWindow(pid);
  ::SendMessageW(existing, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&data));
  return true;
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  HANDLE instance_mutex =
      ::CreateMutexW(nullptr, TRUE, L"Local\\com.medut.generic.phone");
  if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    HandOverToRunningInstance(command_line_arguments);
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  const bool start_hidden =
      std::find(command_line_arguments.begin(), command_line_arguments.end(),
                "--minimized") != command_line_arguments.end();
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, start_hidden);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1040, 720);
  if (!window.Create(L"Medut", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (instance_mutex != nullptr) ::CloseHandle(instance_mutex);
  return EXIT_SUCCESS;
}
