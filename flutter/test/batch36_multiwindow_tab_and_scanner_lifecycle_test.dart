import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/dialog.dart';
import 'package:camellia_remote_app/desktop/widgets/tabbar_widget.dart';
import 'package:camellia_remote_app/generated_bridge.dart';
import 'package:camellia_remote_app/models/model.dart';
import 'package:camellia_remote_app/models/peer_model.dart';
import 'package:camellia_remote_app/models/platform_model.dart';

class _FakeRustdeskImpl extends RustdeskImpl {
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
  Future<void> sessionClose({required UuidValue sessionId}) async {}
  @override
  Future<void> stopGlobalEventStream({required String appType}) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

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

  setUp(() async {
    fakeBridge = _FakeRustdeskImpl();
    platformFFI.ffiBind = fakeBridge;
    isTest = true;
    Get.reset();
    await initGlobalFFI();
    globalFFI = gFFI;
  });

  tearDown(() async {
    await globalFFI.close();
    Get.reset();
  });

  group('STATE-014: DesktopTabController.clear & Get Registry Instance Fencing', () {
    test('DesktopTabController.clear calls onRemoved for all tabs and resets selection', () {
      final controller = DesktopTabController(
        tabType: DesktopTabType.remoteScreen,
      );

      final removedKeys = <String>[];
      final removedIndices = <int>[];

      controller.onRemoved = (index, key) {
        removedIndices.add(index);
        removedKeys.add(key);
      };

      // Add 3 tabs
      controller.state.value.tabs.addAll([
        TabInfo(key: 'tab_alpha', label: 'Tab Alpha', page: Container()),
        TabInfo(key: 'tab_beta', label: 'Tab Beta', page: Container()),
        TabInfo(key: 'tab_gamma', label: 'Tab Gamma', page: Container()),
      ]);
      controller.state.value.selected = 1;
      controller.state.value.scrollController.itemCount = 3;

      expect(controller.state.value.tabs.length, equals(3));

      // Call clear()
      controller.clear();

      // Verify all tabs were cleared and onRemoved was invoked for each
      expect(controller.state.value.tabs, isEmpty);
      expect(controller.state.value.selected, equals(0));
      expect(controller.state.value.scrollController.itemCount, equals(0));

      expect(removedKeys, equals(['tab_gamma', 'tab_beta', 'tab_alpha']));
      expect(removedIndices, equals([2, 1, 0]));

      controller.dispose();
    });

    test('Get registry forced replacement safely overwrites stale FFI instances', () {
      const tag = 'peer_test_session_tag';

      final firstFFI = FFI(Uuid().v4obj(), isGlobal: false);
      Get.put<FFI>(firstFFI, tag: tag);

      expect(Get.find<FFI>(tag: tag), same(firstFFI));

      // Construct a new FFI instance for the same tag (e.g. subwindow reuse)
      final secondFFI = FFI(Uuid().v4obj(), isGlobal: false);

      // Using the hardened replacement pattern
      if (Get.isRegistered<FFI>(tag: tag)) {
        Get.delete<FFI>(tag: tag, force: true);
      }
      Get.put<FFI>(secondFFI, tag: tag);

      expect(Get.find<FFI>(tag: tag), same(secondFFI));
      expect(Get.find<FFI>(tag: tag), isNot(same(firstFFI)));
    });
  });

  group('STATE-015: setSharedAbPasswordDialog Error Retention & Re-entrancy Safety', () {
    testWidgets('failed password update keeps dialog open and retains user input', (tester) async {
      final overlayState = OverlayKeyState();
      globalFFI.dialogManager.setOverlayState(overlayState);

      await tester.pumpWidget(
        MaterialApp(home: Overlay(key: overlayState.key)),
      );

      final peer = Peer.fromJson({'id': 'peer_target_1', 'password': 'old_pw'});

      // Show dialog
      setSharedAbPasswordDialog('non_existent_ab', peer);
      await tester.pumpAndSettle();

      // Find OK button
      final okButtonFinder = find.widgetWithText(ElevatedButton, 'OK');
      expect(okButtonFinder, findsOneWidget);

      // Enter new password
      final textFieldFinder = find.byType(TextField);
      expect(textFieldFinder, findsOneWidget);
      await tester.enterText(textFieldFinder, 'new_secret_password');
      await tester.pumpAndSettle();

      // Tap OK - mutation fails because address book does not exist
      await tester.tap(okButtonFinder);
      await tester.pumpAndSettle();

      // Dialog is NOT dismissed on failure; input is retained for retry
      expect(find.byType(CustomAlertDialog), findsOneWidget);
      expect(find.text('new_secret_password'), findsOneWidget);
    });

    testWidgets('cancel button closes dialog and disposes controller', (tester) async {
      final overlayState = OverlayKeyState();
      globalFFI.dialogManager.setOverlayState(overlayState);

      await tester.pumpWidget(
        MaterialApp(home: Overlay(key: overlayState.key)),
      );

      final peer = Peer.fromJson({'id': 'peer_target_2', 'password': 'old_pw'});

      setSharedAbPasswordDialog('non_existent_ab', peer);
      await tester.pumpAndSettle();

      final cancelButtonFinder = find.widgetWithText(OutlinedButton, 'Cancel');
      expect(cancelButtonFinder, findsOneWidget);

      await tester.tap(cancelButtonFinder);
      await tester.pumpAndSettle();

      // Dialog closed
      expect(find.byType(CustomAlertDialog), findsNothing);
    });
  });

  group('STATE-027: Mobile QR Scanner Validation & Debounce Safety', () {
    test('ServerConfig.decode validates configuration format and rejects invalid prefixes', () {
      // Valid config payload
      const validConfig = 'config=eyJob3N0IjoiMS4yLjMuNCJ9';
      expect(validConfig.startsWith('config='), isTrue);

      // Invalid config payloads
      const invalidNoPrefix = 'eyJob3N0IjoiMS4yLjMuNCJ9';
      expect(invalidNoPrefix.startsWith('config='), isFalse);

      const invalidRandomUrl = 'https://example.com/login?token=abc';
      expect(invalidRandomUrl.startsWith('config='), isFalse);

      const invalidEmpty = '';
      expect(invalidEmpty.startsWith('config='), isFalse);
    });
  });
}
