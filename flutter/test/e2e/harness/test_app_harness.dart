import 'package:flutter/material.dart';
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
    platformFFI.ffiBind = fakeBridge;

    // 4. Initialize Global FFI models without background pollers
    await initGlobalFFI();
    await gFFI.serverModel.fetchID();
    gFFI.serverModel.serverPasswd.text = initialPassword;

    // 5. Seed test fixtures (peers, address book entries)
    TestDataFixtures.seedDefaultFixtures(gFFI);

    // 6. Synchronous visibility updates to prevent async timers
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  }

  /// Tears down and cleans up resources after test completion.
  static Future<void> tearDown(WidgetTester tester) async {
    // Unmount any active widget tree to trigger disposal of looping timers
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    await tester.binding.setSurfaceSize(null);
    if (!gFFI.closed) {
      await gFFI.close();
    }
    Get.reset();
    MockWindowController.uninstallMethodChannelHandler();
    themeModeNotifier.value = ThemeMode.light;
  }

  /// Pumps a widget wrapped in standard Camellia MaterialApp with providers.
  static Future<void> pumpWidget(
    WidgetTester tester, {
    required Widget child,
    Size surfaceSize = const Size(1280, 800),
    ThemeMode themeMode = ThemeMode.light,
  }) async {
    tester.view.physicalSize = surfaceSize;
    tester.view.devicePixelRatio = 1.0;
    await tester.binding.setSurfaceSize(surfaceSize);
    themeModeNotifier.value = themeMode;

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
              ).copyWith(
                extensions: [
                  ColorThemeExtension.light,
                  AppDesignTokens.light,
                ],
              ),
              darkTheme: CamelliaTheme.build(
                brightness: Brightness.dark,
                desktopDensity: true,
              ).copyWith(
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
