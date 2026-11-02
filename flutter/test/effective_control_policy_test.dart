import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/models/model.dart';

void main() {
  group('EffectiveControlPolicy Tests (PRIV-009)', () {
    test('canControlRemote requires defaultConn, keyboardPerm, !viewOnly, !isViewCamera', () {
      final pi = PeerInfo();
      pi.platform = kPeerPlatformWindows;

      // Fully authorized
      final policyActive = EffectiveControlPolicy(
        generation: 1,
        keyboardPerm: true,
        viewOnly: false,
        isViewCamera: false,
        connType: ConnType.defaultConn,
        permissions: {},
        pi: pi,
      );
      expect(policyActive.canControlRemote, isTrue);

      // View-only active
      final policyViewOnly = EffectiveControlPolicy(
        generation: 2,
        keyboardPerm: true,
        viewOnly: true,
        isViewCamera: false,
        connType: ConnType.defaultConn,
        permissions: {},
        pi: pi,
      );
      expect(policyViewOnly.canControlRemote, isFalse);

      // Keyboard permission false
      final policyNoKb = EffectiveControlPolicy(
        generation: 3,
        keyboardPerm: false,
        viewOnly: false,
        isViewCamera: false,
        connType: ConnType.defaultConn,
        permissions: {},
        pi: pi,
      );
      expect(policyNoKb.canControlRemote, isFalse);

      // Camera view
      final policyCamera = EffectiveControlPolicy(
        generation: 4,
        keyboardPerm: true,
        viewOnly: false,
        isViewCamera: true,
        connType: ConnType.defaultConn,
        permissions: {},
        pi: pi,
      );
      expect(policyCamera.canControlRemote, isFalse);

      // Non-default connection type (e.g. fileTransfer)
      final policyFileTransfer = EffectiveControlPolicy(
        generation: 5,
        keyboardPerm: true,
        viewOnly: false,
        isViewCamera: false,
        connType: ConnType.fileTransfer,
        permissions: {},
        pi: pi,
      );
      expect(policyFileTransfer.canControlRemote, isFalse);
    });

    test('canRequestElevation respects canControlRemote, Windows platform, and permission', () {
      final piWin = PeerInfo()..platform = kPeerPlatformWindows;
      final piLinux = PeerInfo()..platform = kPeerPlatformLinux;

      // Windows with elevation permission
      final winAllowed = EffectiveControlPolicy(
        generation: 1,
        keyboardPerm: true,
        viewOnly: false,
        isViewCamera: false,
        connType: ConnType.defaultConn,
        permissions: {'elevation': true},
        pi: piWin,
      );
      expect(winAllowed.canRequestElevation, isTrue);

      // Windows with elevation disabled
      final winDenied = EffectiveControlPolicy(
        generation: 2,
        keyboardPerm: true,
        viewOnly: false,
        isViewCamera: false,
        connType: ConnType.defaultConn,
        permissions: {'elevation': false},
        pi: piWin,
      );
      expect(winDenied.canRequestElevation, isFalse);

      // Non-Windows
      final linuxDenied = EffectiveControlPolicy(
        generation: 3,
        keyboardPerm: true,
        viewOnly: false,
        isViewCamera: false,
        connType: ConnType.defaultConn,
        permissions: {'elevation': true},
        pi: piLinux,
      );
      expect(linuxDenied.canRequestElevation, isFalse);

      // In view-only mode on Windows
      final winViewOnly = EffectiveControlPolicy(
        generation: 4,
        keyboardPerm: true,
        viewOnly: true,
        isViewCamera: false,
        connType: ConnType.defaultConn,
        permissions: {'elevation': true},
        pi: piWin,
      );
      expect(winViewOnly.canRequestElevation, isFalse);
    });

    test('canBlockUserInput respects canControlRemote, Windows platform, and permission', () {
      final piWin = PeerInfo()..platform = kPeerPlatformWindows;
      final piLinux = PeerInfo()..platform = kPeerPlatformLinux;

      final winAllowed = EffectiveControlPolicy(
        generation: 1,
        keyboardPerm: true,
        viewOnly: false,
        isViewCamera: false,
        connType: ConnType.defaultConn,
        permissions: {},
        pi: piWin,
      );
      expect(winAllowed.canBlockUserInput, isTrue);

      final winDenied = EffectiveControlPolicy(
        generation: 2,
        keyboardPerm: true,
        viewOnly: false,
        isViewCamera: false,
        connType: ConnType.defaultConn,
        permissions: {'block_input': false},
        pi: piWin,
      );
      expect(winDenied.canBlockUserInput, isFalse);

      final linuxDenied = EffectiveControlPolicy(
        generation: 3,
        keyboardPerm: true,
        viewOnly: false,
        isViewCamera: false,
        connType: ConnType.defaultConn,
        permissions: {},
        pi: piLinux,
      );
      expect(linuxDenied.canBlockUserInput, isFalse);
    });

    test('canSendClipboardKeystrokes disallows Android and requires canControlRemote', () {
      final piAndroid = PeerInfo()..platform = kPeerPlatformAndroid;
      final piLinux = PeerInfo()..platform = kPeerPlatformLinux;

      final linuxAllowed = EffectiveControlPolicy(
        generation: 1,
        keyboardPerm: true,
        viewOnly: false,
        isViewCamera: false,
        connType: ConnType.defaultConn,
        permissions: {},
        pi: piLinux,
      );
      expect(linuxAllowed.canSendClipboardKeystrokes, isTrue);

      final androidDenied = EffectiveControlPolicy(
        generation: 2,
        keyboardPerm: true,
        viewOnly: false,
        isViewCamera: false,
        connType: ConnType.defaultConn,
        permissions: {},
        pi: piAndroid,
      );
      expect(androidDenied.canSendClipboardKeystrokes, isFalse);
    });

    test('canCtrlAltDel requires canControlRemote and Linux or SAS enabled', () {
      final piLinux = PeerInfo()..platform = kPeerPlatformLinux;
      final piWinNoSas = PeerInfo()..platform = kPeerPlatformWindows..sasEnabled = false;
      final piWinWithSas = PeerInfo()..platform = kPeerPlatformWindows..sasEnabled = true;

      final linuxAllowed = EffectiveControlPolicy(
        generation: 1,
        keyboardPerm: true,
        viewOnly: false,
        isViewCamera: false,
        connType: ConnType.defaultConn,
        permissions: {},
        pi: piLinux,
      );
      expect(linuxAllowed.canCtrlAltDel, isTrue);

      final winNoSasDenied = EffectiveControlPolicy(
        generation: 2,
        keyboardPerm: true,
        viewOnly: false,
        isViewCamera: false,
        connType: ConnType.defaultConn,
        permissions: {},
        pi: piWinNoSas,
      );
      expect(winNoSasDenied.canCtrlAltDel, isFalse);

      final winWithSasAllowed = EffectiveControlPolicy(
        generation: 3,
        keyboardPerm: true,
        viewOnly: false,
        isViewCamera: false,
        connType: ConnType.defaultConn,
        permissions: {},
        pi: piWinWithSas,
      );
      expect(winWithSasAllowed.canCtrlAltDel, isTrue);
    });
  });
}
