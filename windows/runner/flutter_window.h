#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>
#include <vector>

#include "win32_window.h"

// The Flutter view, and the medut/desktop channel a second launch's
// arguments arrive on (WM_COPYDATA from main.cpp).
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  // |start_hidden|: started at login, so the first frame does not show it.
  FlutterWindow(const flutter::DartProject& project, bool start_hidden);
  virtual ~FlutterWindow();

  // The WM_COPYDATA tag a second launch sends its arguments with.
  static constexpr ULONG_PTR kOpenArgs = 0x4D454455;  // "MEDU"

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  bool start_hidden_;

  // Brings the window up and hands Dart a second launch's arguments.
  void OpenArgs(const std::vector<std::string>& args);
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
