#include "include/uni_links_desktop/uni_links_desktop_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>

#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <codecvt>
#include <map>
#include <memory>
#include <sstream>

namespace {

class UniLinksDesktopPlugin : public flutter::Plugin,
                              flutter::StreamHandler<flutter::EncodableValue> {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  UniLinksDesktopPlugin(
      flutter::PluginRegistrarWindows* registrar,
      std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel,
      std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> eventChannel);

  flutter::MethodChannel<flutter::EncodableValue>* channel() const {
    return channel_.get();
  }

  flutter::EventChannel<flutter::EncodableValue>* eventChannel() const {
    return eventChannel_.get();
  }

  std::string UniLinksDesktopPlugin::GetInitialLink();

  virtual ~UniLinksDesktopPlugin();

 private:
  flutter::PluginRegistrarWindows* registrar_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_ =
      nullptr;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> eventChannel_ =
      nullptr;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink_;

  int32_t window_proc_id_ = -1;

  std::optional<LRESULT> HandleWindowProc(HWND hwnd,
                                          UINT message,
                                          WPARAM wparam,
                                          LPARAM lparam);

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::StreamHandlerError<>> OnListenInternal(
      const flutter::EncodableValue* arguments,
      std::unique_ptr<flutter::EventSink<>>&& events) override;
  std::unique_ptr<flutter::StreamHandlerError<>> OnCancelInternal(
      const flutter::EncodableValue* arguments) override;
};

// static
void UniLinksDesktopPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<UniLinksDesktopPlugin>(
      registrar,
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "uni_links/messages",
          &flutter::StandardMethodCodec::GetInstance()),
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          registrar->messenger(), "uni_links/events",
          &flutter::StandardMethodCodec::GetInstance()));
  plugin->channel()->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto& call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  auto atreamHandler = std::make_unique<flutter::StreamHandlerFunctions<>>(
      [plugin_pointer = plugin.get()](
          const flutter::EncodableValue* arguments,
          std::unique_ptr<flutter::EventSink<>>&& events)
          -> std::unique_ptr<flutter::StreamHandlerError<>> {
        return plugin_pointer->OnListen(arguments, std::move(events));
      },
      [plugin_pointer = plugin.get()](const flutter::EncodableValue* arguments)
          -> std::unique_ptr<flutter::StreamHandlerError<>> {
        return plugin_pointer->OnCancel(arguments);
      });

  plugin->eventChannel()->SetStreamHandler(std::move(atreamHandler));

  registrar->AddPlugin(std::move(plugin));
}

UniLinksDesktopPlugin::UniLinksDesktopPlugin(
    flutter::PluginRegistrarWindows* registrar,
    std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel,
    std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> eventChannel)
    : registrar_(registrar), channel_(std::move(channel)), eventChannel_(std::move(eventChannel)) {
  window_proc_id_ = registrar->RegisterTopLevelWindowProcDelegate(
      [this](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
        return HandleWindowProc(hwnd, message, wparam, lparam);
      });
}

UniLinksDesktopPlugin::~UniLinksDesktopPlugin() {
  registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_id_);
}

std::optional<LRESULT> UniLinksDesktopPlugin::HandleWindowProc(HWND hwnd,
                                                               UINT message,
                                                               WPARAM wparam,
                                                               LPARAM lparam) {
  switch (message) {
    case WM_COPYDATA: {
      if (lparam == 0) {
        return std::nullopt;
      }
      auto* cds = reinterpret_cast<COPYDATASTRUCT*>(lparam);
      if (cds == nullptr || cds->dwData != UNI_LINKS_DESKTOP_MSG_ID) {
        return std::nullopt;
      }
      if (cds->lpData == nullptr || cds->cbData == 0 ||
          cds->cbData > UNI_LINKS_MAX_URL_LENGTH) {
        return 0;
      }
      const char* raw_data = reinterpret_cast<const char*>(cds->lpData);
      size_t str_len = 0;
      while (str_len < cds->cbData && raw_data[str_len] != '\0') {
        str_len++;
      }
      if (str_len == 0 || str_len > UNI_LINKS_MAX_URL_LENGTH) {
        return 0;
      }
      std::string url(raw_data, str_len);
      // Validate UTF-8 encoding
      int wide_len = ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                           url.data(), static_cast<int>(url.length()),
                                           nullptr, 0);
      if (wide_len <= 0) {
        return 0;
      }
      // Reject raw ASCII control characters
      for (char c : url) {
        if (static_cast<unsigned char>(c) < 0x20 && c != '\t' && c != '\r' && c != '\n') {
          return 0;
        }
      }
      if (event_sink_) {
        event_sink_->Success(flutter::EncodableValue(url));
      }
      return UNI_LINKS_DESKTOP_ACK;
    }
  }
  return std::nullopt;
}

std::string UniLinksDesktopPlugin::GetInitialLink() {
  int argc;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr || argc < 2) {
    return "";
  }

  std::wstring_convert<std::codecvt_utf8_utf16<wchar_t>> converter;
  std::string url = converter.to_bytes(argv[1]);
  ::LocalFree(argv);
  return url;
}

void UniLinksDesktopPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (method_call.method_name().compare("getInitialLink") == 0) {
    std::string value = GetInitialLink();
    result->Success(flutter::EncodableValue(value.c_str()));
  } else {
    result->NotImplemented();
  }
}

std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
UniLinksDesktopPlugin::OnListenInternal(
    const flutter::EncodableValue* arguments,
    std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events) {
  event_sink_ = std::move(events);
  return nullptr;
}

std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
UniLinksDesktopPlugin::OnCancelInternal(
    const flutter::EncodableValue* arguments) {
  event_sink_ = nullptr;
  return nullptr;
}

}  // namespace

void UniLinksDesktopPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  UniLinksDesktopPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}

bool DispatchToUniLinksDesktop(HWND hwnd) {
  if (hwnd == nullptr || !::IsWindow(hwnd) || ::IsHungAppWindow(hwnd)) {
    return false;
  }
  int argc;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr || argc < 2) {
    return false;
  }

  std::string url;
  for (int i = 1; i < argc; ++i) {
    if (argv[i] != nullptr && wcslen(argv[i]) > 0) {
      int target_length = ::WideCharToMultiByte(
          CP_UTF8, WC_ERR_INVALID_CHARS, argv[i], -1, nullptr, 0, nullptr, nullptr);
      if (target_length > 1) {
        std::string candidate(target_length - 1, '\0');
        ::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, argv[i], -1,
                              candidate.data(), target_length, nullptr, nullptr);
        if (candidate.rfind("camellia://", 0) == 0 ||
            candidate.rfind("rustdesk://", 0) == 0 ||
            candidate.find("://") != std::string::npos) {
          url = candidate;
          break;
        }
        if (url.empty()) url = candidate;
      }
    }
  }
  ::LocalFree(argv);
  if (url.empty() || url.length() > UNI_LINKS_MAX_URL_LENGTH) {
    return false;
  }

  COPYDATASTRUCT cds = {0};
  cds.dwData = UNI_LINKS_DESKTOP_MSG_ID;
  cds.cbData = (DWORD)(strlen(url.c_str()) + 1);
  cds.lpData = (PVOID)url.c_str();

  DWORD_PTR result = 0;
  LRESULT send_ok = ::SendMessageTimeoutW(
      hwnd, WM_COPYDATA, 0, (LPARAM)&cds,
      SMTO_ABORTIFHUNG | SMTO_BLOCK, 3000, &result);
  if (send_ok == 0) {
    return false;
  }
  return (result == UNI_LINKS_DESKTOP_ACK || result == 1);
}
