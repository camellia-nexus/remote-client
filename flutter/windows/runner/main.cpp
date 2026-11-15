#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <tchar.h>
#include <uni_links_desktop/uni_links_desktop_plugin.h>
#include <windows.h>

#include <algorithm>
#include <iostream>

#include "win32_desktop.h"
#include "flutter_window.h"
#include "utils.h"

typedef char** (*FUNC_RUSTDESK_CORE_MAIN)(int*);
typedef void (*FUNC_RUSTDESK_FREE_ARGS)( char**, int);
typedef int (*FUNC_RUSTDESK_GET_APP_NAME)(wchar_t*, int);
typedef int (*FUNC_RUSTDESK_IS_DISABLE_INSTALLATION)();
/// Note: `--server`, `--service` are already handled in [core_main.rs].
const std::vector<std::string> parameters_white_list = {"--install", "--cm"};

const wchar_t* getWindowClassName();

class ScopedComInitializer {
 public:
  ScopedComInitializer() {
    hr_ = ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  }
  ~ScopedComInitializer() {
    if (hr_ == S_OK || hr_ == S_FALSE) {
      ::CoUninitialize();
    }
  }
  bool Succeeded() const {
    return SUCCEEDED(hr_) || hr_ == RPC_E_CHANGED_MODE;
  }
  HRESULT hr() const { return hr_; }
 private:
  HRESULT hr_;
};

static bool IsTrustedTargetWindow(HWND hwnd) {
  if (!::IsWindow(hwnd) || ::IsHungAppWindow(hwnd)) {
    return false;
  }
  DWORD target_pid = 0;
  ::GetWindowThreadProcessId(hwnd, &target_pid);
  if (target_pid == 0 || target_pid == ::GetCurrentProcessId()) {
    return false;
  }
  HANDLE hProc = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, target_pid);
  if (!hProc) return false;
  wchar_t target_exe[MAX_PATH] = {0}, current_exe[MAX_PATH] = {0};
  DWORD len = MAX_PATH;
  bool match = false;
  if (::QueryFullProcessImageNameW(hProc, 0, target_exe, &len) &&
      ::GetModuleFileNameW(nullptr, current_exe, MAX_PATH)) {
    match = (_wcsicmp(target_exe, current_exe) == 0);
  }
  ::CloseHandle(hProc);
  return match;
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command)
{
  HINSTANCE hInstance = LoadLibraryA("camellia_remote.dll");
  if (!hInstance)
  {
    std::cout << "Failed to load camellia_remote.dll." << std::endl;
    return EXIT_FAILURE;
  }
  FUNC_RUSTDESK_CORE_MAIN camellia_remote_core_main =
      (FUNC_RUSTDESK_CORE_MAIN)GetProcAddress(hInstance, "camellia_remote_core_main_args");
  if (!camellia_remote_core_main)
  {
    std::cout << "Failed to get camellia_remote_core_main." << std::endl;
    return EXIT_FAILURE;
  }
  FUNC_RUSTDESK_FREE_ARGS free_c_args =
      (FUNC_RUSTDESK_FREE_ARGS)GetProcAddress(hInstance, "free_c_args");
  if (!free_c_args)
  {
    std::cout << "Failed to get free_c_args." << std::endl;
    return EXIT_FAILURE;
  }
  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  int args_len = 0;
  char** c_args = camellia_remote_core_main(&args_len);
  if (!c_args || args_len < 0)
  {
    std::string args_str = "";
    for (const auto& argument : command_line_arguments) {
      args_str += (argument + " ");
    }
    // std::cout << "RustDesk [" << args_str << "], core returns false, exiting without launching Flutter app." << std::endl;
    return EXIT_SUCCESS;
  }
  std::vector<std::string> rust_args;
  rust_args.reserve(args_len);
  for (int i = 0; i < args_len; ++i) {
    if (c_args[i] != nullptr) {
      rust_args.emplace_back(c_args[i]);
    }
  }
  free_c_args(c_args, args_len);
  FUNC_RUSTDESK_IS_DISABLE_INSTALLATION rustdesk_is_disable_installation =
      (FUNC_RUSTDESK_IS_DISABLE_INSTALLATION)GetProcAddress(hInstance, "rustdesk_is_disable_installation");
  bool is_disable_installation =
      rustdesk_is_disable_installation && rustdesk_is_disable_installation() != 0;
  const auto installParam = std::string("--install");
  // Flutter reads the original process command line, not only rust_args, so
  // remove the `--install` injected by the portable wrapper here as well. This
  // also lets `no-install.exe` continue as a portable app when installation is
  // disabled. See: https://github.com/rustdesk/rustdesk-server-pro/issues/991#issuecomment-4978376890
  if (is_disable_installation) {
    command_line_arguments.erase(
        std::remove(command_line_arguments.begin(),
                    command_line_arguments.end(),
                    installParam),
        command_line_arguments.end());
  }

  std::wstring app_name = L"Camellia Remote";
  FUNC_RUSTDESK_GET_APP_NAME get_rustdesk_app_name = (FUNC_RUSTDESK_GET_APP_NAME)GetProcAddress(hInstance, "get_rustdesk_app_name");
  if (get_rustdesk_app_name) {
    wchar_t app_name_buffer[512] = {0};
    if (get_rustdesk_app_name(app_name_buffer, 512) == 0) {
      app_name = std::wstring(app_name_buffer);
    }
  }

  // Uri links dispatch
  HWND hwnd = ::FindWindowW(getWindowClassName(), app_name.c_str());
  if (hwnd != NULL && IsTrustedTargetWindow(hwnd)) {
    // Allow multiple flutter instances when being executed by parameters
    // contained in whitelists.
    bool allow_multiple_instances = false;
    for (auto& whitelist_param : parameters_white_list) {
      allow_multiple_instances =
          allow_multiple_instances ||
          std::find(command_line_arguments.begin(),
                    command_line_arguments.end(),
                    whitelist_param) != command_line_arguments.end();
    }
    if (!allow_multiple_instances) {
      if (!command_line_arguments.empty()) {
        bool dispatched = DispatchToUniLinksDesktop(hwnd);
        ::ShowWindow(hwnd, SW_NORMAL);
        ::SetForegroundWindow(hwnd);
        return dispatched ? EXIT_SUCCESS : EXIT_FAILURE;
      } else {
        ::ShowWindow(hwnd, SW_NORMAL);
        ::SetForegroundWindow(hwnd);
        return EXIT_SUCCESS;
      }
    }
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent())
  {
    CreateAndAttachConsole();
  }

  ScopedComInitializer com_initializer;
  if (!com_initializer.Succeeded()) {
    std::cerr << "Failed to initialize COM library: 0x" << std::hex
              << com_initializer.hr() << std::endl;
    return EXIT_FAILURE;
  }

  flutter::DartProject project(L"data");
  // connection manager hide icon from taskbar
  bool is_cm_page = false;
  const auto cmParam = std::string("--cm");
  if (!command_line_arguments.empty() && command_line_arguments.front() == cmParam) {
    is_cm_page = true;
  }
  bool is_install_page = false;
  if (!command_line_arguments.empty() && command_line_arguments.front() == installParam) {
    is_install_page = true;
  }

  command_line_arguments.insert(command_line_arguments.end(), rust_args.begin(), rust_args.end());
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);

  // Get primary monitor's work area.
  Win32Window::Point workarea_origin(0, 0);
  Win32Window::Size workarea_size(0, 0);

  Win32Desktop::GetWorkArea(workarea_origin, workarea_size);

  // Compute window bounds for default main window position: (10, 10) x(800, 600)
  Win32Window::Point relative_origin(10, 10);

  Win32Window::Point origin(workarea_origin.x + relative_origin.x, workarea_origin.y + relative_origin.y);
  Win32Window::Size size(800u, 600u);

  // Fit the window to the monitor's work area.
  Win32Desktop::FitToWorkArea(origin, size);

  std::wstring window_title;
  if (is_cm_page) {
    window_title = app_name + L" - Connection Manager";
  } else if (is_install_page) {
    window_title = app_name + L" - Install";
  } else {
    window_title = app_name;
  }
  if (!window.CreateAndShow(window_title, origin, size, !is_cm_page)) {
      return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  BOOL bRet;
  while ((bRet = ::GetMessage(&msg, nullptr, 0, 0)) != 0)
  {
    if (bRet == -1) {
      std::cerr << "GetMessage error: " << ::GetLastError() << std::endl;
      return EXIT_FAILURE;
    }
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  return static_cast<int>(msg.wParam);
}
