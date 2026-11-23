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

  static int _channelCloseCount = 0;
  static int _channelHideCount = 0;
  static int _channelDestroyCount = 0;
  static bool _channelPreventClose = false;

  int get channelCloseCount => _channelCloseCount;
  int get closeCallCount => closeCount > 0 ? closeCount : _channelCloseCount;
  int get hideCallCount => _channelHideCount;
  int get destroyCallCount => _channelDestroyCount;
  bool get preventCloseState => _channelPreventClose;

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
    _channelCloseCount = 0;
    _channelHideCount = 0;
    _channelDestroyCount = 0;
    _channelPreventClose = false;
  }

  /// Synthesizes native WindowListener events into the Flutter framework
  /// so that classes implementing `WindowListener` (like DesktopHomePage)
  /// receive callbacks.
  static Future<void> simulateWindowEvent(String eventName) async {
    final message = const StandardMethodCodec().encodeMethodCall(
      MethodCall('onEvent', {'eventName': eventName}),
    );
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage('window_manager', message, (data) {});
  }

  static Future<void> simulateWindowClose() => simulateWindowEvent('close');
  static Future<void> simulateWindowFocus() => simulateWindowEvent('focus');
  static Future<void> simulateWindowBlur() => simulateWindowEvent('blur');

  /// Installs mock method call handler on 'window_manager' channel.
  static void installMethodChannelHandler() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), (
          MethodCall call,
        ) async {
          switch (call.method) {
            case 'close':
              _channelCloseCount++;
              return true;
            case 'hide':
              _channelHideCount++;
              return true;
            case 'destroy':
              _channelDestroyCount++;
              return true;
            case 'setPreventClose':
              _channelPreventClose =
                  (call.arguments as Map?)?['isPreventClose'] as bool? ?? false;
              return true;
            case 'isPreventClose':
              return _channelPreventClose;
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
