// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/models/ab_model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/models/platform_model.dart';
import 'fake_rustdesk_bridge.dart';
import 'mock_window_controller.dart';
import 'test_data_fixtures.dart';

/// Central fixture builder and runner for Camellia Remote desktop E2E tests.
class TestAppHarness {
  TestAppHarness._();

  static late FakeRustdeskBridge fakeBridge;
  static late MockWindowController windowController;
  static final ValueNotifier<ThemeMode> themeModeNotifier =
      ValueNotifier<ThemeMode>(ThemeMode.light);

  /// Initializes the mock environment before running widget tests.
  static Future<void> setUp({
    Size surfaceSize = const Size(1024, 720),
    String initialServerId = '888 999 111',
    String initialPassword = 'TestPassword123',
    String initialFingerprint = 'SHA256:abcd1234ef567890',
    String? themeStyle,
  }) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    isTest = true;
    Get.reset();

    // 1. Mock window_manager MethodChannel
    MockWindowController.installMethodChannelHandler();
    windowController = MockWindowController();

    // 2. Put required Get services for desktop connection page & status
    Get.put<RxBool>(false.obs, tag: 'stop-service');

    // 3. Mock Rust FFI Bridge with in-memory storage
    fakeBridge = FakeRustdeskBridge(
      serverId: initialServerId,
      password: initialPassword,
      fingerprint: initialFingerprint,
    );
    if (themeStyle != null) {
      fakeBridge.localOptions['theme_style'] = themeStyle;
    }
    platformFFI.ffiBind = fakeBridge;

    // 4. Register auxiliary desktop platform method channels
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/url_launcher'),
          (call) async => true,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('screen_retriever'),
          (call) async {
            if (call.method == 'getCursorScreenPoint') {
              return {'x': 0.0, 'y': 0.0};
            }
            return null;
          },
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('desktop_drop'),
          (call) async => null,
        );

    // 5. Initialize Global FFI models without background pollers
    await initGlobalFFI();
    await gFFI.serverModel.fetchID();
    gFFI.serverModel.serverPasswd.text = initialPassword;

    // 6. Seed test fixtures (peers, address book entries)
    TestDataFixtures.seedDefaultFixtures(gFFI);

    // 7. Synchronous visibility updates to prevent async timers
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  }

  /// Tears down and cleans up resources after test completion.
  static Future<void> tearDown(WidgetTester tester) async {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    await tester.binding.setSurfaceSize(null);
    // Unmount any active widget tree to trigger disposal of looping timers
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
    if (!gFFI.closed) {
      await gFFI.close();
    }
    Get.reset();
    MockWindowController.uninstallMethodChannelHandler();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/url_launcher'),
          null,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('screen_retriever'),
          null,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('desktop_drop'),
          null,
        );
    themeModeNotifier.value = ThemeMode.light;
  }

  /// Pumps a widget wrapped in standard Camellia MaterialApp with providers.
  static Future<void> pumpWidget(
    WidgetTester tester, {
    required Widget child,
    Size surfaceSize = const Size(1280, 800),
    ThemeMode themeMode = ThemeMode.light,
    String? themeStyle,
  }) async {
    tester.view.physicalSize = surfaceSize;
    tester.view.devicePixelRatio = 1.0;
    await tester.binding.setSurfaceSize(surfaceSize);
    themeModeNotifier.value = themeMode;

    if (themeStyle != null) {
      fakeBridge.localOptions['theme_style'] = themeStyle;
    }

    final currentStyle = fakeBridge.localOptions['theme_style'] ?? '';
    final isMidnight =
        currentStyle == 'midnight' || currentStyle == 'obsidianCyber';

    await tester.pumpWidget(
      ValueListenableBuilder<ThemeMode>(
        valueListenable: themeModeNotifier,
        builder: (context, activeMode, _) {
          return MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: gFFI.serverModel),
              Provider<AbModel>.value(value: gFFI.abModel),
              ChangeNotifierProvider.value(value: gFFI.peerTabModel),
            ],
            child: MaterialApp(
              navigatorKey: globalKey,
              theme: CamelliaTheme.build(
                brightness: Brightness.light,
                desktopDensity: true,
                extensions: [
                  ColorThemeExtension.light,
                  AppDesignTokens.light,
                ],
              ),
              darkTheme: CamelliaTheme.build(
                brightness: Brightness.dark,
                desktopDensity: true,
                oledMidnight: isMidnight,
                extensions: [
                  ColorThemeExtension.dark,
                  AppDesignTokens.dark,
                ],
              ),
              themeMode: activeMode,
              home: Scaffold(body: child),
            ),
          );
        },
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }
}
