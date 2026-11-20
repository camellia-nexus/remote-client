import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:camellia_remote_app/generated_bridge.dart';
import 'package:camellia_remote_app/common.dart';

/// Pure in-memory [RustdeskImpl] mock for deterministic desktop E2E testing.
class FakeRustdeskBridge extends RustdeskImpl {
  FakeRustdeskBridge({
    this.serverId = '888 999 111',
    this.password = 'TestPassword123',
    this.fingerprint = 'SHA256:abcd1234ef567890',
  });

  String serverId;
  String password;
  String fingerprint;
  String lastRemoteId = '';
  int refreshPasswordCallCount = 0;

  final Map<String, String> options = {};
  final Map<String, String> localOptions = {};
  final Map<String, String> flutterOptions = {};
  final Map<String, String> builtinOptions = {};
  final Map<String, Map<String, String>> peerOptions = {};
  final Map<String, String> peerAliases = {};
  final List<dynamic> favoritePeers = [];
  final List<String> removedPeers = [];
  final List<String> addedSessions = [];

  // --- Option getters & setters ---

  @override
  Future<String> mainGetOption({required String key}) async =>
      options[key] ?? '';

  @override
  Future<void> mainSetOption({
    required String key,
    required String value,
  }) async {
    options[key] = value;
  }

  @override
  String mainGetOptionSync({required String key}) => options[key] ?? '';

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
  String getLocalFlutterOption({required String k}) => flutterOptions[k] ?? '';

  @override
  Future<void> setLocalFlutterOption({
    required String k,
    required String v,
  }) async {
    flutterOptions[k] = v;
  }

  @override
  String mainGetBuildinOption({required String key}) =>
      builtinOptions[key] ?? '';

  void setBuildinOption(String key, String value) {
    builtinOptions[key] = value;
  }

  @override
  bool mainShowOption({required String key}) => false;

  @override
  bool mainHasHwcodec() => false;

  @override
  bool mainHasVram() => false;

  @override
  Future<void> mainCheckHwcodec() async {}

  @override
  bool mainGetUseTextureRender() => false;

  @override
  String mainVideoSaveDirectory({required bool root}) => '/tmp';

  @override
  Future<bool> mainSupportRemoveWallpaper() async => false;

  @override
  Future<String> mainGetLangs() async => jsonEncode(['en', 'zh-CN']);

  @override
  Future<String> mainHandleWaylandScreencastRestoreToken({
    required String key,
    required String value,
  }) async => '';

  @override
  Future<String> mainGetOptions() async => jsonEncode(options);

  @override
  String mainGetOptionsSync() => jsonEncode(options);

  // --- Identity & State ---

  @override
  Future<String> mainGetMyId() async => serverId;

  @override
  Future<String> mainGetTemporaryPassword() async => password;

  @override
  Future<void> mainUpdateTemporaryPassword() async {
    refreshPasswordCallCount++;
    password = 'UpdatedPass$refreshPasswordCallCount';
    try {
      if (isTest) {
        gFFI.serverModel.serverPasswd.text = password;
      }
    } catch (_) {}
  }

  @override
  Future<String> mainGetLicense() async => 'GPL-3.0';

  @override
  Future<String> mainGetVersion() async => '1.4.0';

  @override
  Future<String> mainGetBuildDate() async => '2026-11-20';

  @override
  Future<String> mainGetFingerprint() async => fingerprint;

  @override
  Future<String> mainGetConnectStatus() async => '{"status_num": 1}';

  @override
  Future<bool> optionSynced() async => true;

  @override
  String mainGetAppNameSync() => 'Camellia Remote';

  @override
  Future<String> mainGetLastRemoteId() async => lastRemoteId;

  @override
  Future<String> mainGetError() async => '';

  @override
  bool isIncomingOnly() => false;

  @override
  bool isOutgoingOnly() => false;

  @override
  bool isDisableSettings() => false;

  @override
  bool isDisableAb() => false;

  @override
  bool isDisableAccount() => false;

  @override
  bool isDisableGroupPanel() => false;

  @override
  bool isCustomClient() => false;

  @override
  bool pluginFeatureIsEnabled() => false;

  // --- Session & Events ---

  @override
  Future<void> sessionClose({required UuidValue sessionId}) async {}

  @override
  Future<void> stopGlobalEventStream({required String appType}) async {}

  @override
  Stream<String> startGlobalEventStream({required String appType}) =>
      const Stream.empty();

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
    addedSessions.add(id);
    return '';
  }

  @override
  String sessionAddExistedSync({
    required String id,
    required UuidValue sessionId,
    required List<int> displays,
    required bool isViewCamera,
  }) => '';

  @override
  int peerGetSessionsCount({required String id, required int connType}) => 0;

  // --- Peer & Address Book management ---

  @override
  Future<void> mainLoadRecentPeers() async {}

  @override
  Future<void> mainLoadFavPeers() async {}

  @override
  Future<void> mainLoadLanPeers() async {}

  @override
  Future<void> mainDiscover() async {}

  @override
  Future<List<String>> mainGetFav() async =>
      favoritePeers.map((e) => e.toString()).toList();

  @override
  Future<void> mainStoreFav({required List<dynamic> favs}) async {
    favoritePeers.clear();
    favoritePeers.addAll(favs);
  }

  @override
  Future<bool> mainPeerHasPassword({required String id}) async => false;

  @override
  Future<String> mainGetPeerOption({
    required String id,
    required String key,
  }) async =>
      peerOptions[id]?[key] ?? '';

  @override
  String mainGetPeerOptionSync({
    required String id,
    required String key,
  }) =>
      peerOptions[id]?[key] ?? '';

  @override
  Future<void> mainSetPeerOption({
    required String id,
    required String key,
    required String value,
  }) async {
    peerOptions.putIfAbsent(id, () => {})[key] = value;
  }

  @override
  Future<void> queryOnlines({required List<String> ids}) async {}

  @override
  Future<String> mainLoadAb() async => '';

  @override
  Future<String> mainLoadGroup() async => '';

  @override
  Future<void> mainSetPeerAlias({
    required String id,
    required String alias,
  }) async {
    peerAliases[id] = alias;
  }

  @override
  Future<void> mainRemovePeer({required String id}) async {
    removedPeers.add(id);
  }

  @override
  Future<void> mainRemoveDiscovered({required String id}) async {
    removedPeers.add(id);
  }

  @override
  Future<void> mainForgetPassword({required String id}) async {}

  @override
  int mainMaxEncryptLen() => 128;

  @override
  String mainUriPrefixSync() => 'camellia-remote://';

  @override
  Future<void> mainStartService() async {}

  @override
  Future<void> mainStopService() async {}

  @override
  Future<void> mainOnMainWindowClose() async {}

  @override
  Future<String?> cmCheckClientsLength({required int length}) async => null;

  @override
  Future<String> cmGetClientsState() async => '';

  // --- Environment & Capabilities ---

  @override
  bool mainCurrentIsWayland() => false;

  @override
  String mainGetMainDisplay() => '';

  @override
  String mainSupportedInputSource() => '0';

  @override
  String mainSupportedPrivacyModeImpls() => '';

  @override
  bool mainIsShareRdp() => false;

  @override
  Future<void> mainSetShareRdp({required bool enable}) async {}

  @override
  bool mainHasValidBotSync() => false;

  @override
  bool mainHasValid2FaSync() => false;

  @override
  bool mainIsInstalled() => false;

  @override
  String getLocalKbLayoutType() => '';

  @override
  Future<void> setLocalKbLayoutType({required String kbLayoutType}) async {}

  @override
  bool mainIsCanScreenRecording({required bool prompt}) => true;

  @override
  bool mainIsProcessTrusted({required bool prompt}) => true;

  @override
  bool mainIsCanInputMonitoring({required bool prompt}) => true;

  @override
  String translate({required String name, required String locale}) => name;

  // --- Server settings & API ---

  @override
  Future<String> mainGetApiServer() async => options['api-server'] ?? '';

  @override
  bool mainIsOptionFixed({required String key}) => false;

  @override
  Future<bool> mainIsUsingPublicServer() async => false;

  @override
  Future<bool> isPresetPassword() async => false;

  @override
  bool isPresetPasswordMobileOnly() => false;

  @override
  bool isDisableInstallation() => true;

  @override
  bool mainIsInstalledLowerVersion() => false;

  @override
  bool mainIsInstalledDaemon({required bool prompt}) => false;

  @override
  bool mainIsLoginWayland() => false;

  @override
  bool isSelinuxEnforcing() => false;

  @override
  Future<String> mainGetCommon({required String key}) async => '';

  @override
  String mainGetCommonSync({required String key}) => '';

  @override
  Future<bool> mainSetPermanentPasswordWithResult({
    required String password,
  }) async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    debugPrint(
      'FakeRustdeskBridge.noSuchMethod fallback: ${invocation.memberName}',
    );
    try {
      return super.noSuchMethod(invocation);
    } catch (_) {
      return null;
    }
  }
}
