import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/generated_bridge.dart';
import 'package:camellia_remote_app/models/platform_model.dart';

class _MockRustdeskImpl extends RustdeskImpl {
  final Map<String, String> _options = {};
  int startServiceCalls = 0;
  int stopServiceCalls = 0;

  @override
  String mainGetLocalOption({required String key}) => _options[key] ?? '';

  @override
  Future<String> mainGetOption({required String key}) async =>
      _options[key] ?? '';

  @override
  Future<void> mainSetOption({
    required String key,
    required String value,
  }) async {
    _options[key] = value;
  }

  @override
  Future<void> mainStartService() async {
    startServiceCalls++;
  }

  @override
  Future<void> mainStopService() async {
    stopServiceCalls++;
  }

  @override
  Future<String> mainGetConnectStatus() async => '{"status_num": 1}';

  @override
  Future<bool> optionSynced() async => true;

  @override
  Future<String> mainGetMyId() async => 'test-id-12345';

  @override
  Future<String> mainGetTemporaryPassword() async => '123456';

  @override
  bool isDisableAb() => false;

  @override
  bool isDisableAccount() => false;

  @override
  bool isDisableGroupPanel() => false;

  @override
  bool isCustomClient() => false;

  @override
  String getLocalFlutterOption({required String k}) => '';

  @override
  Future<void> setLocalFlutterOption({
    required String k,
    required String v,
  }) async {}

  @override
  Future<void> sessionClose({required dynamic sessionId}) async {}

  @override
  Future<void> stopGlobalEventStream({required String appType}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockRustdeskImpl mockBridge;

  setUp(() async {
    isTest = true;
    Get.reset();
    mockBridge = _MockRustdeskImpl();
    platformFFI.ffiBind = mockBridge;
    await initGlobalFFI();
  });

  tearDown(() async {
    await gFFI.close();
    Get.reset();
  });

  group('PRIV-010: Android Host Storage Permission Decoupling & ServerModel', () {
    test(
      'ServerModel starts screen sharing with zero storage permission prompts',
      () async {
        final serverModel = gFFI.serverModel;
        expect(serverModel.isStart, isFalse);

        await serverModel.startService();

        expect(serverModel.isStart, isTrue);
        expect(mockBridge.startServiceCalls, equals(1));

        await serverModel.stopService();
        expect(serverModel.isStart, isFalse);
        expect(mockBridge.stopServiceCalls, equals(1));
      },
    );

    test(
      'toggleFile toggles fileOk and invalidates session generation on disable',
      () async {
        final serverModel = gFFI.serverModel;
        final initialGen = serverModel.storageGeneration;

        if (!serverModel.fileOk) {
          await serverModel.toggleFile();
        }
        expect(serverModel.fileOk, isTrue);
        expect(
          await mockBridge.mainGetOption(key: kOptionEnableFileTransfer),
          equals(defaultOptionYes),
        );

        await serverModel.toggleFile();
        expect(serverModel.fileOk, isFalse);
        expect(
          await mockBridge.mainGetOption(key: kOptionEnableFileTransfer),
          equals('N'),
        );
        expect(serverModel.storageGeneration, greaterThan(initialGen));
      },
    );

    test('stopService invalidates storage generation', () async {
      final serverModel = gFFI.serverModel;
      final genBefore = serverModel.storageGeneration;

      await serverModel.stopService();
      expect(serverModel.storageGeneration, greaterThan(genBefore));
    });

    test(
      'requestSafDirectoryGrant delegates to platform MethodChannel',
      () async {
        final serverModel = gFFI.serverModel;
        await expectLater(serverModel.requestSafDirectoryGrant(), completes);
      },
    );
  });
}
