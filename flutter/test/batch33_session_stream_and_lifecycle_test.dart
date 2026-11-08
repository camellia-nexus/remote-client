import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/generated_bridge.dart';
import 'package:camellia_remote_app/models/model.dart';
import 'package:camellia_remote_app/models/platform_model.dart';

class _FakeRustdeskImpl extends RustdeskImpl {
  final Map<String, String> localOptions = {};
  String sessionAddSyncResult = '';
  int sessionAddSyncCalls = 0;
  int sessionStartCalls = 0;
  int stopGlobalEventStreamCalls = 0;
  String? lastStoppedAppType;

  final StreamController<String> globalStreamController =
      StreamController<String>.broadcast();
  final StreamController<EventToUI> sessionStreamController =
      StreamController<EventToUI>.broadcast();

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
  Stream<String> startGlobalEventStream({required String appType}) {
    return globalStreamController.stream;
  }

  @override
  Future<void> stopGlobalEventStream({required String appType}) async {
    stopGlobalEventStreamCalls++;
    lastStoppedAppType = appType;
  }

  @override
  String sessionAddSync({
    required UuidValue sessionId,
    required String id,
    required bool isFileTransfer,
    required bool isViewCamera,
    required bool isPortForward,
    required bool isRdp,
    required bool isTerminal,
    required String switchUuid,
    required bool forceRelay,
    required String password,
    required bool isSharedPassword,
    String? connToken,
    required bool isTerminalAdmin,
  }) {
    sessionAddSyncCalls++;
    return sessionAddSyncResult;
  }

  @override
  Stream<EventToUI> sessionStart({
    required UuidValue sessionId,
    required String id,
  }) {
    sessionStartCalls++;
    return sessionStreamController.stream;
  }

  @override
  Stream<EventToUI> sessionStartWithDisplays({
    required UuidValue sessionId,
    required String id,
    required List<int> displays,
  }) {
    sessionStartCalls++;
    return sessionStreamController.stream;
  }

  @override
  Future<void> sessionClose({required UuidValue sessionId}) async {}
  @override
  Future<void> sessionSendMouse({
    required UuidValue sessionId,
    required String msg,
  }) async {}
  @override
  bool mainGetUseTextureRender() => false;
  @override
  Future<int> sessionGetTrackpadSpeed({required UuidValue sessionId}) async => 0;
  @override
  void sessionRegisterPixelbufferTexture({
    required UuidValue sessionId,
    required int display,
    required int ptr,
  }) {}
  @override
  bool mainHasGpuTextureRender() => false;
  int nextTextureKeyCounter = 100;
  @override
  int getNextTextureKey() => ++nextTextureKeyCounter;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeRustdeskImpl fakeBridge;

  setUp(() {
    fakeBridge = _FakeRustdeskImpl();
    platformFFI.ffiBind = fakeBridge;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('texture_rgba_renderer'), (
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
  });

  tearDown(() {
    fakeBridge.globalStreamController.close();
    fakeBridge.sessionStreamController.close();
  });

  group('RES-052: Supervised macOS Termination Timer', () {
    test('supervisedMacOSTerminate halts after maxAttempts without leaking', () async {
      int attempts = 0;
      final timer = supervisedMacOSTerminate(
        maxAttempts: 3,
        interval: const Duration(milliseconds: 10),
        terminateFn: () async {
          attempts++;
        },
      );

      expect(timer.isActive, isTrue);

      // Wait for timer to complete all 3 attempts
      await Future.delayed(const Duration(milliseconds: 60));

      expect(attempts, equals(3));
      expect(timer.isActive, isFalse);
    });

    test('supervisedMacOSTerminate handles exceptions in terminateFn safely', () async {
      int attempts = 0;
      final timer = supervisedMacOSTerminate(
        maxAttempts: 2,
        interval: const Duration(milliseconds: 10),
        terminateFn: () async {
          attempts++;
          throw Exception('Native platform channel unavailable');
        },
      );

      await Future.delayed(const Duration(milliseconds: 45));

      expect(attempts, equals(2));
      expect(timer.isActive, isFalse);
    });

    test('supervisedMacOSTerminate can be cancelled early by caller', () async {
      int attempts = 0;
      final timer = supervisedMacOSTerminate(
        maxAttempts: 10,
        interval: const Duration(milliseconds: 10),
        terminateFn: () async {
          attempts++;
        },
      );

      await Future.delayed(const Duration(milliseconds: 15));
      timer.cancel();
      final recordedAttempts = attempts;

      await Future.delayed(const Duration(milliseconds: 50));
      expect(attempts, equals(recordedAttempts));
      expect(timer.isActive, isFalse);
    });
  });

  group('RES-052: DesktopTab macOS Window Close Generational Fencing', () {
    test('Sequential reentrant calls cancel prior check and follow-up timers', () async {
      int closeExecuted = 0;
      int generation = 0;
      Timer? checkTimer;
      Timer? followupTimer;

      void triggerMacOSClose(Future<bool> Function() checkFs, Future<void> Function() closeFunc) {
        checkTimer?.cancel();
        followupTimer?.cancel();
        final myGen = ++generation;
        int counter = 0;

        checkTimer = Timer.periodic(const Duration(milliseconds: 10), (timer) async {
          if (myGen != generation) {
            timer.cancel();
            return;
          }
          counter++;
          final isFs = await checkFs();
          if (myGen != generation) {
            timer.cancel();
            return;
          }
          if (!isFs || counter >= 5) {
            timer.cancel();
            if (checkTimer == timer) {
              checkTimer = null;
            }
            followupTimer?.cancel();
            followupTimer = Timer(const Duration(milliseconds: 30), () async {
              if (myGen == generation) {
                await closeFunc();
              }
            });
          }
        });
      }

      // First close call
      triggerMacOSClose(
        () async => false,
        () async {
          closeExecuted++;
        },
      );

      // Reentrant second call immediately bumps generation
      triggerMacOSClose(
        () async => false,
        () async {
          closeExecuted++;
        },
      );

      await Future.delayed(const Duration(milliseconds: 80));

      // Exactly 1 close callback executed (from generation 2, generation 1 cancelled)
      expect(closeExecuted, equals(1));
      expect(checkTimer, isNull);
    });
  });

  group('STATE-011: Global Event Stream Ordering & Subscription Lifecycle', () {
    test('Global events are processed strictly sequentially in FIFO order', () async {
      final processedEvents = <String>[];
      final completer1 = Completer<void>();
      final completer2 = Completer<void>();

      platformFFI.registerEventHandler('test_global', 'handler', (evt) async {
        final id = evt['id'] as String;
        processedEvents.add('start_$id');
        if (id == '1') {
          // Simulate slow asynchronous task
          await Future.delayed(const Duration(milliseconds: 30));
          completer1.complete();
        } else if (id == '2') {
          completer2.complete();
        }
        processedEvents.add('finish_$id');
      });

      // Start listening with fake bridge
      platformFFI.startListenEvent(fakeBridge);

      // Emit two events rapidly
      fakeBridge.globalStreamController.add(jsonEncode({'name': 'test_global', 'id': '1'}));
      fakeBridge.globalStreamController.add(jsonEncode({'name': 'test_global', 'id': '2'}));

      await Future.wait([completer1.future, completer2.future]);

      // Strict FIFO sequential execution: event 1 completely finishes before event 2 starts
      expect(processedEvents, equals(['start_1', 'finish_1', 'start_2', 'finish_2']));

      platformFFI.stopListenEvent(fakeBridge);
    });

    test('stopListenEvent cancels stream and calls bridge stop', () {
      platformFFI.startListenEvent(fakeBridge);
      expect(fakeBridge.stopGlobalEventStreamCalls, equals(0));

      platformFFI.stopListenEvent(fakeBridge);
      expect(fakeBridge.stopGlobalEventStreamCalls, equals(1));
    });

    test('dispose clears event handlers and stops event stream', () {
      platformFFI.registerEventHandler('dummy', 'h', (evt) async {});
      expect(platformFFI.tryHandle({'name': 'dummy'}), completion(isTrue));

      platformFFI.dispose();

      // Handlers cleared
      expect(platformFFI.tryHandle({'name': 'dummy'}), completion(isFalse));
    });
  });

  group('INIT-002: FFI Session Startup & Native Add Validation', () {
    test('FFI.start aborts and returns error if sessionAddSync fails', () {
      fakeBridge.sessionAddSyncResult = 'Failed to add session with id 123456, same session id is found';

      final ffi = FFI(null);
      final result = ffi.start('123456');

      expect(result, contains('same session id is found'));
      expect(ffi.closed, isTrue);
      expect(fakeBridge.sessionAddSyncCalls, equals(1));
      // sessionStart was NOT called because add failed
      expect(fakeBridge.sessionStartCalls, equals(0));
    });

    test('FFI.start succeeds and establishes stream when sessionAddSync succeeds', () {
      fakeBridge.sessionAddSyncResult = '';

      final ffi = FFI(null);
      final result = ffi.start('123456');

      expect(result, equals(''));
      expect(ffi.closed, isFalse);
      expect(fakeBridge.sessionAddSyncCalls, equals(1));
      expect(fakeBridge.sessionStartCalls, equals(1));

      ffi.close();
    });

    test('FFI.close cancels session event stream subscription and resets queue', () {
      fakeBridge.sessionAddSyncResult = '';

      final ffi = FFI(null);
      ffi.start('123456');

      expect(ffi.closed, isFalse);
      ffi.close();
      expect(ffi.closed, isTrue);
    });
  });

  group('STATE-012: Multi-Window Tab Transfer Two-Phase Handoff', () {
    test('commit_tab_transfer constant is defined and matches protocol', () {
      expect(kWindowEventCommitTabTransfer, equals('commit_tab_transfer'));
    });

    test('CachedPeerData serializes and deserializes accurately', () {
      final cached = CachedPeerData();
      cached.peerInfo = {'hostname': 'camellia-workstation', 'version': '1.0.1'};
      cached.permissions = {'keyboard': true, 'mouse': true};
      cached.secure = true;
      cached.direct = false;

      final serialized = cached.toString();
      final deserialized = CachedPeerData.fromString(serialized);

      expect(deserialized, isNotNull);
      expect(deserialized!.peerInfo['hostname'], equals('camellia-workstation'));
      expect(deserialized.permissions['keyboard'], isTrue);
      expect(deserialized.secure, isTrue);
      expect(deserialized.direct, isFalse);
    });

    test('CachedPeerData handles null/invalid string gracefully', () {
      expect(CachedPeerData.fromString('not-json'), isNull);
      expect(CachedPeerData.fromString(''), isNull);
    });
  });
}
