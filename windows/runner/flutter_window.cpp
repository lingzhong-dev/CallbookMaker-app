#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {

constexpr UINT_PTR kInitialSurfaceNudgeTimerId = 1001;
constexpr UINT_PTR kInitialSurfaceRestoreTimerId = 1002;
constexpr UINT kInitialSurfaceNudgeDelayMs = 120;
constexpr UINT kInitialSurfaceRestoreDelayMs = 16;

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Window visibility is coordinated by window_manager after the first frame.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  HWND hwnd = GetHandle();
  if (hwnd != nullptr) {
    KillTimer(hwnd, kInitialSurfaceNudgeTimerId);
    KillTimer(hwnd, kInitialSurfaceRestoreTimerId);
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_SHOWWINDOW && wparam != 0 &&
      !initial_surface_nudge_scheduled_ && flutter_controller_) {
    initial_surface_nudge_scheduled_ = true;
    flutter_controller_->ForceRedraw();
    SetTimer(hwnd, kInitialSurfaceNudgeTimerId, kInitialSurfaceNudgeDelayMs,
             nullptr);
  } else if (message == WM_TIMER && wparam == kInitialSurfaceNudgeTimerId) {
    KillTimer(hwnd, kInitialSurfaceNudgeTimerId);
    if (flutter_controller_ && !IsIconic(hwnd) && IsWindowVisible(hwnd)) {
      HWND child = GetChildContent();
      RECT rect = GetClientArea();
      const int width = static_cast<int>(rect.right - rect.left);
      const int height = static_cast<int>(rect.bottom - rect.top);
      if (child != nullptr && width > 2 && height > 2) {
        MoveWindow(child, static_cast<int>(rect.left),
                   static_cast<int>(rect.top), width - 1, height, TRUE);
        flutter_controller_->ForceRedraw();
        SetTimer(hwnd, kInitialSurfaceRestoreTimerId,
                 kInitialSurfaceRestoreDelayMs, nullptr);
      }
    }
    return 0;
  } else if (message == WM_TIMER && wparam == kInitialSurfaceRestoreTimerId) {
    KillTimer(hwnd, kInitialSurfaceRestoreTimerId);
    if (flutter_controller_ && !IsIconic(hwnd)) {
      HWND child = GetChildContent();
      RECT rect = GetClientArea();
      const int width = static_cast<int>(rect.right - rect.left);
      const int height = static_cast<int>(rect.bottom - rect.top);
      if (child != nullptr && width > 0 && height > 0) {
        MoveWindow(child, static_cast<int>(rect.left),
                   static_cast<int>(rect.top), width, height, TRUE);
        flutter_controller_->ForceRedraw();
      }
    }
    return 0;
  }

  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
