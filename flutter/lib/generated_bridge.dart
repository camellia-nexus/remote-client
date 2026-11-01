import 'dart:async';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import 'generated_bridge/flutter_ffi.dart' as ffi;
import 'generated_bridge/flutter_ffi.dart' show EventToUI;

export 'generated_bridge/frb_generated.dart';
export 'generated_bridge/flutter_ffi.dart' hide translate;
export 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;

class RustdeskImpl {
  const RustdeskImpl();

  Stream<String> startGlobalEventStream({required String appType}) =>
      ffi.startGlobalEventStream(appType: appType);
  Future<void> stopGlobalEventStream({required String appType}) =>
      ffi.stopGlobalEventStream(appType: appType);
  Future<void> hostStopSystemKeyPropagate({required bool stopped}) =>
      ffi.hostStopSystemKeyPropagate(stopped: stopped);
  int peerGetSessionsCount({required String id, required int connType}) =>
      ffi.peerGetSessionsCount(id: id, connType: connType);
  String sessionAddExistedSync({
    required String id,
    required UuidValue sessionId,
    required List<int> displays,
    required bool isViewCamera,
  }) => ffi.sessionAddExistedSync(
    id: id,
    sessionId: sessionId,
    displays: displays,
    isViewCamera: isViewCamera,
  );
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
  }) => ffi.sessionAddSync(
    sessionId: sessionId,
    id: id,
    isFileTransfer: isFileTransfer,
    isViewCamera: isViewCamera,
    isPortForward: isPortForward,
    isRdp: isRdp,
    isTerminal: isTerminal,
    switchUuid: switchUuid,
    forceRelay: forceRelay,
    password: password,
    isSharedPassword: isSharedPassword,
    connToken: connToken,
  );
  Stream<EventToUI> sessionStart({
    required UuidValue sessionId,
    required String id,
  }) => ffi.sessionStart(sessionId: sessionId, id: id);
  Stream<EventToUI> sessionStartWithDisplays({
    required UuidValue sessionId,
    required String id,
    required List<int> displays,
  }) => ffi.sessionStartWithDisplays(
    sessionId: sessionId,
    id: id,
    displays: displays,
  );
  Future<bool?> sessionGetRemember({required UuidValue sessionId}) =>
      ffi.sessionGetRemember(sessionId: sessionId);
  Future<bool?> sessionGetToggleOption({
    required UuidValue sessionId,
    required String arg,
  }) => ffi.sessionGetToggleOption(sessionId: sessionId, arg: arg);
  bool sessionGetToggleOptionSync({
    required UuidValue sessionId,
    required String arg,
  }) => ffi.sessionGetToggleOptionSync(sessionId: sessionId, arg: arg);
  Future<String?> sessionGetOption({
    required UuidValue sessionId,
    required String arg,
  }) => ffi.sessionGetOption(sessionId: sessionId, arg: arg);
  Future<void> sessionLogin({
    required UuidValue sessionId,
    required String osUsername,
    required String osPassword,
    required String password,
    required bool remember,
  }) => ffi.sessionLogin(
    sessionId: sessionId,
    osUsername: osUsername,
    osPassword: osPassword,
    password: password,
    remember: remember,
  );
  Future<void> sessionSend2Fa({
    required UuidValue sessionId,
    required String code,
    required bool trustThisDevice,
  }) => ffi.sessionSend2Fa(
    sessionId: sessionId,
    code: code,
    trustThisDevice: trustThisDevice,
  );
  bool sessionGetEnableTrustedDevices({required UuidValue sessionId}) =>
      ffi.sessionGetEnableTrustedDevices(sessionId: sessionId);
  bool willSessionCloseCloseSession({required UuidValue sessionId}) =>
      ffi.willSessionCloseCloseSession(sessionId: sessionId);
  Future<void> sessionClose({required UuidValue sessionId}) =>
      ffi.sessionClose(sessionId: sessionId);
  Future<void> sessionRefresh({
    required UuidValue sessionId,
    required int display,
  }) => ffi.sessionRefresh(sessionId: sessionId, display: display);
  Future<void> sessionTakeScreenshot({
    required UuidValue sessionId,
    required int display,
  }) => ffi.sessionTakeScreenshot(sessionId: sessionId, display: display);
  Future<String> sessionHandleScreenshot({
    required UuidValue sessionId,
    required String action,
  }) => ffi.sessionHandleScreenshot(sessionId: sessionId, action: action);
  bool sessionIsMultiUiSession({required UuidValue sessionId}) =>
      ffi.sessionIsMultiUiSession(sessionId: sessionId);
  Future<void> sessionRecordScreen({
    required UuidValue sessionId,
    required bool start,
  }) => ffi.sessionRecordScreen(sessionId: sessionId, start: start);
  bool sessionGetIsRecording({required UuidValue sessionId}) =>
      ffi.sessionGetIsRecording(sessionId: sessionId);
  Future<void> sessionReconnect({
    required UuidValue sessionId,
    required bool forceRelay,
  }) => ffi.sessionReconnect(sessionId: sessionId, forceRelay: forceRelay);
  Future<void> sessionToggleOption({
    required UuidValue sessionId,
    required String value,
  }) => ffi.sessionToggleOption(sessionId: sessionId, value: value);
  Future<void> sessionTogglePrivacyMode({
    required UuidValue sessionId,
    required String implKey,
    required bool on,
  }) => ffi.sessionTogglePrivacyMode(
    sessionId: sessionId,
    implKey: implKey,
    on_: on,
  );
  Future<String?> sessionGetFlutterOption({
    required UuidValue sessionId,
    required String k,
  }) => ffi.sessionGetFlutterOption(sessionId: sessionId, k: k);
  Future<void> sessionSetFlutterOption({
    required UuidValue sessionId,
    required String k,
    required String v,
  }) => ffi.sessionSetFlutterOption(sessionId: sessionId, k: k, v: v);
  int getNextTextureKey() => ffi.getNextTextureKey();
  String getLocalFlutterOption({required String k}) =>
      ffi.getLocalFlutterOption(k: k);
  Future<void> setLocalFlutterOption({required String k, required String v}) =>
      ffi.setLocalFlutterOption(k: k, v: v);
  String getLocalKbLayoutType() => ffi.getLocalKbLayoutType();
  Future<void> setLocalKbLayoutType({required String kbLayoutType}) =>
      ffi.setLocalKbLayoutType(kbLayoutType: kbLayoutType);
  Future<String?> sessionGetViewStyle({required UuidValue sessionId}) =>
      ffi.sessionGetViewStyle(sessionId: sessionId);
  Future<void> sessionSetViewStyle({
    required UuidValue sessionId,
    required String value,
  }) => ffi.sessionSetViewStyle(sessionId: sessionId, value: value);
  Future<String?> sessionGetScrollStyle({required UuidValue sessionId}) =>
      ffi.sessionGetScrollStyle(sessionId: sessionId);
  Future<void> sessionSetScrollStyle({
    required UuidValue sessionId,
    required String value,
  }) => ffi.sessionSetScrollStyle(sessionId: sessionId, value: value);
  Future<int?> sessionGetEdgeScrollEdgeThickness({
    required UuidValue sessionId,
  }) => ffi.sessionGetEdgeScrollEdgeThickness(sessionId: sessionId);
  Future<void> sessionSetEdgeScrollEdgeThickness({
    required UuidValue sessionId,
    required int value,
  }) =>
      ffi.sessionSetEdgeScrollEdgeThickness(sessionId: sessionId, value: value);
  Future<String?> sessionGetImageQuality({required UuidValue sessionId}) =>
      ffi.sessionGetImageQuality(sessionId: sessionId);
  Future<void> sessionSetImageQuality({
    required UuidValue sessionId,
    required String value,
  }) => ffi.sessionSetImageQuality(sessionId: sessionId, value: value);
  Future<String?> sessionGetKeyboardMode({required UuidValue sessionId}) =>
      ffi.sessionGetKeyboardMode(sessionId: sessionId);
  Future<void> sessionSetKeyboardMode({
    required UuidValue sessionId,
    required String value,
  }) => ffi.sessionSetKeyboardMode(sessionId: sessionId, value: value);
  String? sessionGetReverseMouseWheelSync({required UuidValue sessionId}) =>
      ffi.sessionGetReverseMouseWheelSync(sessionId: sessionId);
  Future<void> sessionSetReverseMouseWheel({
    required UuidValue sessionId,
    required String value,
  }) => ffi.sessionSetReverseMouseWheel(sessionId: sessionId, value: value);
  String? sessionGetDisplaysAsIndividualWindows({
    required UuidValue sessionId,
  }) => ffi.sessionGetDisplaysAsIndividualWindows(sessionId: sessionId);
  Future<void> sessionSetDisplaysAsIndividualWindows({
    required UuidValue sessionId,
    required String value,
  }) => ffi.sessionSetDisplaysAsIndividualWindows(
    sessionId: sessionId,
    value: value,
  );
  String? sessionGetUseAllMyDisplaysForTheRemoteSession({
    required UuidValue sessionId,
  }) => ffi.sessionGetUseAllMyDisplaysForTheRemoteSession(sessionId: sessionId);
  Future<void> sessionSetUseAllMyDisplaysForTheRemoteSession({
    required UuidValue sessionId,
    required String value,
  }) => ffi.sessionSetUseAllMyDisplaysForTheRemoteSession(
    sessionId: sessionId,
    value: value,
  );
  Future<Int32List?> sessionGetCustomImageQuality({
    required UuidValue sessionId,
  }) => ffi.sessionGetCustomImageQuality(sessionId: sessionId);
  bool sessionIsKeyboardModeSupported({
    required UuidValue sessionId,
    required String mode,
  }) => ffi.sessionIsKeyboardModeSupported(sessionId: sessionId, mode: mode);
  Future<void> sessionSetCustomImageQuality({
    required UuidValue sessionId,
    required int value,
  }) => ffi.sessionSetCustomImageQuality(sessionId: sessionId, value: value);
  Future<void> sessionSetCustomFps({
    required UuidValue sessionId,
    required int fps,
  }) => ffi.sessionSetCustomFps(sessionId: sessionId, fps: fps);
  Future<int?> sessionGetTrackpadSpeed({required UuidValue sessionId}) =>
      ffi.sessionGetTrackpadSpeed(sessionId: sessionId);
  Future<void> sessionSetTrackpadSpeed({
    required UuidValue sessionId,
    required int value,
  }) => ffi.sessionSetTrackpadSpeed(sessionId: sessionId, value: value);
  Future<void> sessionLockScreen({required UuidValue sessionId}) =>
      ffi.sessionLockScreen(sessionId: sessionId);
  Future<void> sessionCtrlAltDel({required UuidValue sessionId}) =>
      ffi.sessionCtrlAltDel(sessionId: sessionId);
  Future<void> sessionSwitchDisplay({
    required bool isDesktop,
    required UuidValue sessionId,
    required List<int> value,
  }) => ffi.sessionSwitchDisplay(
    isDesktop: isDesktop,
    sessionId: sessionId,
    value: value,
  );
  Future<void> sessionHandleFlutterKeyEvent({
    required UuidValue sessionId,
    required String character,
    required int usbHid,
    required int lockModes,
    required bool downOrUp,
  }) => ffi.sessionHandleFlutterKeyEvent(
    sessionId: sessionId,
    character: character,
    usbHid: usbHid,
    lockModes: lockModes,
    downOrUp: downOrUp,
  );
  Future<void> sessionHandleFlutterRawKeyEvent({
    required UuidValue sessionId,
    required String name,
    required int platformCode,
    required int positionCode,
    required int lockModes,
    required bool downOrUp,
  }) => ffi.sessionHandleFlutterRawKeyEvent(
    sessionId: sessionId,
    name: name,
    platformCode: platformCode,
    positionCode: positionCode,
    lockModes: lockModes,
    downOrUp: downOrUp,
  );
  void sessionEnterOrLeave({
    required UuidValue sessionId,
    required bool enter,
  }) => ffi.sessionEnterOrLeave(sessionId: sessionId, enter: enter);
  Future<void> sessionInputKey({
    required UuidValue sessionId,
    required String name,
    required bool down,
    required bool press,
    required bool alt,
    required bool ctrl,
    required bool shift,
    required bool command,
  }) => ffi.sessionInputKey(
    sessionId: sessionId,
    name: name,
    down: down,
    press: press,
    alt: alt,
    ctrl: ctrl,
    shift: shift,
    command: command,
  );
  Future<void> sessionInputString({
    required UuidValue sessionId,
    required String value,
  }) => ffi.sessionInputString(sessionId: sessionId, value: value);
  Future<void> sessionSendChat({
    required UuidValue sessionId,
    required String text,
  }) => ffi.sessionSendChat(sessionId: sessionId, text: text);
  Future<void> sessionOpenTerminal({
    required UuidValue sessionId,
    required int terminalId,
    required int rows,
    required int cols,
  }) => ffi.sessionOpenTerminal(
    sessionId: sessionId,
    terminalId: terminalId,
    rows: rows,
    cols: cols,
  );
  Future<void> sessionSendTerminalInput({
    required UuidValue sessionId,
    required int terminalId,
    required String data,
  }) => ffi.sessionSendTerminalInput(
    sessionId: sessionId,
    terminalId: terminalId,
    data: data,
  );
  Future<void> sessionResizeTerminal({
    required UuidValue sessionId,
    required int terminalId,
    required int rows,
    required int cols,
  }) => ffi.sessionResizeTerminal(
    sessionId: sessionId,
    terminalId: terminalId,
    rows: rows,
    cols: cols,
  );
  Future<void> sessionCloseTerminal({
    required UuidValue sessionId,
    required int terminalId,
  }) => ffi.sessionCloseTerminal(sessionId: sessionId, terminalId: terminalId);
  Future<void> sessionPeerOption({
    required UuidValue sessionId,
    required String name,
    required String value,
  }) => ffi.sessionPeerOption(sessionId: sessionId, name: name, value: value);
  Future<String> sessionGetPeerOption({
    required UuidValue sessionId,
    required String name,
  }) => ffi.sessionGetPeerOption(sessionId: sessionId, name: name);
  Future<void> sessionInputOsPassword({
    required UuidValue sessionId,
    required String value,
  }) => ffi.sessionInputOsPassword(sessionId: sessionId, value: value);
  Future<void> sessionReadRemoteDir({
    required UuidValue sessionId,
    required String path,
    required bool includeHidden,
  }) => ffi.sessionReadRemoteDir(
    sessionId: sessionId,
    path: path,
    includeHidden: includeHidden,
  );
  Future<void> sessionSendFiles({
    required UuidValue sessionId,
    required int actId,
    required String path,
    required String to,
    required int fileNum,
    required bool includeHidden,
    required bool isRemote,
    required bool isDir,
  }) => ffi.sessionSendFiles(
    sessionId: sessionId,
    actId: actId,
    path: path,
    to: to,
    fileNum: fileNum,
    includeHidden: includeHidden,
    isRemote: isRemote,
    isDir: isDir,
  );
  Future<void> sessionSetConfirmOverrideFile({
    required UuidValue sessionId,
    required int actId,
    required int fileNum,
    required bool needOverride,
    required bool remember,
    required bool isUpload,
  }) => ffi.sessionSetConfirmOverrideFile(
    sessionId: sessionId,
    actId: actId,
    fileNum: fileNum,
    needOverride: needOverride,
    remember: remember,
    isUpload: isUpload,
  );
  Future<void> sessionRemoveFile({
    required UuidValue sessionId,
    required int actId,
    required String path,
    required int fileNum,
    required bool isRemote,
  }) => ffi.sessionRemoveFile(
    sessionId: sessionId,
    actId: actId,
    path: path,
    fileNum: fileNum,
    isRemote: isRemote,
  );
  Future<void> sessionReadDirToRemoveRecursive({
    required UuidValue sessionId,
    required int actId,
    required String path,
    required bool isRemote,
    required bool showHidden,
  }) => ffi.sessionReadDirToRemoveRecursive(
    sessionId: sessionId,
    actId: actId,
    path: path,
    isRemote: isRemote,
    showHidden: showHidden,
  );
  Future<void> sessionRemoveAllEmptyDirs({
    required UuidValue sessionId,
    required int actId,
    required String path,
    required bool isRemote,
  }) => ffi.sessionRemoveAllEmptyDirs(
    sessionId: sessionId,
    actId: actId,
    path: path,
    isRemote: isRemote,
  );
  Future<void> sessionCancelJob({
    required UuidValue sessionId,
    required int actId,
  }) => ffi.sessionCancelJob(sessionId: sessionId, actId: actId);
  Future<void> sessionCreateDir({
    required UuidValue sessionId,
    required int actId,
    required String path,
    required bool isRemote,
  }) => ffi.sessionCreateDir(
    sessionId: sessionId,
    actId: actId,
    path: path,
    isRemote: isRemote,
  );
  Future<String> sessionReadLocalDirSync({
    required UuidValue sessionId,
    required String path,
    required bool showHidden,
  }) => ffi.sessionReadLocalDirSync(
    sessionId: sessionId,
    path: path,
    showHidden: showHidden,
  );
  Future<String> sessionReadLocalEmptyDirsRecursiveSync({
    required UuidValue sessionId,
    required String path,
    required bool includeHidden,
  }) => ffi.sessionReadLocalEmptyDirsRecursiveSync(
    sessionId: sessionId,
    path: path,
    includeHidden: includeHidden,
  );
  Future<void> sessionReadRemoteEmptyDirsRecursiveSync({
    required UuidValue sessionId,
    required String path,
    required bool includeHidden,
  }) => ffi.sessionReadRemoteEmptyDirsRecursiveSync(
    sessionId: sessionId,
    path: path,
    includeHidden: includeHidden,
  );
  Future<String> sessionGetPlatform({
    required UuidValue sessionId,
    required bool isRemote,
  }) => ffi.sessionGetPlatform(sessionId: sessionId, isRemote: isRemote);
  Future<void> sessionLoadLastTransferJobs({required UuidValue sessionId}) =>
      ffi.sessionLoadLastTransferJobs(sessionId: sessionId);
  Future<void> sessionAddJob({
    required UuidValue sessionId,
    required int actId,
    required String path,
    required String to,
    required int fileNum,
    required bool includeHidden,
    required bool isRemote,
  }) => ffi.sessionAddJob(
    sessionId: sessionId,
    actId: actId,
    path: path,
    to: to,
    fileNum: fileNum,
    includeHidden: includeHidden,
    isRemote: isRemote,
  );
  Future<void> sessionResumeJob({
    required UuidValue sessionId,
    required int actId,
    required bool isRemote,
  }) => ffi.sessionResumeJob(
    sessionId: sessionId,
    actId: actId,
    isRemote: isRemote,
  );
  Future<void> sessionRenameFile({
    required UuidValue sessionId,
    required int actId,
    required String path,
    required String newName,
    required bool isRemote,
  }) => ffi.sessionRenameFile(
    sessionId: sessionId,
    actId: actId,
    path: path,
    newName: newName,
    isRemote: isRemote,
  );
  Future<void> sessionElevateDirect({required UuidValue sessionId}) =>
      ffi.sessionElevateDirect(sessionId: sessionId);
  Future<void> sessionElevateWithLogon({
    required UuidValue sessionId,
    required String username,
    required String password,
  }) => ffi.sessionElevateWithLogon(
    sessionId: sessionId,
    username: username,
    password: password,
  );
  Future<void> sessionSwitchSides({required UuidValue sessionId}) =>
      ffi.sessionSwitchSides(sessionId: sessionId);
  Future<void> sessionChangeResolution({
    required UuidValue sessionId,
    required int display,
    required int width,
    required int height,
  }) => ffi.sessionChangeResolution(
    sessionId: sessionId,
    display: display,
    width: width,
    height: height,
  );
  Future<void> sessionSetSize({
    required UuidValue sessionId,
    required int display,
    required int width,
    required int height,
  }) => ffi.sessionSetSize(
    sessionId: sessionId,
    display: display,
    width: width,
    height: height,
  );
  Future<void> sessionSendSelectedSessionId({
    required UuidValue sessionId,
    required String sid,
  }) => ffi.sessionSendSelectedSessionId(sessionId: sessionId, sid: sid);
  Future<List<String>> mainGetSoundInputs() => ffi.mainGetSoundInputs();
  String mainGetLoginDeviceInfo() => ffi.mainGetLoginDeviceInfo();
  Future<void> mainChangeId({required String newId}) =>
      ffi.mainChangeId(newId: newId);
  Future<String> mainGetAsyncStatus() => ffi.mainGetAsyncStatus();
  Future<String> mainGetHttpStatus({required String requestId}) =>
      ffi.mainGetHttpStatus(requestId: requestId);
  Future<void> mainCancelHttpRequest({required String requestId}) =>
      ffi.mainCancelHttpRequest(requestId: requestId);
  Future<String> mainGetOption({required String key}) =>
      ffi.mainGetOption(key: key);
  String mainGetOptionSync({required String key}) =>
      ffi.mainGetOptionSync(key: key);
  Future<String> mainGetError() => ffi.mainGetError();
  bool mainShowOption({required String key}) => ffi.mainShowOption(key: key);
  Future<void> mainSetOption({required String key, required String value}) =>
      ffi.mainSetOption(key: key, value: value);
  Future<String> mainGetOptions() => ffi.mainGetOptions();
  String mainGetOptionsSync() => ffi.mainGetOptionsSync();
  Future<void> mainSetOptions({required String json}) =>
      ffi.mainSetOptions(json: json);
  Future<String> mainTestIfValidServer({
    required String server,
    required bool testWithProxy,
  }) => ffi.mainTestIfValidServer(server: server, testWithProxy: testWithProxy);
  Future<void> mainSetSocks({
    required String proxy,
    required String username,
    required String password,
  }) => ffi.mainSetSocks(proxy: proxy, username: username, password: password);
  Future<bool> mainGetProxyStatus() => ffi.mainGetProxyStatus();
  Future<List<String>> mainGetSocks() => ffi.mainGetSocks();
  Future<String> mainGetAppName() => ffi.mainGetAppName();
  String mainGetAppNameSync() => ffi.mainGetAppNameSync();
  String mainUriPrefixSync() => ffi.mainUriPrefixSync();
  Future<String> mainGetLicense() => ffi.mainGetLicense();
  Future<String> mainGetVersion() => ffi.mainGetVersion();
  Future<List<String>> mainGetFav() => ffi.mainGetFav();
  Future<void> mainStoreFav({required List<String> favs}) =>
      ffi.mainStoreFav(favs: favs);
  String mainGetPeerSync({required String id}) => ffi.mainGetPeerSync(id: id);
  Future<String> mainGetLanPeers() => ffi.mainGetLanPeers();
  Future<String> mainGetConnectStatus() => ffi.mainGetConnectStatus();
  Future<void> mainCheckConnectStatus() => ffi.mainCheckConnectStatus();
  Future<bool> mainIsUsingPublicServer() => ffi.mainIsUsingPublicServer();
  Future<void> mainDiscover() => ffi.mainDiscover();
  Future<String> mainGetApiServer() => ffi.mainGetApiServer();
  Future<String> mainGetDeviceProof({
    required String purpose,
    required String id,
    required String uuid,
    required String token,
  }) => ffi.mainGetDeviceProof(
    purpose: purpose,
    id: id,
    uuid: uuid,
    token: token,
  );
  Future<String> mainDeployDevice({
    required String token,
    required String id,
  }) => ffi.mainDeployDevice(token: token, id: id);
  String mainResolveAvatarUrl({required String avatar}) =>
      ffi.mainResolveAvatarUrl(avatar: avatar);
  Future<String> mainHttpRequest({
    required String url,
    required String method,
    String? body,
    required String header,
  }) =>
      ffi.mainHttpRequest(url: url, method: method, body: body, header: header);
  Future<String> mainManagementOperationJournal({
    required String action,
    required String operationId,
    required String scope,
    required String createdAtMs,
  }) => ffi.mainManagementOperationJournal(
    action: action,
    operationId: operationId,
    scope: scope,
    createdAtMs: createdAtMs,
  );
  String mainGetLocalOption({required String key}) =>
      ffi.mainGetLocalOption(key: key);
  bool mainGetUseTextureRender() => ffi.mainGetUseTextureRender();
  String mainGetEnv({required String key}) => ffi.mainGetEnv(key: key);
  void mainSetEnv({required String key, String? value}) =>
      ffi.mainSetEnv(key: key, value: value);
  Future<void> mainSetLocalOption({
    required String key,
    required String value,
  }) => ffi.mainSetLocalOption(key: key, value: value);
  Future<String> mainHandleWaylandScreencastRestoreToken({
    required String key,
    required String value,
  }) => ffi.mainHandleWaylandScreencastRestoreToken(key: key, value: value);
  String mainGetInputSource() => ffi.mainGetInputSource();
  Future<void> mainSetInputSource({
    required UuidValue sessionId,
    required String value,
  }) => ffi.mainSetInputSource(sessionId: sessionId, value: value);
  bool mainSetCursorPosition({required int x, required int y}) =>
      ffi.mainSetCursorPosition(x: x, y: y);
  bool mainClipCursor({
    required int left,
    required int top,
    required int right,
    required int bottom,
    required bool enable,
  }) => ffi.mainClipCursor(
    left: left,
    top: top,
    right: right,
    bottom: bottom,
    enable: enable,
  );
  Future<String> mainGetMyId() => ffi.mainGetMyId();
  Future<String> mainGetUuid() => ffi.mainGetUuid();
  Future<String> mainGetPeerOption({required String id, required String key}) =>
      ffi.mainGetPeerOption(id: id, key: key);
  String mainGetPeerOptionSync({required String id, required String key}) =>
      ffi.mainGetPeerOptionSync(id: id, key: key);
  String mainGetPeerFlutterOptionSync({
    required String id,
    required String k,
  }) => ffi.mainGetPeerFlutterOptionSync(id: id, k: k);
  void mainSetPeerFlutterOptionSync({
    required String id,
    required String k,
    required String v,
  }) => ffi.mainSetPeerFlutterOptionSync(id: id, k: k, v: v);
  Future<void> mainSetPeerOption({
    required String id,
    required String key,
    required String value,
  }) => ffi.mainSetPeerOption(id: id, key: key, value: value);
  bool mainSetPeerOptionSync({
    required String id,
    required String key,
    required String value,
  }) => ffi.mainSetPeerOptionSync(id: id, key: key, value: value);
  Future<void> mainSetPeerAlias({required String id, required String alias}) =>
      ffi.mainSetPeerAlias(id: id, alias: alias);
  Future<String> mainGetNewStoredPeers() => ffi.mainGetNewStoredPeers();
  Future<void> mainForgetPassword({required String id}) =>
      ffi.mainForgetPassword(id: id);
  Future<bool> mainPeerHasPassword({required String id}) =>
      ffi.mainPeerHasPassword(id: id);
  Future<bool> mainPeerExists({required String id}) =>
      ffi.mainPeerExists(id: id);
  Future<void> mainLoadRecentPeers() => ffi.mainLoadRecentPeers();
  Future<String> mainLoadRecentPeersForAb({required String filter}) =>
      ffi.mainLoadRecentPeersForAb(filter: filter);
  Future<void> mainLoadFavPeers() => ffi.mainLoadFavPeers();
  Future<void> mainLoadLanPeers() => ffi.mainLoadLanPeers();
  Future<void> mainRemoveDiscovered({required String id}) =>
      ffi.mainRemoveDiscovered(id: id);
  Future<void> mainChangeTheme({required String dark}) =>
      ffi.mainChangeTheme(dark: dark);
  Future<void> mainChangeLanguage({required String lang}) =>
      ffi.mainChangeLanguage(lang: lang);
  String mainVideoSaveDirectory({required bool root}) =>
      ffi.mainVideoSaveDirectory(root: root);
  Future<void> mainSetUserDefaultOption({
    required String key,
    required String value,
  }) => ffi.mainSetUserDefaultOption(key: key, value: value);
  String mainGetUserDefaultOption({required String key}) =>
      ffi.mainGetUserDefaultOption(key: key);
  Future<String> mainHandleRelayId({required String id}) =>
      ffi.mainHandleRelayId(id: id);
  bool mainIsOptionFixed({required String key}) =>
      ffi.mainIsOptionFixed(key: key);
  String mainGetMainDisplay() => ffi.mainGetMainDisplay();
  String mainGetDisplays() => ffi.mainGetDisplays();
  Future<void> sessionAddPortForward({
    required UuidValue sessionId,
    required int localPort,
    required String remoteHost,
    required int remotePort,
  }) => ffi.sessionAddPortForward(
    sessionId: sessionId,
    localPort: localPort,
    remoteHost: remoteHost,
    remotePort: remotePort,
  );
  Future<void> sessionRemovePortForward({
    required UuidValue sessionId,
    required int localPort,
  }) =>
      ffi.sessionRemovePortForward(sessionId: sessionId, localPort: localPort);
  Future<void> sessionNewRdp({required UuidValue sessionId}) =>
      ffi.sessionNewRdp(sessionId: sessionId);
  Future<void> sessionRequestVoiceCall({required UuidValue sessionId}) =>
      ffi.sessionRequestVoiceCall(sessionId: sessionId);
  Future<void> sessionCloseVoiceCall({required UuidValue sessionId}) =>
      ffi.sessionCloseVoiceCall(sessionId: sessionId);
  String? sessionGetConnToken({required UuidValue sessionId}) =>
      ffi.sessionGetConnToken(sessionId: sessionId);
  Future<void> cmHandleIncomingVoiceCall({
    required int id,
    required bool accept,
  }) => ffi.cmHandleIncomingVoiceCall(id: id, accept: accept);
  Future<void> cmCloseVoiceCall({required int id}) =>
      ffi.cmCloseVoiceCall(id: id);
  Future<void> setVoiceCallInputDevice({
    required bool isCm,
    required String device,
  }) => ffi.setVoiceCallInputDevice(isCm: isCm, device: device);
  Future<String> getVoiceCallInputDevice({required bool isCm}) =>
      ffi.getVoiceCallInputDevice(isCm: isCm);
  Future<String> mainGetLastRemoteId() => ffi.mainGetLastRemoteId();
  Future<String> mainGetHomeDir() => ffi.mainGetHomeDir();
  Future<String> mainGetLangs() => ffi.mainGetLangs();
  Future<String> mainGetTemporaryPassword() => ffi.mainGetTemporaryPassword();
  Future<bool> mainSetPermanentPasswordWithResult({required String password}) =>
      ffi.mainSetPermanentPasswordWithResult(password: password);
  Future<String> mainGetFingerprint() => ffi.mainGetFingerprint();
  Future<String> cmGetClientsState() => ffi.cmGetClientsState();
  Future<String?> cmCheckClientsLength({required int length}) =>
      ffi.cmCheckClientsLength(length: length);
  Future<int> cmGetClientsLength() => ffi.cmGetClientsLength();
  Future<void> mainInit({
    required String appDir,
    required String customClientConfig,
  }) => ffi.mainInit(appDir: appDir, customClientConfig: customClientConfig);
  Future<void> mainDeviceId({required String id}) => ffi.mainDeviceId(id: id);
  Future<void> mainDeviceName({required String name}) =>
      ffi.mainDeviceName(name: name);
  Future<void> mainRemovePeer({required String id}) =>
      ffi.mainRemovePeer(id: id);
  bool mainHasHwcodec() => ffi.mainHasHwcodec();
  bool mainHasVram() => ffi.mainHasVram();
  String mainSupportedHwdecodings() => ffi.mainSupportedHwdecodings();
  Future<bool> mainIsRoot() => ffi.mainIsRoot();
  int getDoubleClickTime() => ffi.getDoubleClickTime();
  Future<void> mainStartDbusServer() => ffi.mainStartDbusServer();
  Future<void> mainSaveAb({required String json}) => ffi.mainSaveAb(json: json);
  Future<void> mainClearAb() => ffi.mainClearAb();
  Future<String> mainLoadAb() => ffi.mainLoadAb();
  Future<void> mainSaveGroup({required String json}) =>
      ffi.mainSaveGroup(json: json);
  Future<void> mainClearGroup() => ffi.mainClearGroup();
  Future<String> mainLoadGroup() => ffi.mainLoadGroup();
  Future<void> sessionSendPointer({
    required UuidValue sessionId,
    required String msg,
  }) => ffi.sessionSendPointer(sessionId: sessionId, msg: msg);
  Future<void> sessionSendMouse({
    required UuidValue sessionId,
    required String msg,
  }) => ffi.sessionSendMouse(sessionId: sessionId, msg: msg);
  Future<void> sessionRestartRemoteDevice({required UuidValue sessionId}) =>
      ffi.sessionRestartRemoteDevice(sessionId: sessionId);
  String sessionGetAuditServerSync({
    required UuidValue sessionId,
    required String typ,
  }) => ffi.sessionGetAuditServerSync(sessionId: sessionId, typ: typ);
  Future<void> sessionSendNote({
    required UuidValue sessionId,
    required String note,
  }) => ffi.sessionSendNote(sessionId: sessionId, note: note);
  String sessionGetLastAuditNote({required UuidValue sessionId}) =>
      ffi.sessionGetLastAuditNote(sessionId: sessionId);
  Future<void> sessionSetAuditGuid({
    required UuidValue sessionId,
    required String guid,
  }) => ffi.sessionSetAuditGuid(sessionId: sessionId, guid: guid);
  String sessionGetAuditGuid({required UuidValue sessionId}) =>
      ffi.sessionGetAuditGuid(sessionId: sessionId);
  String sessionGetConnSessionId({required UuidValue sessionId}) =>
      ffi.sessionGetConnSessionId(sessionId: sessionId);
  Future<String> sessionAlternativeCodecs({required UuidValue sessionId}) =>
      ffi.sessionAlternativeCodecs(sessionId: sessionId);
  Future<void> sessionChangePreferCodec({required UuidValue sessionId}) =>
      ffi.sessionChangePreferCodec(sessionId: sessionId);
  Future<void> sessionOnWaitingForImageDialogShow({
    required UuidValue sessionId,
  }) => ffi.sessionOnWaitingForImageDialogShow(sessionId: sessionId);
  Future<void> sessionToggleVirtualDisplay({
    required UuidValue sessionId,
    required int index,
    required bool on,
  }) => ffi.sessionToggleVirtualDisplay(
    sessionId: sessionId,
    index: index,
    on_: on,
  );
  Future<void> sessionPrinterResponse({
    required UuidValue sessionId,
    required int id,
    required String path,
    required String printerName,
  }) => ffi.sessionPrinterResponse(
    sessionId: sessionId,
    id: id,
    path: path,
    printerName: printerName,
  );
  Future<void> mainSetHomeDir({required String home}) =>
      ffi.mainSetHomeDir(home: home);
  String mainGetDataDirIos({required String appDir}) =>
      ffi.mainGetDataDirIos(appDir: appDir);
  Future<void> mainStopService() => ffi.mainStopService();
  Future<void> mainStartService() => ffi.mainStartService();
  Future<void> mainUpdateTemporaryPassword() =>
      ffi.mainUpdateTemporaryPassword();
  Future<bool> mainCheckSuperUserPermission() =>
      ffi.mainCheckSuperUserPermission();
  String mainGetUnlockPin() => ffi.mainGetUnlockPin();
  String mainSetUnlockPin({required String pin}) =>
      ffi.mainSetUnlockPin(pin: pin);
  Future<void> mainCheckMouseTime() => ffi.mainCheckMouseTime();
  Future<double> mainGetMouseTime() => ffi.mainGetMouseTime();
  Future<void> mainWol({required String id}) => ffi.mainWol(id: id);
  Future<void> mainCreateShortcut({required String id}) =>
      ffi.mainCreateShortcut(id: id);
  Future<void> cmSendChat({required int connId, required String msg}) =>
      ffi.cmSendChat(connId: connId, msg: msg);
  Future<void> cmLoginRes({required int connId, required bool res}) =>
      ffi.cmLoginRes(connId: connId, res: res);
  Future<void> cmCloseConnection({required int connId}) =>
      ffi.cmCloseConnection(connId: connId);
  Future<void> cmRemoveDisconnectedConnection({required int connId}) =>
      ffi.cmRemoveDisconnectedConnection(connId: connId);
  Future<void> cmCheckClickTime({required int connId}) =>
      ffi.cmCheckClickTime(connId: connId);
  Future<double> cmGetClickTime() => ffi.cmGetClickTime();
  Future<void> cmSwitchPermission({
    required int connId,
    required String name,
    required bool enabled,
  }) => ffi.cmSwitchPermission(connId: connId, name: name, enabled: enabled);
  bool cmCanElevate() => ffi.cmCanElevate();
  Future<void> cmElevatePortable({required int connId}) =>
      ffi.cmElevatePortable(connId: connId);
  Future<void> cmSwitchBack({required int connId}) =>
      ffi.cmSwitchBack(connId: connId);
  Future<String> cmGetConfig({required String name}) =>
      ffi.cmGetConfig(name: name);
  Future<String> mainGetBuildDate() => ffi.mainGetBuildDate();
  String translate({required String name, required String locale}) =>
      ffi.translate(name: name, locale: locale);
  int sessionGetRgbaSize({
    required UuidValue sessionId,
    required int display,
  }) => ffi.sessionGetRgbaSize(sessionId: sessionId, display: display);
  void sessionNextRgba({required UuidValue sessionId, required int display}) =>
      ffi.sessionNextRgba(sessionId: sessionId, display: display);
  void sessionRegisterPixelbufferTexture({
    required UuidValue sessionId,
    required int display,
    required int ptr,
  }) => ffi.sessionRegisterPixelbufferTexture(
    sessionId: sessionId,
    display: display,
    ptr: ptr,
  );
  void sessionRegisterGpuTexture({
    required UuidValue sessionId,
    required int display,
    required int ptr,
  }) => ffi.sessionRegisterGpuTexture(
    sessionId: sessionId,
    display: display,
    ptr: ptr,
  );
  Future<void> queryOnlines({required List<String> ids}) =>
      ffi.queryOnlines(ids: ids);
  int versionToNumber({required String v}) => ffi.versionToNumber(v: v);
  Future<bool> optionSynced() => ffi.optionSynced();
  bool mainIsInstalled() => ffi.mainIsInstalled();
  void mainInitInputSource() => ffi.mainInitInputSource();
  bool mainIsInstalledLowerVersion() => ffi.mainIsInstalledLowerVersion();
  bool mainIsInstalledDaemon({required bool prompt}) =>
      ffi.mainIsInstalledDaemon(prompt: prompt);
  bool mainIsProcessTrusted({required bool prompt}) =>
      ffi.mainIsProcessTrusted(prompt: prompt);
  bool mainIsCanScreenRecording({required bool prompt}) =>
      ffi.mainIsCanScreenRecording(prompt: prompt);
  bool mainIsCanInputMonitoring({required bool prompt}) =>
      ffi.mainIsCanInputMonitoring(prompt: prompt);
  bool mainIsShareRdp() => ffi.mainIsShareRdp();
  Future<void> mainSetShareRdp({required bool enable}) =>
      ffi.mainSetShareRdp(enable: enable);
  bool mainGotoInstall() => ffi.mainGotoInstall();
  bool mainUpdateMe() => ffi.mainUpdateMe();
  Future<void> setCurSessionId({required UuidValue sessionId}) =>
      ffi.setCurSessionId(sessionId: sessionId);
  bool installShowRunWithoutInstall() => ffi.installShowRunWithoutInstall();
  Future<void> installRunWithoutInstall() => ffi.installRunWithoutInstall();
  Future<void> installInstallMe({
    required String options,
    required String path,
  }) => ffi.installInstallMe(options: options, path: path);
  String installInstallPath() => ffi.installInstallPath();
  String installInstallOptions() => ffi.installInstallOptions();
  Future<void> mainAccountAuth({
    required String op,
    required bool rememberMe,
  }) => ffi.mainAccountAuth(op: op, rememberMe: rememberMe);
  Future<void> mainAccountAuthCancel() => ffi.mainAccountAuthCancel();
  Future<String> mainAccountAuthResult() => ffi.mainAccountAuthResult();
  Future<void> accountLogout() => ffi.accountLogout();
  Future<void> mainAccountLogout() => ffi.mainAccountLogout();
  String mainCreateCapabilityHandle({
    required String peerId,
    required String secret,
  }) => ffi.mainCreateCapabilityHandle(peerId: peerId, secret: secret);
  String mainConsumeCapabilityHandle({
    required String peerId,
    required String handle,
  }) => ffi.mainConsumeCapabilityHandle(peerId: peerId, handle: handle);
  Future<void> mainOnMainWindowClose() => ffi.mainOnMainWindowClose();
  bool mainCurrentIsWayland() => ffi.mainCurrentIsWayland();
  bool mainIsLoginWayland() => ffi.mainIsLoginWayland();
  bool mainHideDock() => ffi.mainHideDock();
  bool mainHasFileClipboard() => ffi.mainHasFileClipboard();
  bool mainHasGpuTextureRender() => ffi.mainHasGpuTextureRender();
  Future<void> cmInit() => ffi.cmInit();
  Future<void> mainStartIpcUrlServer() => ffi.mainStartIpcUrlServer();
  Future<void> mainTestWallpaper({required int second}) =>
      ffi.mainTestWallpaper(second: second);
  Future<bool> mainSupportRemoveWallpaper() => ffi.mainSupportRemoveWallpaper();
  bool isIncomingOnly() => ffi.isIncomingOnly();
  bool isOutgoingOnly() => ffi.isOutgoingOnly();
  bool isCustomClient() => ffi.isCustomClient();
  bool isDisableSettings() => ffi.isDisableSettings();
  bool isDisableAb() => ffi.isDisableAb();
  bool isDisableAccount() => ffi.isDisableAccount();
  bool isDisableGroupPanel() => ffi.isDisableGroupPanel();
  bool isDisableInstallation() => ffi.isDisableInstallation();
  Future<bool> isPresetPassword() => ffi.isPresetPassword();
  bool isPresetPasswordMobileOnly() => ffi.isPresetPasswordMobileOnly();
  Future<void> sendUrlScheme({required String url}) =>
      ffi.sendUrlScheme(url: url);
  Future<void> pluginEvent({
    required String id,
    required String peer,
    required List<int> event,
  }) => ffi.pluginEvent(id: id, peer: peer, event: event);
  Stream<EventToUI> pluginRegisterEventStream({required String id}) =>
      ffi.pluginRegisterEventStream(id: id);
  String? pluginGetSessionOption({
    required String id,
    required String peer,
    required String key,
  }) => ffi.pluginGetSessionOption(id: id, peer: peer, key: key);
  Future<void> pluginSetSessionOption({
    required String id,
    required String peer,
    required String key,
    required String value,
  }) => ffi.pluginSetSessionOption(id: id, peer: peer, key: key, value: value);
  String? pluginGetSharedOption({required String id, required String key}) =>
      ffi.pluginGetSharedOption(id: id, key: key);
  Future<void> pluginSetSharedOption({
    required String id,
    required String key,
    required String value,
  }) => ffi.pluginSetSharedOption(id: id, key: key, value: value);
  Future<void> pluginReload({required String id}) => ffi.pluginReload(id: id);
  void pluginEnable({required String id, required bool v}) =>
      ffi.pluginEnable(id: id, v: v);
  bool pluginIsEnabled({required String id}) => ffi.pluginIsEnabled(id: id);
  bool pluginFeatureIsEnabled() => ffi.pluginFeatureIsEnabled();
  Future<void> pluginSyncUi({required String syncTo}) =>
      ffi.pluginSyncUi(syncTo: syncTo);
  Future<void> pluginListReload() => ffi.pluginListReload();
  Future<void> pluginInstall({required String id, required bool b}) =>
      ffi.pluginInstall(id: id, b: b);
  bool isSupportMultiUiSession({required String version}) =>
      ffi.isSupportMultiUiSession(version: version);
  bool isSelinuxEnforcing() => ffi.isSelinuxEnforcing();
  String mainDefaultPrivacyModeImpl() => ffi.mainDefaultPrivacyModeImpl();
  String mainSupportedPrivacyModeImpls() => ffi.mainSupportedPrivacyModeImpls();
  String mainSupportedInputSource() => ffi.mainSupportedInputSource();
  Future<String> mainGenerate2Fa() => ffi.mainGenerate2Fa();
  Future<bool> mainVerify2Fa({required String code}) =>
      ffi.mainVerify2Fa(code: code);
  bool mainHasValid2FaSync() => ffi.mainHasValid2FaSync();
  Future<String> mainVerifyBot({required String token}) =>
      ffi.mainVerifyBot(token: token);
  bool mainHasValidBotSync() => ffi.mainHasValidBotSync();
  String mainGetHardOption({required String key}) =>
      ffi.mainGetHardOption(key: key);
  String mainGetBuildinOption({required String key}) =>
      ffi.mainGetBuildinOption(key: key);
  Future<void> mainCheckHwcodec() => ffi.mainCheckHwcodec();
  Future<String> mainGetTrustedDevices() => ffi.mainGetTrustedDevices();
  Future<void> mainRemoveTrustedDevices({required String json}) =>
      ffi.mainRemoveTrustedDevices(json: json);
  Future<void> mainClearTrustedDevices() => ffi.mainClearTrustedDevices();
  int mainMaxEncryptLen() => ffi.mainMaxEncryptLen();
  Future<void> sessionRequestNewDisplayInitMsgs({
    required UuidValue sessionId,
    required int display,
  }) => ffi.sessionRequestNewDisplayInitMsgs(
    sessionId: sessionId,
    display: display,
  );
  bool mainAudioSupportLoopback() => ffi.mainAudioSupportLoopback();
  String mainGetPrinterNames() => ffi.mainGetPrinterNames();
  Future<String> mainGetCommon({required String key}) =>
      ffi.mainGetCommon(key: key);
  String mainGetCommonSync({required String key}) =>
      ffi.mainGetCommonSync(key: key);
  Future<void> mainSetCommon({required String key, required String value}) =>
      ffi.mainSetCommon(key: key, value: value);
  Future<void> sessionSetCommon({
    required UuidValue sessionId,
    required String key,
    required String value,
  }) => ffi.sessionSetCommon(sessionId: sessionId, key: key, value: value);
  String? sessionGetCommonSync({
    required UuidValue sessionId,
    required String key,
    required String param,
  }) => ffi.sessionGetCommonSync(sessionId: sessionId, key: key, param: param);
  Future<String?> sessionGetCommon({
    required UuidValue sessionId,
    required String key,
    required String param,
  }) => ffi.sessionGetCommon(sessionId: sessionId, key: key, param: param);
}
