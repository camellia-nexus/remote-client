import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/generated_bridge.dart';
import 'package:camellia_remote_app/main.dart';
import 'package:camellia_remote_app/models/platform_model.dart';
import 'package:camellia_remote_app/models/relative_mouse_model.dart';

class _MockRustdeskImpl extends RustdeskImpl {
  @override
  bool mainCurrentIsWayland() => false;

  @override
  int versionToNumber({required String v}) => 10400;

  @override
  Future<void> sessionSendMouse({
    required dynamic sessionId,
    required String msg,
  }) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('STATE-028: macOS Relative Mouse Multi-Window & Generation Fencing', () {
    const MethodChannel hostChannel = MethodChannel('com.camellia.remote/host');
    final List<MethodCall> nativeCalls = [];
    late SessionID sessionA;
    late SessionID sessionB;
    final List<Map<String, dynamic>> sentMessagesA = [];
    final List<Map<String, dynamic>> sentMessagesB = [];

    setUp(() {
      platformFFI.ffiBind = _MockRustdeskImpl();
      nativeCalls.clear();
      sentMessagesA.clear();
      sentMessagesB.clear();
      sessionA = const Uuid().v4obj();
      sessionB = const Uuid().v4obj();
      RelativeMouseModel.resetNativeStateForTesting();
      RelativeMouseModel.debugOverrideIsMacOS = true;
      kWindowId = 101;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hostChannel, (MethodCall call) async {
        nativeCalls.add(call);
        switch (call.method) {
          case 'enableNativeRelativeMouseMode':
            final args = call.arguments as Map<dynamic, dynamic>;
            final windowId = args['windowId'] as int?;
            final sessId = args['sessionId'] as String?;
            final gen = args['generation'] as int?;
            if (windowId == null || sessId == null || gen == null) {
              throw PlatformException(
                code: 'INVALID_ARGUMENT',
                message: 'Missing caller identity',
              );
            }
            return true;
          case 'disableNativeRelativeMouseMode':
            final args = call.arguments as Map<dynamic, dynamic>;
            final windowId = args['windowId'] as int?;
            final sessId = args['sessionId'] as String?;
            final gen = args['generation'] as int?;
            if (windowId == null || sessId == null || gen == null) {
              throw PlatformException(
                code: 'INVALID_ARGUMENT',
                message: 'Missing caller identity',
              );
            }
            return true;
          default:
            return null;
        }
      });
    });

    tearDown(() {
      RelativeMouseModel.resetNativeStateForTesting();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hostChannel, null);
    });

    RelativeMouseModel createModel({
      required SessionID sessionId,
      required List<Map<String, dynamic>> messagesList,
    }) {
      return RelativeMouseModel(
        sessionId: sessionId,
        enabled: false.obs,
        keyboardPerm: () => true,
        isViewCamera: () => false,
        peerVersion: () => '1.4.0',
        peerPlatform: () => 'Windows',
        modify: (msg) {
          messagesList.add(Map<String, dynamic>.from(msg));
          return msg;
        },
        getPointerInsideImage: () => true,
        setPointerInsideImage: (_) {},
      );
    }

    test('1. enable passes windowId, sessionId, generation and increments generation', () async {
      final modelA = createModel(sessionId: sessionA, messagesList: sentMessagesA);
      modelA.updateImageWidgetSize(const Size(800, 600));

      expect(modelA.nativeGeneration, equals(0));

      // Trigger relative mouse mode
      final accepted = modelA.setRelativeMouseMode(true);
      expect(accepted, isTrue);

      // Await event loop for async method channel call
      await pumpEventQueue();

      expect(nativeCalls.length, equals(1));
      final enableCall = nativeCalls.first;
      expect(enableCall.method, equals('enableNativeRelativeMouseMode'));
      final args = enableCall.arguments as Map<dynamic, dynamic>;
      expect(args['windowId'], equals(101));
      expect(args['sessionId'], equals(sessionA.toString()));
      expect(args['generation'], equals(1));
      expect(modelA.nativeGeneration, equals(1));
      expect(RelativeMouseModel.activeNativeModel, equals(modelA));
      expect(modelA.enabled.value, isTrue);
    });

    test('2. onMouseDelta routes to active model only when sessionId and generation match', () async {
      final modelA = createModel(sessionId: sessionA, messagesList: sentMessagesA);
      modelA.updateImageWidgetSize(const Size(800, 600));
      modelA.setRelativeMouseMode(true);
      await pumpEventQueue();

      expect(RelativeMouseModel.activeNativeModel, equals(modelA));
      sentMessagesA.clear(); // Clear initial enable marker message

      // Simulate onMouseDelta with matching sessionId and generation
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        'com.camellia.remote/host',
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('onMouseDelta', {
            'dx': 12,
            'dy': -8,
            'sessionId': sessionA.toString(),
            'generation': 1,
          }),
        ),
        (data) {},
      );

      expect(sentMessagesA.length, equals(1));
      expect(sentMessagesA.first['type'], equals('move_relative'));
      expect(sentMessagesA.first['x'], equals('12'));
      expect(sentMessagesA.first['y'], equals('-8'));

      // Stale sessionId from another session/window should be discarded
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        'com.camellia.remote/host',
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('onMouseDelta', {
            'dx': 99,
            'dy': 99,
            'sessionId': sessionB.toString(),
            'generation': 1,
          }),
        ),
        (data) {},
      );

      // Stale generation should be discarded
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        'com.camellia.remote/host',
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('onMouseDelta', {
            'dx': 50,
            'dy': 50,
            'sessionId': sessionA.toString(),
            'generation': 999, // Mismatched generation
          }),
        ),
        (data) {},
      );

      // Verify no extra messages were processed
      expect(sentMessagesA.length, equals(1));
    });

    test('3. OWNER_CONFLICT error from native rejects enable without activating model', () async {
      // Mock native returning OWNER_CONFLICT
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hostChannel, (MethodCall call) async {
        nativeCalls.add(call);
        if (call.method == 'enableNativeRelativeMouseMode') {
          throw PlatformException(
            code: 'OWNER_CONFLICT',
            message: 'Pointer lock already owned by another window',
            details: {'ownerWindowId': 200, 'ownerSessionId': 'other-session'},
          );
        }
        return null;
      });

      final modelB = createModel(sessionId: sessionB, messagesList: sentMessagesB);
      modelB.updateImageWidgetSize(const Size(800, 600));

      final accepted = modelB.setRelativeMouseMode(true);
      expect(accepted, isTrue);
      await pumpEventQueue();

      expect(nativeCalls.length, equals(1));
      expect(modelB.enabled.value, isFalse);
      expect(RelativeMouseModel.activeNativeModel, isNull);
    });

    test('4. disable sends active windowId, sessionId, generation and resets active model', () async {
      final modelA = createModel(sessionId: sessionA, messagesList: sentMessagesA);
      modelA.updateImageWidgetSize(const Size(800, 600));
      modelA.setRelativeMouseMode(true);
      await pumpEventQueue();

      expect(RelativeMouseModel.activeNativeModel, equals(modelA));
      nativeCalls.clear();

      // Disable relative mouse mode
      modelA.setRelativeMouseMode(false);
      await pumpEventQueue();

      expect(modelA.enabled.value, isFalse);
      expect(RelativeMouseModel.activeNativeModel, isNull);
      expect(nativeCalls.length, equals(1));

      final disableCall = nativeCalls.first;
      expect(disableCall.method, equals('disableNativeRelativeMouseMode'));
      final args = disableCall.arguments as Map<dynamic, dynamic>;
      expect(args['windowId'], equals(101));
      expect(args['sessionId'], equals(sessionA.toString()));
      expect(args['generation'], equals(1));
    });

    test('5. cancelled enable rolls back native pointer lock to prevent stranded lock', () async {
      final Completer<bool> enableCompleter = Completer<bool>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hostChannel, (MethodCall call) async {
        nativeCalls.add(call);
        if (call.method == 'enableNativeRelativeMouseMode') {
          return enableCompleter.future;
        }
        if (call.method == 'disableNativeRelativeMouseMode') {
          return true;
        }
        return null;
      });

      final modelA = createModel(sessionId: sessionA, messagesList: sentMessagesA);
      modelA.updateImageWidgetSize(const Size(800, 600));

      // Start enable
      modelA.setRelativeMouseMode(true);
      await Future<void>.delayed(Duration.zero);
      expect(nativeCalls.where((c) => c.method == 'enableNativeRelativeMouseMode').length, equals(1));

      // User immediately cancels / turns off relative mode before native returns
      modelA.setRelativeMouseMode(false);
      await Future<void>.delayed(Duration.zero);

      // Now native enable finally completes with success
      enableCompleter.complete(true);
      await pumpEventQueue();

      // Model must NOT be enabled
      expect(modelA.enabled.value, isFalse);
      expect(RelativeMouseModel.activeNativeModel, isNull);

      // Rollback must have called disableNativeRelativeMouseMode
      final disableCalls = nativeCalls.where((c) => c.method == 'disableNativeRelativeMouseMode');
      expect(disableCalls.isNotEmpty, isTrue);
    });

    test('6. dispose invalidates in-flight requests and triggers cleanup', () async {
      final modelA = createModel(sessionId: sessionA, messagesList: sentMessagesA);
      modelA.updateImageWidgetSize(const Size(800, 600));
      modelA.setRelativeMouseMode(true);
      await pumpEventQueue();

      expect(RelativeMouseModel.activeNativeModel, equals(modelA));
      nativeCalls.clear();

      bool onDisabledCalled = false;
      modelA.onDisabled = () => onDisabledCalled = true;

      modelA.dispose();
      await pumpEventQueue();

      expect(modelA.enabled.value, isFalse);
      expect(RelativeMouseModel.activeNativeModel, isNull);
      expect(onDisabledCalled, isTrue);
      expect(nativeCalls.where((c) => c.method == 'disableNativeRelativeMouseMode').length, equals(1));
    });

    test('7. rapid re-enable after cancellation preserves newest generation and does not destroy active lock', () async {
      final enableCompleter1 = Completer<bool>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hostChannel, (MethodCall call) async {
        nativeCalls.add(call);
        if (call.method == 'enableNativeRelativeMouseMode') {
          final args = call.arguments as Map<dynamic, dynamic>;
          final gen = args['generation'] as int;
          if (gen == 1) {
            return enableCompleter1.future;
          }
          return true;
        }
        if (call.method == 'disableNativeRelativeMouseMode') {
          return true;
        }
        return null;
      });

      final modelA = createModel(sessionId: sessionA, messagesList: sentMessagesA);
      modelA.updateImageWidgetSize(const Size(800, 600));

      // 1. First enable started (generation 1)
      modelA.setRelativeMouseMode(true);
      await Future<void>.delayed(Duration.zero);

      // 2. Immediately cancel (toggle off)
      modelA.setRelativeMouseMode(false);
      await Future<void>.delayed(Duration.zero);

      // 3. Immediately re-enable (generation 2)
      modelA.setRelativeMouseMode(true);
      await Future<void>.delayed(Duration.zero);

      // 4. Now generation 1 finally returns
      enableCompleter1.complete(true);
      await pumpEventQueue();

      // Generation 2 must remain active and NOT be destroyed by generation 1's rollback!
      expect(modelA.enabled.value, isTrue);
      expect(RelativeMouseModel.activeNativeModel, equals(modelA));
      expect(modelA.nativeGeneration, equals(2));

      // Generation 1 rollback must have targeted generation 1, not generation 2
      final disableCalls = nativeCalls.where((c) => c.method == 'disableNativeRelativeMouseMode');
      for (final call in disableCalls) {
        final args = call.arguments as Map<dynamic, dynamic>;
        expect(args['generation'], equals(1));
      }
    });

    test('8. performCleanupAsync cleanly awaits platform release and prevents double invocation', () async {
      int disableCount = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hostChannel, (MethodCall call) async {
        nativeCalls.add(call);
        if (call.method == 'enableNativeRelativeMouseMode') {
          return true;
        }
        if (call.method == 'disableNativeRelativeMouseMode') {
          disableCount++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return true;
        }
        return null;
      });

      final modelA = createModel(sessionId: sessionA, messagesList: sentMessagesA);
      modelA.updateImageWidgetSize(const Size(800, 600));
      modelA.setRelativeMouseMode(true);
      await pumpEventQueue();

      expect(RelativeMouseModel.activeNativeModel, equals(modelA));
      nativeCalls.clear();

      await modelA.performCleanupAsync();

      expect(modelA.enabled.value, isFalse);
      expect(RelativeMouseModel.activeNativeModel, isNull);
      expect(disableCount, equals(1));
    });
  });
}
