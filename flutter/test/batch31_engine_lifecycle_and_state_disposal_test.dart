import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/shared_state.dart';
import 'package:camellia_remote_app/generated_bridge.dart';
import 'package:camellia_remote_app/models/model.dart';
import 'package:camellia_remote_app/models/platform_model.dart';
import 'package:camellia_remote_app/models/server_model.dart';
import 'package:camellia_remote_app/models/ab_model.dart';

class _FakeRustdeskImpl extends RustdeskImpl {
  @override
  String mainGetLocalOption({required String key}) => '';
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
  Future<void> mainSetOption({required String key, required String value}) async {}
  @override
  @override
  String getLocalFlutterOption({required String k}) => '';
  @override
  Future<void> setLocalFlutterOption({required String k, required String v}) async {}
  @override
  Future<void> sessionClose({required UuidValue sessionId}) async {}
  @override
  Future<void> stopGlobalEventStream({required String appType}) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  platformFFI.ffiBind = _FakeRustdeskImpl();

  group('Batch 31: SharedState Generation Fencing and Safe Disposal (STATE-005)', () {
    const testId = 'peer_test_session_123';

    tearDown(() {
      removeSharedStates(testId);
    });

    test('initSharedStates registers states and assigns monotonically increasing generations', () {
      final gen1 = initSharedStates(testId);
      expect(gen1, greaterThan(0));
      expect(getSharedStateGeneration(testId), equals(gen1));

      // Re-initializing without passing a generation generates a strictly newer generation
      final gen2 = initSharedStates(testId);
      expect(gen2, greaterThan(gen1));
      expect(getSharedStateGeneration(testId), equals(gen2));
    });

    test('removeSharedStates with stale generation does NOT delete active states', () {
      final gen1 = initSharedStates(testId);
      // Simulate new session starting under same ID
      final gen2 = initSharedStates(testId);
      expect(gen2, greaterThan(gen1));

      // Stale teardown from gen1 arrives
      removeSharedStates(testId, expectedGeneration: gen1);

      // States from gen2 must still be registered and intact
      expect(Get.isRegistered<RxBool>(tag: KeyboardEnabledState.tag(testId)), isTrue);
      expect(getSharedStateGeneration(testId), equals(gen2));

      // Teardown from current gen2 cleans up properly
      removeSharedStates(testId, expectedGeneration: gen2);
      expect(Get.isRegistered<RxBool>(tag: KeyboardEnabledState.tag(testId)), isFalse);
      expect(getSharedStateGeneration(testId), isNull);
    });

    test('deleteIfMatching only removes matching instance from Get registry', () async {
      const tag = 'test_matching_tag';
      final instanceA = SimpleWrapper<String>('A');
      final instanceB = SimpleWrapper<String>('B');

      Get.put<SimpleWrapper<String>>(instanceA, tag: tag);
      expect(Get.isRegistered<SimpleWrapper<String>>(tag: tag), isTrue);

      // Attempt deletion with mismatched instance: must NOT delete
      final removedMismatched = await deleteIfMatching<SimpleWrapper<String>>(tag, instanceB);
      expect(removedMismatched, isFalse);
      expect(Get.isRegistered<SimpleWrapper<String>>(tag: tag), isTrue);
      expect(Get.find<SimpleWrapper<String>>(tag: tag), same(instanceA));

      // Attempt deletion with matching instance: must delete
      final removedMatched = await deleteIfMatching<SimpleWrapper<String>>(tag, instanceA);
      expect(removedMatched, isTrue);
      expect(Get.isRegistered<SimpleWrapper<String>>(tag: tag), isFalse);

      // Attempt deletion on non-registered tag: must return false without throwing
      final removedNonExistent = await deleteIfMatching<SimpleWrapper<String>>('non_existent', instanceA);
      expect(removedNonExistent, isFalse);
    });

    test('PrivacyModeState.delete does not throw on unregistered tag', () {
      expect(() => PrivacyModeState.delete('non_registered_id_999'), returnsNormally);
    });
  });

  group('Batch 31: Flutter FFI Model Segregation and Global Pollers (RES-049)', () {
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

    test('global FFI constructs server and ab models, while session FFI delegates to global', () {
      final sessionFFI = FFI(Uuid().v4obj(), isGlobal: false);

      // Session FFI delegates getters to global FFI
      expect(sessionFFI.serverModel, same(globalFFI.serverModel));
      expect(sessionFFI.abModel, same(globalFFI.abModel));

      // Session FFI does not have its own private models
      expect(sessionFFI.isGlobal, isFalse);
      expect(globalFFI.isGlobal, isTrue);
    });

    test('closing session FFI does not stop or dispose global pollers', () async {
      final sessionFFI = FFI(Uuid().v4obj(), isGlobal: false);
      await sessionFFI.close(closeSession: false);

      // Global models should remain active and non-disposed
      expect(globalFFI.serverModel.isDisposed, isFalse);
      expect(globalFFI.abModel.isDisposed, isFalse);
    });

    test('mobileReset increments sessionGeneration and issues distinct session UUID', () {
      final initialId = globalFFI.sessionId;
      final initialGen = globalFFI.sessionGeneration;

      globalFFI.mobileReset();

      expect(globalFFI.sessionId, isNot(equals(initialId)));
      expect(globalFFI.sessionGeneration, equals(initialGen + 1));
      expect(globalFFI.ffiModel.sessionId, equals(globalFFI.sessionId));
    });

    test('ServerModel supervised poller starts, stops, and handles disposal idempotently', () async {
      final serverModel = globalFFI.serverModel;
      expect(serverModel.isPolling, isFalse);

      serverModel.startPoller();
      expect(serverModel.isPolling, isTrue);

      // Starting again is idempotent
      serverModel.startPoller();
      expect(serverModel.isPolling, isTrue);

      await serverModel.stopPoller();
      expect(serverModel.isPolling, isFalse);

      // Stopping again is idempotent
      await serverModel.stopPoller();
      expect(serverModel.isPolling, isFalse);
    });

    test('AbModel supervised poller starts, stops, and handles disposal idempotently', () async {
      final abModel = globalFFI.abModel;
      expect(abModel.isPolling, isFalse);

      abModel.startPoller();
      expect(abModel.isPolling, isTrue);

      // Calling start again is idempotent
      abModel.startPoller();
      expect(abModel.isPolling, isTrue);

      await abModel.stopPoller();
      expect(abModel.isPolling, isFalse);

      await abModel.stopPoller();
      expect(abModel.isPolling, isFalse);
    });
  });
}
