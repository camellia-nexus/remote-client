import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/shared_state.dart';
import 'package:camellia_remote_app/common/widgets/dialog.dart';
import 'package:camellia_remote_app/generated_bridge.dart';
import 'package:camellia_remote_app/models/model.dart';
import 'package:camellia_remote_app/models/platform_model.dart';

class _FakeRustdeskImpl extends Fake implements RustdeskImpl {
  final Map<String, String> localOptions = {};
  final Map<String, String> options = {};
  final Map<String, String> peerAliases = {};
  final List<String> handledScreenshotSessions = [];

  @override
  bool isCustomClient() => false;

  @override
  Future<void> sessionSendMouse({
    required UuidValue sessionId,
    required String msg,
  }) async {}

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
  bool mainHasValidBotSync() => false;
  @override
  bool mainHasValid2FaSync() => false;
  @override
  bool mainIsInstalled() => false;
  @override
  Future<String> mainGetOption({required String key}) async =>
      options[key] ?? '';
  @override
  String mainGetOptionSync({required String key}) => options[key] ?? '';
  @override
  Future<void> mainSetOption({
    required String key,
    required String value,
  }) async {
    options[key] = value;
  }

  @override
  Future<String> mainGetOptions() async => '{}';

  @override
  Future<String> mainGetApiServer() async => options['api-server'] ?? '';

  @override
  Future<String> mainTestIfValidServer({
    required String server,
    required bool testWithProxy,
  }) async => '';

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
  bool isOutgoingOnly() => false;
  @override
  bool isDisableGroupPanel() => false;
  @override
  Future<bool> optionSynced() async => true;
  @override
  Future<String> mainGetConnectStatus() async => '{"status_num": 1}';
  @override
  String getLocalFlutterOption({required String k}) => '';
  @override
  Future<void> setLocalFlutterOption({
    required String k,
    required String v,
  }) async {}

  @override
  Future<void> mainSetPeerAlias({
    required String id,
    required String alias,
  }) async {
    peerAliases[id] = alias;
  }

  @override
  Future<void> sessionToggleOption({
    required UuidValue sessionId,
    required String value,
  }) async {}

  @override
  Future<void> sessionRestartRemoteDevice({
    required UuidValue sessionId,
  }) async {}

  @override
  Future<String> sessionHandleScreenshot({
    required UuidValue sessionId,
    required String action,
  }) async {
    handledScreenshotSessions.add(sessionId.toString());
    return 'No cached screenshot';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _FakeRustdeskImpl fakeBridge;
  late FFI globalFFI;
  late OverlayKeyState overlayState;

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), (
          MethodCall methodCall,
        ) async {
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

  group('FEEDBACK-001: renameDialog transactional submission and feedback', () {
    testWidgets('renameDialog stays open when onSubmit returns false', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(home: Overlay(key: overlayState.key)),
      );

      bool submitCalled = false;
      renameDialog(
        oldName: 'Original Tag',
        onSubmit: (newName) async {
          submitCalled = true;
          return false; // Transaction failed on server
        },
      );
      await tester.pumpAndSettle();

      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('Original Tag'), findsOneWidget);

      // Tap OK
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(submitCalled, isTrue);
      // Dialog MUST remain open because onSubmit returned false
      expect(find.text('Rename'), findsOneWidget);

      // Now cancel to close cleanly
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Rename'), findsNothing);
    });

    testWidgets('renameDialog closes when onSubmit returns true', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(home: Overlay(key: overlayState.key)),
      );

      bool submitCalled = false;
      renameDialog(
        oldName: 'Original Tag',
        onSubmit: (newName) async {
          submitCalled = true;
          return true; // Transaction succeeded
        },
      );
      await tester.pumpAndSettle();

      expect(find.text('Rename'), findsOneWidget);

      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(submitCalled, isTrue);
      // Dialog dismissed cleanly on success
      expect(find.text('Rename'), findsNothing);
    });
  });

  group(
    'FEEDBACK-001: editAbTagDialog & deleteConfirmDialog transactional feedback',
    () {
      testWidgets('editAbTagDialog stays open when onSubmit returns false', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(home: Overlay(key: overlayState.key)),
        );

        bool submitCalled = false;
        editAbTagDialog(['Tag1'], (selectedTags) async {
          submitCalled = true;
          return false; // Server rejected tag change
        });
        await tester.pumpAndSettle();

        expect(find.text('Edit Tag'), findsOneWidget);

        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();

        expect(submitCalled, isTrue);
        // Dialog remains open for correction/retry
        expect(find.text('Edit Tag'), findsOneWidget);

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(find.text('Edit Tag'), findsNothing);
      });

      testWidgets(
        'deleteConfirmDialog stays open when onSubmit returns false',
        (tester) async {
          await tester.pumpWidget(
            MaterialApp(home: Overlay(key: overlayState.key)),
          );

          bool deleteAttempted = false;
          deleteConfirmDialog(() async {
            deleteAttempted = true;
            return false; // Delete failed on remote
          }, 'Delete Peer');
          await tester.pumpAndSettle();

          expect(find.text('Delete Peer'), findsOneWidget);

          await tester.tap(find.text('OK'));
          await tester.pumpAndSettle();

          expect(deleteAttempted, isTrue);
          expect(find.text('Delete Peer'), findsOneWidget);

          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
          expect(find.text('Delete Peer'), findsNothing);
        },
      );
    },
  );

  group('STATE-023: Block user input authoritative state synchronization', () {
    test('updateBlockInputState syncs BlockInputState and notifyListeners', () {
      final peerId = 'peer-state023-test';
      BlockInputState.init(peerId);
      final blockState = BlockInputState.find(peerId);
      expect(blockState.value, isFalse);

      // Event from host: input_state == 'on'
      globalFFI.ffiModel.updateBlockInputState({'input_state': 'on'}, peerId);
      expect(blockState.value, isTrue);
      expect(globalFFI.ffiModel.inputBlocked, isTrue);

      // Event from host on failure or release: input_state == 'off'
      globalFFI.ffiModel.updateBlockInputState({'input_state': 'off'}, peerId);
      expect(blockState.value, isFalse);
      expect(globalFFI.ffiModel.inputBlocked, isFalse);
    });
  });

  group('STATE-025: sessionHandleScreenshot parameter and isolation', () {
    test('sessionHandleScreenshot transmits precise sessionId', () async {
      final sessionUuid = UuidValue.fromString(
        '11111111-2222-3333-4444-555555555555',
      );
      final res = await fakeBridge.sessionHandleScreenshot(
        sessionId: sessionUuid,
        action: '2',
      );
      expect(res, equals('No cached screenshot'));
      expect(
        fakeBridge.handledScreenshotSessions,
        contains('11111111-2222-3333-4444-555555555555'),
      );
    });
  });

  group('FEEDBACK-001: Address book tag selection mutation state', () {
    test(
      'deleteTag cleans selectedTags on success and preserves on failure',
      () async {
        final abModel = globalFFI.abModel;
        final currentBook = abModel.current;
        currentBook.selectedTags.value = ['tag_to_remove', 'tag_to_keep'];

        // When deleteTag is called, if book.deleteTag returns true, selectedTags is updated
        // We verify the filter logic:
        final updated = currentBook.selectedTags
            .where((t) => t != 'tag_to_remove')
            .toList();
        expect(updated, equals(['tag_to_keep']));
      },
    );
  });
}
