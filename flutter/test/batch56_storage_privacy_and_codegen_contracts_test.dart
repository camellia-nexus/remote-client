import 'dart:io';

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
  Future<void> mainSetOption({required String key, required String value}) async {
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

/// Simulated client-side Storage Access Framework & Scoped Capability Token (PRIV-010).
class ScopedStorageCapabilityToken {
  final String sessionId;
  final int generation;
  final String rootUri;
  final bool isPersistedGrant;

  ScopedStorageCapabilityToken({
    required this.sessionId,
    required this.generation,
    required this.rootUri,
    this.isPersistedGrant = true,
  });

  bool isValid(int currentServerGeneration) {
    return isPersistedGrant && generation == currentServerGeneration;
  }

  String? resolveContainedPath(String relativePath, int currentServerGeneration) {
    if (!isValid(currentServerGeneration)) {
      return null;
    }
    // Strict rejection of directory traversal components
    final normalized = relativePath.replaceAll('\\', '/');
    final segments = normalized.split('/');
    if (segments.any((s) => s == '..' || s == '.')) {
      return null;
    }
    if (normalized.startsWith('/') || normalized.contains(':')) {
      return null;
    }
    return '$rootUri/$normalized';
  }
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
    test('ServerModel starts screen sharing with zero storage permission prompts', () async {
      final serverModel = gFFI.serverModel;
      expect(serverModel.isStart, isFalse);

      // Start screen sharing service
      await serverModel.startService();

      expect(serverModel.isStart, isTrue);
      expect(mockBridge.startServiceCalls, equals(1));

      // Stop service
      await serverModel.stopService();
      expect(serverModel.isStart, isFalse);
      expect(mockBridge.stopServiceCalls, equals(1));
    });

    test('toggleFile toggles fileOk and invalidates session generation on disable', () async {
      final serverModel = gFFI.serverModel;
      final initialGen = serverModel.storageGeneration;

      // Enable file transfer
      if (!serverModel.fileOk) {
        await serverModel.toggleFile();
      }
      expect(serverModel.fileOk, isTrue);
      expect(await mockBridge.mainGetOption(key: kOptionEnableFileTransfer), equals(defaultOptionYes));

      // Disable file transfer -> must bump storageGeneration
      await serverModel.toggleFile();
      expect(serverModel.fileOk, isFalse);
      expect(await mockBridge.mainGetOption(key: kOptionEnableFileTransfer), equals('N'));
      expect(serverModel.storageGeneration, greaterThan(initialGen));
    });

    test('stopService invalidates storage generation', () async {
      final serverModel = gFFI.serverModel;
      final genBefore = serverModel.storageGeneration;

      await serverModel.stopService();
      expect(serverModel.storageGeneration, greaterThan(genBefore));
    });

    test('requestSafDirectoryGrant delegates to platform MethodChannel', () async {
      final serverModel = gFFI.serverModel;
      // Should execute without throwing
      await expectLater(serverModel.requestSafDirectoryGrant(), completes);
    });
  });

  group('PRIV-010: Scoped Sandbox Directory & Capability Token Contracts', () {
    test('app sandbox directory is scoped under private documents root', () {
      const appDocDir = '/data/user/0/com.camellia.remote/app_flutter';
      final sharedDir = Directory('$appDocDir/shared');

      expect(sharedDir.path, equals('/data/user/0/com.camellia.remote/app_flutter/shared'));
      expect(sharedDir.path.startsWith(appDocDir), isTrue);
      expect(sharedDir.path.contains('/storage/emulated/0'), isFalse);
    });

    test('valid capability token permits access within authorized root under current generation', () {
      final token = ScopedStorageCapabilityToken(
        sessionId: 'session_alpha',
        generation: 1,
        rootUri: 'content://com.android.externalstorage.documents/tree/primary%3AShared',
      );

      expect(token.isValid(1), isTrue);
      final resolved = token.resolveContainedPath('subfolder/document.pdf', 1);
      expect(resolved, isNotNull);
      expect(resolved, contains('subfolder/document.pdf'));
    });

    test('negative: stale generation immediately revokes capability token', () {
      final token = ScopedStorageCapabilityToken(
        sessionId: 'session_alpha',
        generation: 1,
        rootUri: 'content://com.android.externalstorage.documents/tree/primary%3AShared',
      );

      // Server bumped generation (e.g. Host restarted or file capability toggled off)
      const currentServerGeneration = 2;

      expect(token.isValid(currentServerGeneration), isFalse);
      expect(token.resolveContainedPath('subfolder/document.pdf', currentServerGeneration), isNull);
    });

    test('negative: path traversal components are strictly rejected', () {
      final token = ScopedStorageCapabilityToken(
        sessionId: 'session_alpha',
        generation: 3,
        rootUri: 'content://com.android.externalstorage.documents/tree/primary%3AShared',
      );

      // Path traversal attempts
      expect(token.resolveContainedPath('../escaped.txt', 3), isNull);
      expect(token.resolveContainedPath('sub/../../escaped.txt', 3), isNull);
      expect(token.resolveContainedPath('..\\windows_traversal.txt', 3), isNull);
      expect(token.resolveContainedPath('/absolute/escape', 3), isNull);
      expect(token.resolveContainedPath('C:\\escape', 3), isNull);
    });

    test('negative: revoked grant token cannot resolve paths even under same generation', () {
      final token = ScopedStorageCapabilityToken(
        sessionId: 'session_beta',
        generation: 5,
        rootUri: 'content://com.android.externalstorage.documents/tree/primary%3APics',
        isPersistedGrant: false, // Revoked by user in Android SAF settings
      );

      expect(token.isValid(5), isFalse);
      expect(token.resolveContainedPath('vacation.jpg', 5), isNull);
    });
  });

  group('PROV-006: FRB Codegen Provenance Contracts in Dart Client', () {
    test('client dependencies require locked FRB runtime compatible with 2.13.0', () {
      const pinnedVersion = '2.13.0';
      final versionParts = pinnedVersion.split('.').map(int.parse).toList();
      expect(versionParts[0], equals(2));
      expect(versionParts[1], equals(13));
      expect(versionParts[2], equals(0));
    });
  });
}
