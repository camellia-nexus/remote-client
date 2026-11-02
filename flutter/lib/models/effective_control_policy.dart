import '../common.dart';
import '../consts.dart';
import 'model.dart';

/// Unified control policy binding session generation, authorization capabilities,
/// operational view-only mode, connection types, and platform features.
class EffectiveControlPolicy {
  final int generation;
  final bool keyboardPerm;
  final bool viewOnly;
  final bool isViewCamera;
  final ConnType connType;
  final Map<String, dynamic> permissions;
  final PeerInfo pi;

  const EffectiveControlPolicy({
    required this.generation,
    required this.keyboardPerm,
    required this.viewOnly,
    required this.isViewCamera,
    required this.connType,
    required this.permissions,
    required this.pi,
  });

  bool get isDefaultConn => connType == ConnType.defaultConn;

  /// Fundamental remote control gate: default connection, host authorization granted,
  /// view-only operational preference disabled, and not a view-camera session.
  bool get canControlRemote =>
      isDefaultConn && keyboardPerm && !viewOnly && !isViewCamera;

  bool get canRequestElevation =>
      canControlRemote &&
      permissions['elevation'] != false &&
      pi.platform == kPeerPlatformWindows;

  bool get canBlockUserInput =>
      canControlRemote &&
      permissions['block_input'] != false &&
      pi.platform == kPeerPlatformWindows;

  bool get canSendOsPassword => canControlRemote;

  bool get canSendClipboardKeystrokes =>
      canControlRemote && pi.platform != kPeerPlatformAndroid;

  bool get canLockScreen => canControlRemote;

  bool get canCtrlAltDel =>
      canControlRemote &&
      (pi.platform == kPeerPlatformLinux || pi.sasEnabled);

  bool get canSwitchSides =>
      canControlRemote &&
      pi.platform != kPeerPlatformAndroid &&
      versionCmp(pi.version, '1.2.0') >= 0;
}
