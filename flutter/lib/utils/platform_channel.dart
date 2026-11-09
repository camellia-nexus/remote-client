import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:camellia_remote_app/main.dart';
import 'package:camellia_remote_app/common.dart';

enum SystemWindowTheme { light, dark }

/// The platform channel for RustDesk.
class RdPlatformChannel {
  RdPlatformChannel._();

  static final RdPlatformChannel _windowUtil = RdPlatformChannel._();

  static RdPlatformChannel get instance => _windowUtil;

  final MethodChannel _hostMethodChannel =
      MethodChannel("com.camellia.remote/host");

  /// Bump the position of the mouse cursor, if applicable
  Future<bool> bumpMouse({required int dx, required int dy}) async {
    // No debug output; this call is too chatty.

    bool? result = await _hostMethodChannel
      .invokeMethod("bumpMouse", {"dx": dx, "dy": dy});

    return result ?? false;
  }

  /// Change the theme of the system window
  Future<void> changeSystemWindowTheme(SystemWindowTheme theme) {
    assert(isMacOS);
    if (kDebugMode) {
      print(
          "[Window ${kWindowId ?? 'Main'}] change system window theme to ${theme.name}");
    }
    return _hostMethodChannel
        .invokeMethod("setWindowTheme", {"themeName": theme.name});
  }

  /// Terminate .app manually.
  Future<void> terminate() {
    assert(isMacOS);
    return _hostMethodChannel.invokeMethod("terminate");
  }

  /// Request or release Wayland keyboard shortcuts inhibition.
  /// Only RemoteDesktop control windows should request this when capturing keyboard.
  Future<bool> setWaylandShortcutsInhibit({required bool enabled}) async {
    if (!isLinux) return false;
    try {
      final res = await _hostMethodChannel.invokeMethod<dynamic>(
        "setWaylandShortcutsInhibit",
        {"enabled": enabled},
      );
      if (res is Map && res["success"] == true) {
        return true;
      }
      return res == true;
    } catch (e) {
      debugPrint("setWaylandShortcutsInhibit failed: $e");
      return false;
    }
  }

  /// Query the current Wayland shortcuts inhibitor state.
  Future<String?> getWaylandShortcutsInhibitState() async {
    if (!isLinux) return null;
    try {
      final res = await _hostMethodChannel.invokeMethod<dynamic>(
        "getWaylandShortcutsInhibitState",
      );
      if (res is Map) {
        return res["state"]?.toString();
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
