import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/desktop/widgets/titlebar_widget.dart';

/// Test implementation of [DesktopWindowController] and manager for the
/// `window_manager` method channel stub.
class MockWindowController implements DesktopWindowController {
  bool maximized = false;
  bool minimized = false;
  bool closed = false;

  int minimizeCount = 0;
  int maximizeCount = 0;
  int unmaximizeCount = 0;
  int closeCount = 0;
  int dragCount = 0;
  int menuCount = 0;

  @override
  Future<void> minimize() async {
    minimized = true;
    minimizeCount++;
  }

  @override
  Future<void> maximize() async {
    maximized = true;
    maximizeCount++;
  }

  @override
  Future<void> unmaximize() async {
    maximized = false;
    unmaximizeCount++;
  }

  @override
  Future<void> close() async {
    closed = true;
    closeCount++;
  }

  @override
  Future<bool> isMaximized() async => maximized;

  @override
  Future<void> startDragging() async {
    dragCount++;
  }

  @override
  Future<void> showSystemMenu() async {
    menuCount++;
  }

  void reset() {
    maximized = false;
    minimized = false;
    closed = false;
    minimizeCount = 0;
    maximizeCount = 0;
    unmaximizeCount = 0;
    closeCount = 0;
    dragCount = 0;
    menuCount = 0;
  }

  /// Installs mock method call handler on 'window_manager' channel.
  static void installMethodChannelHandler() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), (
          MethodCall call,
        ) async {
          switch (call.method) {
            case 'isMaximized':
              return false;
            case 'isMinimized':
              return false;
            case 'isFullScreen':
              return false;
            case 'isVisible':
              return true;
            case 'isFocused':
              return true;
            case 'isPreventClose':
              return false;
            default:
              return true;
          }
        });
  }

  /// Uninstalls mock method call handler on 'window_manager' channel.
  static void uninstallMethodChannelHandler() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
  }
}
