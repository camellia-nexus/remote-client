import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/generated_bridge.dart';
import 'package:camellia_remote_app/models/model.dart';
import 'package:camellia_remote_app/models/platform_model.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

class _FakeRustdeskImplForClipboard extends Fake implements RustdeskImpl {
  final Map<String, bool> toggleOptions = {};

  @override
  bool sessionGetToggleOptionSync({
    required UuidValue sessionId,
    required String arg,
  }) {
    return toggleOptions['${sessionId.uuid}:$arg'] ?? false;
  }

  @override
  Future<void> sessionClose({required UuidValue sessionId}) async {}

  @override
  Future<void> stopGlobalEventStream({required String appType}) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeRustdeskImplForClipboard fakeBind;
  final List<String> clipboardLog = [];

  setUp(() {
    isTest = true;
    fakeBind = _FakeRustdeskImplForClipboard();
    platformFFI.ffiBind = fakeBind;
    clipboardLog.clear();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (
          MethodCall methodCall,
        ) async {
          if (methodCall.method == 'Clipboard.setData') {
            final text = methodCall.arguments['text'] as String?;
            if (text != null) {
              clipboardLog.add(text);
            }
            return null;
          }
          if (methodCall.method == 'Clipboard.getData') {
            return <String, dynamic>{'text': clipboardLog.lastOrNull ?? ''};
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  group('Batch 42 Clipboard Policy Enforcement (PRIV-008)', () {
    test('kOptionToggleDisableClipboard is canonically defined', () {
      expect(kOptionToggleDisableClipboard, equals('disable-clipboard'));
      expect(kOptionToggleViewOnly, equals('view-only'));
    });

    test(
      'Inbound clipboard event is ignored when view-only option is enabled',
      () async {
        final sessionId = UuidValue.fromString(
          '11111111-1111-1111-1111-111111111111',
        );
        fakeBind.toggleOptions['${sessionId.uuid}:$kOptionToggleViewOnly'] =
            true;
        fakeBind
                .toggleOptions['${sessionId.uuid}:$kOptionToggleDisableClipboard'] =
            false;

        final ffi = FFI(sessionId);
        final handler = ffi.ffiModel.startEventListener(sessionId, 'peer_test');

        await handler({
          'name': 'clipboard',
          'content': 'sensitive-remote-text-1',
        });

        expect(
          clipboardLog,
          isEmpty,
          reason: 'Clipboard must not be set when view-only is active',
        );
      },
    );

    test(
      'Inbound clipboard event is ignored when disable-clipboard option is enabled',
      () async {
        final sessionId = UuidValue.fromString(
          '22222222-2222-2222-2222-222222222222',
        );
        fakeBind.toggleOptions['${sessionId.uuid}:$kOptionToggleViewOnly'] =
            false;
        fakeBind
                .toggleOptions['${sessionId.uuid}:$kOptionToggleDisableClipboard'] =
            true;

        final ffi = FFI(sessionId);
        final handler = ffi.ffiModel.startEventListener(sessionId, 'peer_test');

        await handler({
          'name': 'clipboard',
          'content': 'sensitive-remote-text-2',
        });

        expect(
          clipboardLog,
          isEmpty,
          reason: 'Clipboard must not be set when disable-clipboard is active',
        );
      },
    );

    test(
      'Inbound clipboard event is written when both policies allow clipboard',
      () async {
        final sessionId = UuidValue.fromString(
          '33333333-3333-3333-3333-333333333333',
        );
        fakeBind.toggleOptions['${sessionId.uuid}:$kOptionToggleViewOnly'] =
            false;
        fakeBind
                .toggleOptions['${sessionId.uuid}:$kOptionToggleDisableClipboard'] =
            false;

        final ffi = FFI(sessionId);
        final handler = ffi.ffiModel.startEventListener(sessionId, 'peer_test');

        await handler({
          'name': 'clipboard',
          'content': 'allowed-remote-text-3',
        });

        expect(clipboardLog, equals(['allowed-remote-text-3']));
      },
    );
  });
}
