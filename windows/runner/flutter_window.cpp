#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Marks the main window of this app among the windows of every Flutter app,
// which all share one window class.
constexpr wchar_t kMainWindowProp[] = L"kzs.th000.tsdm_client.MainWindow";

// Answer of a hidden main window that showed itself.
constexpr LRESULT kHiddenInstanceShown = 0x7473646D;

UINT ShowHiddenInstanceMessage() {
  static const UINT message =
      ::RegisterWindowMessageW(L"kzs.th000.tsdm_client.ShowHiddenInstance");
  return message;
}

BOOL CALLBACK ShowIfHidden(HWND hwnd, LPARAM lparam) {
  const UINT message = ShowHiddenInstanceMessage();
  if (message == 0 || !::GetPropW(hwnd, kMainWindowProp) ||
      ::IsWindowVisible(hwnd)) {
    return TRUE;
  }
  DWORD process_id = 0;
  ::GetWindowThreadProcessId(hwnd, &process_id);
  // This launch is in the foreground: let the earlier one take it.
  ::AllowSetForegroundWindow(process_id);
  DWORD_PTR reply = 0;
  if (::SendMessageTimeoutW(hwnd, message, 0, 0, SMTO_ABORTIFHUNG, 3000,
                            &reply) &&
      reply == static_cast<DWORD_PTR>(kHiddenInstanceShown)) {
    *reinterpret_cast<bool*>(lparam) = true;
    return FALSE;
  }
  return TRUE;
}

}  // namespace

bool ShowHiddenInstance() {
  bool shown = false;
  ::EnumWindows(ShowIfHidden, reinterpret_cast<LPARAM>(&shown));
  return shown;
}

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
    // Marked once shown: a window still waiting for its first frame is not
    // one hidden in the tray.
    ::SetPropW(GetHandle(), kMainWindowProp, reinterpret_cast<HANDLE>(1));
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  ::RemovePropW(GetHandle(), kMainWindowProp);
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // A later launch found this window hidden in the tray (ShowHiddenInstance).
  const UINT show_hidden = ShowHiddenInstanceMessage();
  if (show_hidden != 0 && message == show_hidden) {
    if (::IsWindowVisible(hwnd)) {
      return 0;
    }
    ::ShowWindow(hwnd, ::IsIconic(hwnd) ? SW_RESTORE : SW_SHOW);
    ::SetForegroundWindow(hwnd);
    return kHiddenInstanceShown;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_EXITMENULOOP:
      if (wparam) {
        // tray_manager foregrounds this window before TrackPopupMenu, but does
        // not post the benign message Windows requires after a tray menu closes.
        // Queue it when the shortcut menu exits so the next menu stays open.
        ::PostMessage(hwnd, WM_NULL, 0, 0);
      }
      return 0;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
