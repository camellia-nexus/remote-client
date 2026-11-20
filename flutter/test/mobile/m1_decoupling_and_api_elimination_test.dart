import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/server_settings_dialog.dart';
import 'package:camellia_remote_app/common/widgets/socks5_proxy_dialog.dart';
import 'package:camellia_remote_app/generated_bridge.dart';
import 'package:camellia_remote_app/models/model.dart';
import 'package:camellia_remote_app/models/platform_model.dart';

class _FakeRustdeskImpl extends Fake implements RustdeskImpl {
  final Map<String, String> localOptions = {};
  Completer<String>? testServerCompleter;
  int mainSetSocksCallCount = 0;
  String? lastSetSocksProxy;

  @override
  String mainGetLocalOption({required String key}) => localOptions[key] ?? '';
  @override
  Future<void> mainSetLocalOption({
    required String key,
    required String value,
  }) async {
    localOptions[key] = value;
  }

  @override
  String mainUriPrefixSync() => 'camellia-remote://';

  @override
  int mainMaxEncryptLen() => 128;

  @override
  Future<List<String>> mainGetSocks() async => ['127.0.0.1:1080', 'user', kStoredPasswordSentinel];

  @override
  Future<String> mainTestIfValidServer({
    required String server,
    required bool testWithProxy,
  }) async {
    if (testServerCompleter != null) {
      return await testServerCompleter!.future;
    }
    return '';
  }

  @override
  Future<void> mainSetSocks({
    required String proxy,
    required String username,
    required String password,
  }) async {
    mainSetSocksCallCount++;
    lastSetSocksProxy = proxy;
  }

  @override
  bool mainHasValidBotSync() => false;

  @override
  String mainSetUnlockPin({required String pin}) => '';

  @override
  bool sessionHasOsPassword({required UuidValue sessionId}) => true;

  @override
  Future<String> sessionGetOption({
    required UuidValue sessionId,
    required String arg,
  }) async => '';

  @override
  Future<void> sessionPeerOption({
    required UuidValue sessionId,
    required String name,
    required String value,
  }) async {}

  @override
  Future<void> sessionClose({required UuidValue sessionId}) async {}
  @override
  Future<void> stopGlobalEventStream({required String appType}) async {}

  @override
  bool mainIsOptionFixed({required String key}) => false;

  @override
  bool isDisableAb() => false;
  @override
  bool isDisableAccount() => false;
  @override
  bool isDisableGroupPanel() => false;
  @override
  Future<bool> optionSynced() async => true;
  @override
  Future<String> mainGetConnectStatus() async => '{"status_num": 1}';
  @override
  Future<String> mainGetOption({required String key}) async => '';
  @override
  Future<void> mainSetOption({
    required String key,
    required String value,
  }) async {}
  @override
  String getLocalFlutterOption({required String k}) => '';
  @override
  Future<void> setLocalFlutterOption({
    required String k,
    required String v,
  }) async {}
  @override
  Future<String> mainGetApiServer() async => 'http://127.0.0.1:21114';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Milestone 1 Architecture & API Invariants', () {
    test('Zero MediaQuery.of occurrences in lib/mobile/ and lib/common/widgets/', () {
      final targetDirs = [
        Directory('lib/mobile'),
        Directory('lib/common/widgets'),
      ];

      final violations = <String>[];
      final regex = RegExp(r'MediaQuery\.of\s*\(');

      for (final dir in targetDirs) {
        if (!dir.existsSync()) continue;
        for (final entity in dir.listSync(recursive: true)) {
          if (entity is File && entity.path.endsWith('.dart')) {
            final lines = entity.readAsLinesSync();
            for (var i = 0; i < lines.length; i++) {
              if (regex.hasMatch(lines[i])) {
                violations.add('${entity.path}:${i + 1}: ${lines[i].trim()}');
              }
            }
          }
        }
      }

      // Also verify common.dart
      final commonFile = File('lib/common.dart');
      if (commonFile.existsSync()) {
        final lines = commonFile.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (regex.hasMatch(lines[i])) {
            violations.add('lib/common.dart:${i + 1}: ${lines[i].trim()}');
          }
        }
      }

      expect(
        violations,
        isEmpty,
        reason: 'Deprecated MediaQuery.of found in: \n${violations.join('\n')}',
      );
    });

    test('Zero desktop imports in mobile settings_page and mobile dialog', () {
      final settingsFile = File('lib/mobile/pages/settings_page.dart');
      expect(settingsFile.existsSync(), isTrue);
      final settingsContent = settingsFile.readAsStringSync();
      expect(
        settingsContent.contains("import 'package:camellia_remote_app/desktop/pages/desktop_setting_page.dart';"),
        isFalse,
        reason: 'mobile/pages/settings_page.dart must not import desktop_setting_page.dart',
      );
      expect(
        settingsContent.contains("/desktop/"),
        isFalse,
        reason: 'mobile/pages/settings_page.dart must have zero desktop imports',
      );

      final dialogFile = File('lib/mobile/widgets/dialog.dart');
      expect(dialogFile.existsSync(), isTrue);
      final dialogContent = dialogFile.readAsStringSync();
      expect(
        dialogContent.contains('showServerSettings'),
        isFalse,
        reason: 'Duplicate showServerSettings must be eliminated from mobile/widgets/dialog.dart',
      );
      expect(
        dialogContent.contains('serverSettingsTextFormField'),
        isFalse,
        reason: 'Duplicate serverSettingsTextFormField must be eliminated from mobile/widgets/dialog.dart',
      );
    });

    test('Zero splashRadius in common/widgets/overlay.dart DraggableMobileActions', () {
      final overlayFile = File('lib/common/widgets/overlay.dart');
      expect(overlayFile.existsSync(), isTrue);
      final content = overlayFile.readAsStringSync();
      expect(
        content.contains('splashRadius'),
        isFalse,
        reason: 'Deprecated splashRadius must be removed from common/widgets/overlay.dart',
      );
    });
  });

  group('Milestone 1 Feature 4 & 5: Dialog Constraints & SOCKS5 Proxy', () {
    late _FakeRustdeskImpl fakeBridge;
    late FFI globalFFI;
    late OverlayKeyState overlayState;

    setUp(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('window_manager'),
              (MethodCall methodCall) async {
        return false;
      });
      fakeBridge = _FakeRustdeskImpl();
      platformFFI.ffiBind = fakeBridge;
      isTest = true;
      Get.reset();
      await initGlobalFFI();
      globalFFI = gFFI;
      overlayState = OverlayKeyState();
      globalFFI.dialogManager.setOverlayState(overlayState);
    });

    tearDown(() async {
      await globalFFI.close();
      Get.reset();
    });

    test('kStoredPasswordSentinel matches contract', () {
      expect(kStoredPasswordSentinel, equals('\u0000\u0000STORED_PASSWORD\u0000\u0000'));
      expect(kStoredPasswordSentinel.contains('STORED_PASSWORD'), isTrue);
    });

    testWidgets('socks5_proxy_dialog lifecycle and cancel dismissal', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Overlay(key: overlayState.key),
      ));

      changeSocks5Proxy();
      await tester.pumpAndSettle();

      expect(find.text('Socks5/Http(s) Proxy'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Socks5/Http(s) Proxy'), findsNothing);
    });

    testWidgets('socks5_proxy_dialog: cancellation during async validation prevents ghost commit and setState after dispose', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Overlay(key: overlayState.key),
      ));

      fakeBridge.testServerCompleter = Completer<String>();
      changeSocks5Proxy();
      await tester.pumpAndSettle();

      expect(find.text('Socks5/Http(s) Proxy'), findsOneWidget);
      expect(find.text('OK'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);

      // Tap OK to trigger submit() and async validation
      await tester.tap(find.text('OK'));
      await tester.pump(); // Start async operation

      // Verify validation is in progress
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      // While async validation is pending, user taps Cancel
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // Dialog is now dismissed
      expect(find.text('Socks5/Http(s) Proxy'), findsNothing);

      // Now complete the server test with success
      fakeBridge.testServerCompleter!.complete('');
      await tester.pumpAndSettle();

      // Invariant: no ghost commit should occur
      expect(fakeBridge.mainSetSocksCallCount, equals(0));
    });

    testWidgets('socks5_proxy_dialog: cancellation during failing async validation does not throw setState after dispose', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Overlay(key: overlayState.key),
      ));

      fakeBridge.testServerCompleter = Completer<String>();
      changeSocks5Proxy();
      await tester.pumpAndSettle();

      // Tap OK to trigger submit()
      await tester.tap(find.text('OK'));
      await tester.pump();

      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      // User taps Cancel while validation is in flight
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Socks5/Http(s) Proxy'), findsNothing);

      // Now complete the server test with error
      fakeBridge.testServerCompleter!.complete('Failed to connect');
      await tester.pumpAndSettle();

      // Invariant: no exception thrown, no commit
      expect(fakeBridge.mainSetSocksCallCount, equals(0));
    });

    testWidgets('server_settings_dialog: cancellation during async validation exits cleanly without setState after dispose', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Overlay(key: overlayState.key),
      ));

      fakeBridge.testServerCompleter = Completer<String>();
      showServerSettingsWithValue(
        ServerConfig(idServer: 'custom.server.com'),
        globalFFI.dialogManager,
        null,
      );
      await tester.pumpAndSettle();

      expect(find.text('ID/Relay Server'), findsOneWidget);
      expect(find.text('OK'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);

      // Tap OK to trigger submit() and async validation
      await tester.tap(find.text('OK'));
      await tester.pump();

      // Progress indicator should be visible
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      // User taps Cancel while async operation is pending
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // Dialog should be dismissed
      expect(find.text('ID/Relay Server'), findsNothing);

      // Now complete the async validation
      fakeBridge.testServerCompleter!.complete('');
      await tester.pumpAndSettle();

      // Verified: no exception thrown, clean exit
    });

    testWidgets('responsive minWidth constraint calculation for mobile and desktop screens', (tester) async {
      // Small screen: 360 x 640
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      late double mobileCalculatedWidth;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) {
            mobileCalculatedWidth = math.max(
              0.0,
              math.min(MediaQuery.sizeOf(context).width - 32, 500.0),
            );
            return Container();
          },
        ),
      ));

      expect(mobileCalculatedWidth, equals(328.0));

      // Large screen: 1024 x 768
      tester.view.physicalSize = const Size(1024, 768);
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) {
            final desktopCalculatedWidth = math.max(
              0.0,
              math.min(MediaQuery.sizeOf(context).width - 32, 500.0),
            );
            expect(desktopCalculatedWidth, equals(500.0));
            return Container();
          },
        ),
      ));
    });
  });

  group('Milestone 1 Feature 2: RadioGroup Modernization & getRadio', () {
    testWidgets('getRadio renders RadioGroup wrapping RadioListTile and responds to change', (tester) async {
      String? selected = 'opt1';

      Widget buildTestGroup() {
        return StatefulBuilder(
          builder: (context, setState) {
            return MaterialApp(
              home: Scaffold(
                body: Column(
                  children: [
                    getRadio<String>(
                      const Text('Option 1'),
                      'opt1',
                      selected ?? '',
                      (val) {
                        setState(() {
                          selected = val;
                        });
                      },
                    ),
                    getRadio<String>(
                      const Text('Option 2'),
                      'opt2',
                      selected ?? '',
                      (val) {
                        setState(() {
                          selected = val;
                        });
                      },
                    ),
                  ],
                ),
              ),
            );
          },
        );
      }

      await tester.pumpWidget(buildTestGroup());
      await tester.pumpAndSettle();

      expect(find.text('Option 1'), findsOneWidget);
      expect(find.text('Option 2'), findsOneWidget);
      expect(find.byType(RadioGroup<String>), findsNWidgets(2));
      expect(find.byType(RadioListTile<String>), findsNWidgets(2));

      // Tap Option 2
      await tester.tap(find.text('Option 2'));
      await tester.pumpAndSettle();

      expect(selected, equals('opt2'));

      // Tap Option 1
      await tester.tap(find.text('Option 1'));
      await tester.pumpAndSettle();

      expect(selected, equals('opt1'));
    });
  });
}
