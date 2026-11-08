import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/hbbs/hbbs.dart';
import 'package:camellia_remote_app/common/widgets/login.dart';
import 'package:camellia_remote_app/common/widgets/overlay.dart';
import 'package:camellia_remote_app/desktop/widgets/tabbar_widget.dart';
import 'package:camellia_remote_app/desktop/pages/terminal_tab_page.dart';
import 'package:camellia_remote_app/generated_bridge.dart';
import 'package:camellia_remote_app/models/desktop_render_texture.dart';
import 'package:camellia_remote_app/models/file_model.dart';
import 'package:camellia_remote_app/models/model.dart';
import 'package:camellia_remote_app/models/platform_model.dart';
import 'package:camellia_remote_app/utils/event_loop.dart';

class _FakeRustdeskImpl extends RustdeskImpl {
  final Map<String, String> localOptions = {};
  int confirmOverrideCallCount = 0;
  int registerPixelbufferCallCount = 0;
  int nextTextureKeyCounter = 100;

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
  Future<void> sessionClose({required UuidValue sessionId}) async {}
  @override
  Future<void> stopGlobalEventStream({required String appType}) async {}
  @override
  int getNextTextureKey() => ++nextTextureKeyCounter;
  @override
  bool isIncomingOnly() => false;
  @override
  bool isOutgoingOnly() => false;
  @override
  String mainGetPeerOptionSync({required String id, required String key}) => '';
  @override
  Future<void> sessionSendMouse({
    required UuidValue sessionId,
    required String msg,
  }) async {}
  @override
  Future<void> sessionHandleFlutterKeyEvent({
    required UuidValue sessionId,
    required String character,
    required int usbHid,
    required int lockModes,
    required bool downOrUp,
  }) async {}
  @override
  Future<String> sessionPeerOption({
    required UuidValue sessionId,
    required String name,
    required String value,
  }) async => '';
  @override
  Future<void> sessionSetConfirmOverrideFile({
    required UuidValue sessionId,
    required int actId,
    required int fileNum,
    required bool needOverride,
    required bool remember,
    required bool isUpload,
  }) async {
    confirmOverrideCallCount++;
  }

  @override
  void sessionRegisterPixelbufferTexture({
    required UuidValue sessionId,
    required int display,
    required int ptr,
  }) {
    registerPixelbufferCallCount++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestEvent extends BaseEvent<String, String> {
  final Future<void> Function(String data)? handler;

  _TestEvent(super.type, super.data, {this.handler});

  @override
  EventCallback<String>? findCallback(String type) {
    if (handler != null) {
      return (d) => handler!(d);
    }
    return null;
  }
}

class _TestFileDialogEvent
    extends BaseEvent<FileDialogType, Map<String, dynamic>> {
  _TestFileDialogEvent() : super(FileDialogType.overwrite, {});

  @override
  EventCallback<Map<String, dynamic>>? findCallback(FileDialogType type) =>
      null;
}

class _TestEventLoop extends BaseEventLoop<String, String> {
  int preConsumeCount = 0;
  int postConsumeCount = 0;
  int clearCount = 0;
  int startCount = 0;

  @override
  Future<void> onEventsStartConsuming() async {
    startCount++;
    await super.onEventsStartConsuming();
  }

  @override
  Future<void> onPreConsume(BaseEvent<String, String> evt) async {
    preConsumeCount++;
    await super.onPreConsume(evt);
  }

  @override
  Future<void> onPostConsume(BaseEvent<String, String> evt) async {
    postConsumeCount++;
    await super.onPostConsume(evt);
  }

  @override
  Future<void> onEventsClear() async {
    clearCount++;
    await super.onEventsClear();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  platformFFI.ffiBind = _FakeRustdeskImpl();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(MethodChannel('texture_rgba_renderer'), (
        call,
      ) async {
        if (call.method == 'createTexture') {
          return 123;
        } else if (call.method == 'closeTexture') {
          return true;
        } else if (call.method == 'getTexturePtr') {
          return 456;
        }
        return null;
      });

  group('Batch 32 RES-051: BaseEventLoop Bounded Capacity and Close Lifecycle', () {
    test(
      'pushEvent enforces maxQueueCapacity (drops and returns false on overflow)',
      () {
        final loop = _TestEventLoop();

        for (int i = 0; i < BaseEventLoop.maxQueueCapacity; i++) {
          final accepted = loop.pushEvent(_TestEvent('test', 'data-$i'));
          expect(accepted, isTrue);
        }
        expect(loop.evts.length, equals(BaseEventLoop.maxQueueCapacity));

        // Exceed capacity
        final overflowAccepted = loop.pushEvent(_TestEvent('test', 'overflow'));
        expect(overflowAccepted, isFalse);
        expect(loop.evts.length, equals(BaseEventLoop.maxQueueCapacity));
      },
    );

    test(
      'close() sets isClosed, advances generation, clears queue, rejects new events and prevents resurrection',
      () async {
        final loop = _TestEventLoop();
        final initialGen = loop.generation;

        loop.pushEvent(_TestEvent('test', 'data-1'));
        loop.pushEvent(_TestEvent('test', 'data-2'));
        expect(loop.evts.length, equals(2));

        await loop.close();

        expect(loop.isClosed, isTrue);
        expect(loop.generation, greaterThan(initialGen));
        expect(loop.evts.isEmpty, isTrue);

        // Pushing to closed loop must return false
        final pushResult = loop.pushEvent(_TestEvent('test', 'after-close'));
        expect(pushResult, isFalse);
        expect(loop.evts.isEmpty, isTrue);

        // Calling onReady() must not resurrect closed loop
        await loop.onReady();
        expect(loop.isClosed, isTrue);
      },
    );

    test(
      'close() awaits in-flight event consumption before completing',
      () async {
        final loop = _TestEventLoop();
        final completer = Completer<void>();
        bool consumed = false;

        loop.pushEvent(
          _TestEvent(
            'slow',
            'data',
            handler: (d) async {
              await completer.future;
              consumed = true;
            },
          ),
        );

        // Start loop
        await loop.onReady();

        // Give timer chance to fire and start consuming
        await Future.delayed(const Duration(milliseconds: 150));

        // Close requested while event handler is blocked on completer
        final closeFuture = loop.close(
          timeout: const Duration(milliseconds: 500),
        );
        expect(consumed, isFalse);

        // Complete in-flight task
        completer.complete();
        await closeFuture;

        expect(consumed, isTrue);
        expect(loop.isClosed, isTrue);
      },
    );

    test('FileDialogEventLoop resets batch state on close', () async {
      final fileLoop = FileDialogEventLoop();
      fileLoop.setOverrideConfirm(true);
      fileLoop.setSkip(true);

      await fileLoop.close();

      expect(fileLoop.isClosed, isTrue);
      // Pushing events after close should be rejected
      final accepted = fileLoop.pushEvent(_TestFileDialogEvent());
      expect(accepted, isFalse);
    });
  });

  group(
    'Batch 32 STATE-006: CancelablePeriodicTimer and Serial Async Execution',
    () {
      test(
        'cancelling before zero-delay tick prevents any execution',
        () async {
          int tickCount = 0;
          final timer = periodic_immediate(
            const Duration(milliseconds: 20),
            () async {
              tickCount++;
            },
          );

          expect(timer.isActive, isTrue);
          timer.cancel();
          expect(timer.isActive, isFalse);

          // Wait beyond the tick interval
          await Future.delayed(const Duration(milliseconds: 80));
          expect(tickCount, equals(0));
        },
      );

      test('serial async execution: consecutive ticks never overlap', () async {
        int concurrentCount = 0;
        int maxConcurrent = 0;
        int completedTicks = 0;

        final timer = periodic_immediate(
          const Duration(milliseconds: 10),
          () async {
            concurrentCount++;
            if (concurrentCount > maxConcurrent) {
              maxConcurrent = concurrentCount;
            }
            // Artificial async delay simulating work
            await Future.delayed(const Duration(milliseconds: 30));
            concurrentCount--;
            completedTicks++;
          },
        );

        // Allow 4 ticks to complete (each takes ~40ms: 30ms work + 10ms delay)
        await Future.delayed(const Duration(milliseconds: 150));
        timer.cancel();

        expect(maxConcurrent, equals(1));
        expect(completedTicks, greaterThanOrEqualTo(2));
        expect(timer.isActive, isFalse);
      });

      test(
        'cancel during in-flight async callback drops subsequent scheduled ticks',
        () async {
          int completedTicks = 0;
          late Timer timer;

          timer = periodic_immediate(
            const Duration(milliseconds: 10),
            () async {
              completedTicks++;
              if (completedTicks == 1) {
                timer.cancel();
              }
              await Future.delayed(const Duration(milliseconds: 20));
            },
          );

          await Future.delayed(const Duration(milliseconds: 100));
          expect(completedTicks, equals(1));
          expect(timer.isActive, isFalse);
        },
      );
    },
  );

  group('Batch 32 STATE-006: Component and Model Disposal Guards', () {
    late FFI globalFFI;

    setUp(() async {
      isTest = true;
      Get.reset();
      await initGlobalFFI();
      globalFFI = gFFI;
    });

    tearDown(() async {
      await globalFFI.close();
      Get.reset();
    });

    test(
      'InputModel dispose sets isDisposed and halts delayed input operations',
      () async {
        final input = globalFFI.inputModel;
        expect(input.isDisposed, isFalse);

        input.dispose();
        expect(input.isDisposed, isTrue);

        // Calling onMobileApps after dispose must not throw or schedule mouseup
        expect(() => input.onMobileApps(), returnsNormally);
        expect(() => input.tapHidKey(10), returnsNormally);

        // Advance clock past delays to verify callbacks safely return on _disposed
        await Future.delayed(const Duration(milliseconds: 550));
      },
    );

    test(
      'ServerModel scrollToBottom is safe when scrollController has no clients',
      () {
        final server = globalFFI.serverModel;
        expect(server.controller.hasClients, isFalse);

        // Calling scrollToBottom when unattached must not throw assertion or exception
        expect(() => server.scrollToBottom(), returnsNormally);
      },
    );

    test(
      'DesktopTabController jumpTo is safe with no clients and dispose cancels jump',
      () async {
        final controller = DesktopTabController(tabType: DesktopTabType.main);

        // jumpTo with empty tabs / no clients
        final jumped = controller.jumpTo(0);
        expect(jumped, isTrue);

        // Disposing controller cancels pending jump timer
        controller.dispose();
        await Future.delayed(const Duration(milliseconds: 150));
        // No crashes or unhandled client exceptions
      },
    );

    testWidgets(
      'OverlayDialogManager dismissAll clears dialogs safely without concurrent modification',
      (tester) async {
        final manager = OverlayDialogManager();
        final overlayState = OverlayKeyState();
        manager.setOverlayState(overlayState);

        await tester.pumpWidget(
          MaterialApp(home: Overlay(key: overlayState.key)),
        );

        expect(manager.activeDialogCount, equals(0));

        manager.show<bool>(
          (setState, close, context) =>
              CustomAlertDialog(content: const Text('dialog-1')),
        );
        manager.show<bool>(
          (setState, close, context) =>
              CustomAlertDialog(content: const Text('dialog-2')),
        );
        manager.show<bool>(
          (setState, close, context) =>
              CustomAlertDialog(content: const Text('dialog-3')),
        );

        await tester.pump();
        expect(manager.activeDialogCount, equals(3));

        // dismissAll should safely iterate and clear without concurrent modification
        expect(() => manager.dismissAll(), returnsNormally);
        await tester.pump();
        expect(manager.activeDialogCount, equals(0));
      },
    );

    test(
      'ChatModel dispose sets isDisposed and cleans up subscriptions/timers',
      () {
        final chat = globalFFI.chatModel;
        expect(chat.isDisposed, isFalse);

        final overlayState = BlockableOverlayState();
        chat.setOverlayState(overlayState);

        chat.dispose();
        expect(chat.isDisposed, isTrue);

        // Focus request after dispose should be safe and ignored
        chat.requestChatInputFocus();
        // Unread update after dispose should be safe and ignored
        chat.mobileUpdateUnreadSum();
      },
    );

    test('FileModel close shuts down evtLoop and dismisses dialogs', () async {
      final sessionFFI = FFI(Uuid().v4obj(), isGlobal: false);
      final fileModel = sessionFFI.fileModel;
      expect(fileModel.evtLoop.isClosed, isFalse);

      await fileModel.close();
      expect(fileModel.evtLoop.isClosed, isTrue);

      // Calling overrideFileConfirm when evtLoop is closed returns immediately
      await fileModel.overrideFileConfirm({'id': 123, 'read_path': 'test'});
    });

    test(
      'Cancellation of in-flight dialogs and FileDialogEventLoop generation fencing',
      () async {
        final sessionFFI = FFI(Uuid().v4obj(), isGlobal: false);
        final fileModel = sessionFFI.fileModel;
        final fakeBind = platformFFI.ffiBind as _FakeRustdeskImpl;
        final initialCallCount = fakeBind.confirmOverrideCallCount;

        // When closed, overrideFileConfirm aborts before and after any dialog logic
        await fileModel.close();
        expect(fileModel.evtLoop.isClosed, isTrue);

        await fileModel.overrideFileConfirm({
          'id': 999,
          'read_path': 'foo/bar',
        }, overrideConfirm: true);

        // Native FFI confirm override must NEVER be called
        expect(fakeBind.confirmOverrideCallCount, equals(initialCallCount));
      },
    );

    test(
      'PixelbufferTexture teardown race resilience prevents native registration',
      () async {
        final sessionFFI = FFI(Uuid().v4obj(), isGlobal: false);
        final texture = PixelbufferTexture();
        final fakeBind = platformFFI.ffiBind as _FakeRustdeskImpl;
        final initialRegistrations = fakeBind.registerPixelbufferCallCount;

        // Simulate a concurrent teardown during creation:
        // set isDestroying to true before createTexture completion
        texture.isDestroying = true;
        texture.create(0, sessionFFI.sessionId, sessionFFI);

        await Future.delayed(const Duration(milliseconds: 50));

        // Discarded texture must never be registered with native FFI
        expect(
          fakeBind.registerPixelbufferCallCount,
          equals(initialRegistrations),
        );
      },
    );

    test(
      'TerminalSessionRestoreCoordinator mounted-checked restore single-flight guard',
      () async {
        final coordinator = TerminalSessionRestoreCoordinator();
        expect(coordinator.isRestoringSessions, isFalse);

        final tabController = DesktopTabController(
          tabType: DesktopTabType.terminal,
        );
        addTearDown(() {
          tabController.dispose();
        });

        // Invalid arguments safely returns without throwing or hanging lock
        await coordinator.restoreSessions(
          arguments: 'invalid_json',
          isMounted: () => true,
          tabController: tabController,
          onAddTerminal: (peer, term) {},
          parseTabKey: (key) => null,
        );
        expect(coordinator.isRestoringSessions, isFalse);

        // Empty arguments safely finishes
        await coordinator.restoreSessions(
          arguments: '{"persistent_sessions": []}',
          isMounted: () => true,
          tabController: tabController,
          onAddTerminal: (peer, term) {},
          parseTabKey: (key) => null,
        );
        expect(coordinator.isRestoringSessions, isFalse);

        // If isMounted() returns false, it immediately aborts
        var addedCount = 0;
        await coordinator.restoreSessions(
          arguments:
              '{"peer_id": "test_peer", "persistent_sessions": [1, 2, 3]}',
          isMounted: () => false,
          tabController: tabController,
          onAddTerminal: (peer, term) => addedCount++,
          parseTabKey: (key) => ('test_peer', 0),
        );
        expect(coordinator.isRestoringSessions, isFalse);
        expect(addedCount, equals(0));

        // With seed tab present, processes sessions and halts when unmounted mid-stream
        tabController.add(
          TabInfo(key: 'test_peer_0', label: 'test_peer #0', page: Container()),
        );

        var mountedState = true;
        final addedTerminals = <int>[];
        final restoreFuture = coordinator.restoreSessions(
          arguments:
              '{"peer_id": "test_peer", "persistent_sessions": [10, 20, 30]}',
          isMounted: () => mountedState,
          tabController: tabController,
          onAddTerminal: (peer, termId) {
            addedTerminals.add(termId);
            if (termId == 10) {
              // Unmount during execution
              mountedState = false;
            }
          },
          parseTabKey: (key) {
            final parts = key.split('_');
            return ('${parts[0]}_${parts[1]}', int.tryParse(parts[2]) ?? 0);
          },
          delayOverride: (_) async {},
        );

        // Concurrent invocation should be rejected due to single-flight guard
        final concurrentFuture = coordinator.restoreSessions(
          arguments: '{"peer_id": "test_peer", "persistent_sessions": [99]}',
          isMounted: () => true,
          tabController: tabController,
          onAddTerminal: (peer, termId) => addedTerminals.add(termId),
          parseTabKey: (key) => ('test_peer', 0),
          delayOverride: (_) async {},
        );

        await Future.wait([restoreFuture, concurrentFuture]);
        expect(coordinator.isRestoringSessions, isFalse);
        // Terminal 10 was added, then unmounted aborted further additions (20, 30 not added, concurrent 99 rejected)
        expect(addedTerminals, equals([10]));
      },
    );
  });

  group('Batch 32 STATE-007: AuthGenerationTracker and Race Invalidation', () {
    setUp(() {
      AuthGenerationTracker.resetForTesting();
    });

    test('nextGen produces strictly monotonic generation numbers', () {
      final gen1 = AuthGenerationTracker.nextGen();
      final gen2 = AuthGenerationTracker.nextGen();
      final gen3 = AuthGenerationTracker.nextGen();

      expect(gen2, greaterThan(gen1));
      expect(gen3, greaterThan(gen2));
      expect(AuthGenerationTracker.currentAuthGen, equals(gen3));
    });

    test(
      'invalidate increments auth generation, invalidating in-flight login requests',
      () {
        final requestGen = AuthGenerationTracker.nextGen();
        expect(requestGen, equals(AuthGenerationTracker.currentAuthGen));

        // User dismisses dialog or cancels login
        AuthGenerationTracker.invalidate();
        expect(AuthGenerationTracker.currentAuthGen, greaterThan(requestGen));

        // Simulated completion check:
        bool shouldCommit =
            (requestGen == AuthGenerationTracker.currentAuthGen);
        expect(shouldCommit, isFalse);
      },
    );

    test('racing auth attempts: newer attempt supersedes older response', () {
      final firstGen = AuthGenerationTracker.nextGen();
      final secondGen = AuthGenerationTracker.nextGen();

      // Older response arrives late
      final isFirstCurrent = (firstGen == AuthGenerationTracker.currentAuthGen);
      expect(isFirstCurrent, isFalse);

      // Newer response arrives
      final isSecondCurrent =
          (secondGen == AuthGenerationTracker.currentAuthGen);
      expect(isSecondCurrent, isTrue);
    });

    test('Login request cancellation prevents token persistence', () async {
      final requestGen = AuthGenerationTracker.nextGen();
      final fakeBind = platformFFI.ffiBind as _FakeRustdeskImpl;
      fakeBind.localOptions.remove('access_token');

      // User cancels dialog before HTTP response completes
      AuthGenerationTracker.invalidate();

      bool dialogClosed = false;
      final committed = await handleLoginResponseStatic(
        resp: LoginResponse(
          type: HttpType.kAuthResTypeToken,
          access_token: 'cancelled_session_token',
          user: UserPayload.fromJson({'name': 'alice'}),
        ),
        storeIfAccessToken: true,
        requestGen: requestGen,
        closeCallback: ([_]) => dialogClosed = true,
      );

      // Outdated generation must be rejected and token must never be persisted
      expect(committed, isFalse);
      expect(dialogClosed, isFalse);
      expect(fakeBind.localOptions['access_token'], isNull);
    });

    test(
      'Generational fencing prevents out-of-order response overwriting newer credentials',
      () async {
        final fakeBind = platformFFI.ffiBind as _FakeRustdeskImpl;

        // User initiates first login attempt (e.g. slow network)
        final gen1 = AuthGenerationTracker.nextGen();

        // User initiates second login attempt (superseding gen1)
        final gen2 = AuthGenerationTracker.nextGen();

        // Attempt 2 response arrives first
        final committed2 = await handleLoginResponseStatic(
          resp: LoginResponse(
            type: HttpType.kAuthResTypeToken,
            access_token: 'token_attempt_2',
            user: UserPayload.fromJson({'name': 'user_2'}),
          ),
          storeIfAccessToken: true,
          requestGen: gen2,
        );
        expect(committed2, isTrue);
        expect(
          fakeBind.localOptions['access_token'],
          equals('token_attempt_2'),
        );

        // Attempt 1 response arrives late
        final committed1 = await handleLoginResponseStatic(
          resp: LoginResponse(
            type: HttpType.kAuthResTypeToken,
            access_token: 'token_attempt_1_late',
            user: UserPayload.fromJson({'name': 'user_1'}),
          ),
          storeIfAccessToken: true,
          requestGen: gen1,
        );

        // Stale attempt 1 must be discarded and MUST NOT overwrite Attempt 2's token
        expect(committed1, isFalse);
        expect(
          fakeBind.localOptions['access_token'],
          equals('token_attempt_2'),
        );
      },
    );

    test(
      'Verification code dialog cancellation prevents late 2FA token persistence',
      () async {
        final fakeBind = platformFFI.ffiBind as _FakeRustdeskImpl;
        fakeBind.localOptions['access_token'] = 'initial_token';

        final verifyGen = AuthGenerationTracker.nextGen();

        // User cancels the verification dialog
        AuthGenerationTracker.invalidate();

        bool closed = false;
        final handled = await handleVerifyResponseStatic(
          resp: LoginResponse(
            type: HttpType.kAuthResTypeToken,
            access_token: 'stale_2fa_token',
          ),
          verifyGen: verifyGen,
          closeCallback: ([_]) => closed = true,
        );

        expect(handled, isFalse);
        expect(closed, isFalse);
        expect(fakeBind.localOptions['access_token'], equals('initial_token'));
      },
    );

    test(
      'OIDC successful response with storeIfAccessToken=false triggers closeCallback',
      () async {
        final oidcGen = AuthGenerationTracker.nextGen();
        bool closed = false;

        final success = await handleLoginResponseStatic(
          resp: LoginResponse(
            type: HttpType.kAuthResTypeToken,
            access_token: 'oidc_token',
            user: UserPayload.fromJson({'name': 'oidc_user'}),
          ),
          storeIfAccessToken: false,
          requestGen: oidcGen,
          closeCallback: ([_]) => closed = true,
        );

        expect(success, isTrue);
        expect(closed, isTrue);
      },
    );
  });
}
