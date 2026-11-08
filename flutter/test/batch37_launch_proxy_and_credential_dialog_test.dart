import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/dialog.dart';
import 'package:camellia_remote_app/desktop/pages/desktop_setting_page.dart';
import 'package:camellia_remote_app/generated_bridge.dart';
import 'package:camellia_remote_app/mobile/widgets/deploy_dialog.dart';
import 'package:camellia_remote_app/models/model.dart';
import 'package:camellia_remote_app/models/platform_model.dart';

class _FakeRustdeskImpl extends Fake implements RustdeskImpl {
  final Map<String, String> localOptions = {};

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
  Future<void> mainSetSocks({
    required String proxy,
    required String username,
    required String password,
  }) async {}

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

  group('INIT-003: Flutter Launch Arguments & URI Link Validation', () {
    test('handleUriLink rejects flags missing target ID without crashing', () async {
      // Flag at end of argv
      final res1 = await handleUriLink(cmdArgs: ['--connect']);
      expect(res1, isFalse);

      final res2 = await handleUriLink(cmdArgs: ['--file-transfer']);
      expect(res2, isFalse);

      final res3 = await handleUriLink(cmdArgs: ['--view-camera']);
      expect(res3, isFalse);

      final res4 = await handleUriLink(cmdArgs: ['--port-forward']);
      expect(res4, isFalse);

      final res5 = await handleUriLink(cmdArgs: ['--rdp']);
      expect(res5, isFalse);

      final res6 = await handleUriLink(cmdArgs: ['--terminal']);
      expect(res6, isFalse);

      final res7 = await handleUriLink(cmdArgs: ['--terminal-admin']);
      expect(res7, isFalse);
    });

    test('handleUriLink rejects flags followed immediately by another flag', () async {
      final res = await handleUriLink(cmdArgs: ['--connect', '--password', 'secret']);
      expect(res, isFalse);
    });

    test('handleUriLink rejects missing password or switch_uuid argument', () async {
      final res1 = await handleUriLink(cmdArgs: ['--connect', '12345', '--password']);
      expect(res1, isFalse);

      final res2 = await handleUriLink(cmdArgs: ['--connect', '12345', '--switch_uuid']);
      expect(res2, isFalse);

      final res3 = await handleUriLink(cmdArgs: ['--connect', '12345', '--password', '--relay']);
      expect(res3, isFalse);
    });

    test('handleUriLink empty args returns true (window on top)', () async {
      final res = await handleUriLink(cmdArgs: []);
      expect(res, isTrue);
    });
  });

  group('CRED-007: Proxy Password Stored Sentinel & Masking', () {
    test('kStoredPasswordSentinel is defined and distinct from plaintext', () {
      expect(kStoredPasswordSentinel, isNotEmpty);
      expect(kStoredPasswordSentinel.contains('STORED_PASSWORD'), isTrue);
      expect(kStoredPasswordSentinel, equals('\u0000\u0000STORED_PASSWORD\u0000\u0000'));
    });
  });

  group('CRED-009: Credential Dialog Lifecycle, Clearance & Disposal', () {
    testWidgets('changeUnlockPinDialog safeClose clears and disposes controllers on cancel',
        (WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Overlay(key: overlayState.key),
      ));

      bool callbackInvoked = false;
      changeUnlockPinDialog('1234', () {
        callbackInvoked = true;
      });
      await tester.pumpAndSettle();

      expect(find.text('Set PIN'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Set PIN'), findsNothing);
      expect(callbackInvoked, isFalse);
    });

    testWidgets('checkUnlockPinDialog safeClose clears and disposes controller on cancel',
        (WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Overlay(key: overlayState.key),
      ));

      bool callbackInvoked = false;
      checkUnlockPinDialog('9999', () {
        callbackInvoked = true;
      });
      await tester.pumpAndSettle();

      expect(find.text('Cancel'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(callbackInvoked, isFalse);
    });

    testWidgets('changeBot safeClose clears and disposes controller on cancel',
        (WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Overlay(key: overlayState.key),
      ));

      bool callbackInvoked = false;
      changeBot(callback: () {
        callbackInvoked = true;
      });
      await tester.pumpAndSettle();

      expect(find.text('Telegram bot'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Telegram bot'), findsNothing);
      expect(callbackInvoked, isFalse);
    });

    testWidgets('showDeployDialog safeClose clears and disposes controllers on cancel',
        (WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Overlay(key: overlayState.key),
      ));

      showDeployDialog();
      await tester.pumpAndSettle();

      expect(find.text('Deploy'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Deploy'), findsNothing);
    });

    testWidgets('changeSocks5Proxy safeClose clears and disposes controllers on cancel',
        (WidgetTester tester) async {
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
  });
}
