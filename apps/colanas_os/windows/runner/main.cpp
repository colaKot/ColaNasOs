#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// 单实例判据用命名互斥量：句柄归内核对象管理，进程正常退出/被强杀都会自动释放，
// 不会出现「进程已经死了，锁还留着，再也打不开」的情况。
constexpr const wchar_t kInstanceMutex[] = L"Local\\ColaNasOsClient.SingleInstance";
// Flutter Windows 嵌入层注册的窗口类（见 win32_window.cpp），第二个实例据此找主窗口。
constexpr const wchar_t kMainWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

/// 把已在运行的窗口唤到前台：还原最小化 → 置前 → 任务栏闪烁兜底。
///
/// Windows 会拒绝后台进程直接抢焦点，所以先临时 AttachThreadInput 到目标窗口线程，
/// 置前后再解除；即使系统仍不给焦点，FlashWindowEx 也会让任务栏图标闪烁提示用户。
void ActivateRunningInstance() {
  HWND window = nullptr;
  // 第一次启动可能还在建窗口：短暂重试，避免「第二次启动毫无反应」。
  for (int i = 0; i < 20 && window == nullptr; ++i) {
    window = ::FindWindowW(kMainWindowClass, nullptr);
    if (window == nullptr) ::Sleep(100);
  }
  if (window == nullptr) return;

  if (::IsIconic(window)) ::ShowWindow(window, SW_RESTORE);

  const DWORD target_thread = ::GetWindowThreadProcessId(window, nullptr);
  const DWORD self_thread = ::GetCurrentThreadId();
  const bool attached = target_thread != 0 && target_thread != self_thread &&
                        ::AttachThreadInput(self_thread, target_thread, TRUE);
  ::SetForegroundWindow(window);
  ::BringWindowToTop(window);
  if (attached) ::AttachThreadInput(self_thread, target_thread, FALSE);

  FLASHWINFO flash{sizeof(flash), window, FLASHW_ALL | FLASHW_TIMERNOFG, 0, 0};
  ::FlashWindowEx(&flash);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // 同一台机器只允许一个客户端窗口：双击快捷方式、开始菜单、命令行最终都是这个进程，
  // 所以在这里统一拦截，第二个实例不开窗口，只把已有窗口唤到前台。
  // 互斥量创建失败时按单实例放行 —— 不能因为拿不到锁就让用户打不开软件。
  HANDLE instance_mutex = ::CreateMutexW(nullptr, TRUE, kInstanceMutex);
  if (instance_mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    ActivateRunningInstance();
    ::CloseHandle(instance_mutex);
    return EXIT_SUCCESS;
  }

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"ColaNasOs 客户端", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
