import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/generated_bridge.dart';
import 'package:camellia_remote_app/models/model.dart';
import 'package:camellia_remote_app/models/platform_model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

class _FakeRustdeskImpl extends Fake implements RustdeskImpl {
  final Map<String, String> localOptions = {};
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
  Future<bool> mainDisable2FaAndClearTrustedDevices() async => true;
  @override
  bool isDisableAb() => false;
  @override
  bool isDisableAccount() => false;
  @override
  bool isDisableGroupPanel() => false;
  @override
  bool mainIsOptionFixed({required String key}) => false;
  @override
  String mainUriPrefixSync() => 'camellia-remote://';
  @override
  String mainGetOptionSync({required String key}) => '';
  @override
  Future<String> mainGetOption({required String key}) async => '';
  @override
  Future<void> mainSetOption({
    required String key,
    required String value,
  }) async {}
  @override
  Future<void> sessionClose({required UuidValue sessionId}) async {}
  @override
  Future<void> stopGlobalEventStream({required String appType}) async {}
  @override
  Future<String> mainGetConnectStatus() async => '{"status_num": 1}';
  @override
  String getLocalFlutterOption({required String k}) => '';
  @override
  Future<void> setLocalFlutterOption({
    required String k,
    required String v,
  }) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    isTest = true;
    platformFFI.ffiBind = _FakeRustdeskImpl();
  });

  group('Batch 41 Recording and Auth UI Tests', () {
    test('RecordingModel handles status and reactive error notifications', () {
      final ffi = FFI(null, isGlobal: true);
      final model = RecordingModel(WeakReference(ffi));
      expect(model.start, isFalse);

      var notified = 0;
      model.addListener(() {
        notified++;
      });

      // 1. Start recording successfully
      model.updateStatus(true);
      expect(model.start, isTrue);
      expect(notified, 1);

      // 2. Stop recording due to failure
      model.updateStatus(false, error: 'Disk full or write permission denied');
      expect(model.start, isFalse);
      expect(notified, 2);
    });

    test(
      'Flutter supportedLocales advertises explicit Hans and Hant script locales',
      () {
        final tags = supportedLocales.map((l) => l.toLanguageTag()).toSet();
        expect(tags, contains('zh-Hans'));
        expect(tags, contains('zh-Hant'));
        expect(tags, contains('en-US'));
        expect(tags, contains('zh-CN'));
        expect(tags, contains('zh-TW'));
      },
    );

    test('CamelliaTypography resolves script code priority strictly', () {
      expect(
        CamelliaTypography.resolve(
          savedLanguage: '',
          systemLocale: const Locale.fromSubtags(
            languageCode: 'zh',
            scriptCode: 'Hans',
            countryCode: 'TW',
          ),
        ),
        CamelliaLanguage.simplifiedChinese,
      );

      expect(
        CamelliaTypography.resolve(
          savedLanguage: '',
          systemLocale: const Locale.fromSubtags(
            languageCode: 'zh',
            scriptCode: 'Hant',
            countryCode: 'CN',
          ),
        ),
        CamelliaLanguage.traditionalChinese,
      );

      expect(
        CamelliaTypography.resolve(
          savedLanguage: '',
          systemLocale: const Locale('en', 'US'),
        ),
        CamelliaLanguage.english,
      );
    });
  });
}
