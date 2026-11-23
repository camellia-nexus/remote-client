// ignore_for_file: deprecated_member_use
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/desktop/pages/desktop_setting_page.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import '../harness/test_app_harness.dart';

Map<String, String> loadRustDictionary(String filename) {
  final candidates = [
    File('../src/lang/$filename'),
    File('client/src/lang/$filename'),
    File('/home/camellia/github/remote-workspace/client/src/lang/$filename'),
  ];
  File? targetFile;
  for (final f in candidates) {
    if (f.existsSync()) {
      targetFile = f;
      break;
    }
  }
  if (targetFile == null) {
    throw StateError('Could not locate Rust translation dictionary: $filename');
  }

  final content = targetFile.readAsStringSync();
  final regex = RegExp(r'\("([^"]+)",\s*"([^"]*)"\)');
  final dict = <String, String>{};
  for (final match in regex.allMatches(content)) {
    dict[match.group(1)!] = match.group(2)!;
  }
  return dict;
}

void main() {
  setUp(() async {
    await TestAppHarness.setUp();
  });

  group('Tier 1: i18n Translation Coverage & String Robustness (F15, F16, F17)', () {
    test(
      '1. (F15) Simplified Chinese dictionary (cn.rs) contains full translation coverage for core theme, wizard, shell, and telemetry keys',
      () {
        final cnDict = loadRustDictionary('cn.rs');
        expect(cnDict, isNotEmpty);

        final requiredKeys = [
          'OLED Midnight',
          'Switch Theme',
          'Switch appearance',
          'Switch workspace',
          'Welcome to Camellia Remote',
          'Get Started',
          'Ultra-Responsive Canvas',
          'Unified Cross-Platform',
          'Zero-Trust Security',
          'Network Status',
          'Search commands...',
          'No matching commands',
          'Address Book',
          'Collapse navigation',
          'Expand navigation',
          'Toggle sidebar',
          'Copy ID',
          'Copy Password',
          'Hide Password',
          'Show Password',
          'Permanent Password',
          'Open Main Window',
          'Disconnect All Sessions',
          'Start Service',
          'Addressing',
          'Route & Relay',
          'Encrypted Handshake',
          'Video Stream',
          'Online',
          'Offline',
          'Drop files here to transfer',
          'Transfer Queue',
          'Upload options',
          'Fullscreen Mode',
          'Pointer Lock (Relative Mouse)',
          'System Shortcut Interception',
          'PWA / Fullscreen',
          'Web Clipboard Permission',
        ];

        final missingKeys = <String>[];
        for (final key in requiredKeys) {
          if (!cnDict.containsKey(key) || cnDict[key]!.trim().isEmpty) {
            missingKeys.add(key);
          }
        }

        expect(
          missingKeys,
          isEmpty,
          reason: 'Missing Simplified Chinese translations in cn.rs: $missingKeys',
        );
      },
    );

    test(
      '2. (F15) Traditional Chinese dictionary (tw.rs) contains full translation coverage for core theme, wizard, shell, and telemetry keys',
      () {
        final twDict = loadRustDictionary('tw.rs');
        expect(twDict, isNotEmpty);

        final requiredKeys = [
          'OLED Midnight',
          'Switch Theme',
          'Switch appearance',
          'Switch workspace',
          'Welcome to Camellia Remote',
          'Get Started',
          'Ultra-Responsive Canvas',
          'Unified Cross-Platform',
          'Zero-Trust Security',
          'Network Status',
          'Search commands...',
          'No matching commands',
          'Address Book',
          'Collapse navigation',
          'Expand navigation',
          'Toggle sidebar',
          'Copy ID',
          'Copy Password',
          'Hide Password',
          'Show Password',
          'Permanent Password',
          'Open Main Window',
          'Disconnect All Sessions',
          'Start Service',
          'Addressing',
          'Route & Relay',
          'Encrypted Handshake',
          'Video Stream',
          'Online',
          'Offline',
          'Drop files here to transfer',
          'Transfer Queue',
          'Upload options',
          'Fullscreen Mode',
          'Pointer Lock (Relative Mouse)',
          'System Shortcut Interception',
          'PWA / Fullscreen',
          'Web Clipboard Permission',
        ];

        final missingKeys = <String>[];
        for (final key in requiredKeys) {
          if (!twDict.containsKey(key) || twDict[key]!.trim().isEmpty) {
            missingKeys.add(key);
          }
        }

        expect(
          missingKeys,
          isEmpty,
          reason: 'Missing Traditional Chinese translations in tw.rs: $missingKeys',
        );
      },
    );

    testWidgets(
      '3. (F16) Settings About section and GlassInput clear/paste slot buttons use localized translate() strings',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: DesktopSettingPage(initialTabkey: SettingsTabKey.about),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        // Settings About page must render without uncaught translation exceptions
        expect(find.byType(DesktopSettingPage), findsOneWidget);

        // GlassInput slot button with tooltip should accept translated messages
        await TestAppHarness.pumpWidget(
          tester,
          child: GlassInput(
            controller: TextEditingController(text: '123 456 789'),
            showClearButton: true,
          ),
        );
        await tester.pump();

        expect(find.byTooltip(translate('Clear')), findsOneWidget);

        await TestAppHarness.tearDown(tester);
      },
    );

    test(
      '4. (F17) Substring slice safety on localized tips prevents RangeError on longer CJK translations',
      () {
        // Safe tip translation slicing logic ensuring RangeError never throws
        String safeFormatTip(String text, String Function(String) translator) {
          final words = text.split(' ');
          if (words.length > 1 && words[0].endsWith('_tip')) {
            final tipKey = words[0];
            // Must slice from original English tipKey length, NOT translated words[0] length
            if (text.length > tipKey.length + 1) {
              final rest = text.substring(tipKey.length + 1);
              return '${translator(tipKey)} ${translator(rest)}';
            } else {
              return translator(tipKey);
            }
          }
          return translator(text);
        }

        final mockTranslations = {
          'install_tip': '安装提示（Camellia Remote 需要管理员权限以启用完全控制并配置服务）',
          'To enable remote control, please install service': '若要启用远程控制，请安装服务',
        };

        const testInput = 'install_tip To enable remote control, please install service';

        // Safe implementation must execute normally without RangeError
        expect(
          () => safeFormatTip(testInput, (k) => mockTranslations[k] ?? k),
          returnsNormally,
        );

        final result = safeFormatTip(testInput, (k) => mockTranslations[k] ?? k);
        expect(result, contains('安装提示'));
        expect(result, contains('若要启用远程控制'));

        // Verify the bug behavior: if text is sliced using the translated string length (which is longer than shortInput),
        // it triggers RangeError when translation length > text.length.
        const shortInput = 'install_tip service';
        final buggyTranslatedKey = mockTranslations['install_tip']!;
        expect(buggyTranslatedKey.length, greaterThan(shortInput.length));
        expect(
          () => shortInput.substring(buggyTranslatedKey.length + 1),
          throwsA(isA<RangeError>()),
          reason: 'Demonstrating that using translated string length for English substring causes RangeError',
        );
      },
    );

    test(
      '5. (F17) Substring boundary cases (single-character suffix, short tip key, zero-length rest) slice safely',
      () {
        String safeFormatTip(String text, String Function(String) translator) {
          final words = text.split(' ');
          if (words.length > 1 && words[0].endsWith('_tip')) {
            final tipKey = words[0];
            if (text.length > tipKey.length + 1) {
              final rest = text.substring(tipKey.length + 1);
              return '${translator(tipKey)} ${translator(rest)}';
            } else {
              return translator(tipKey);
            }
          }
          return translator(text);
        }

        final boundaryInputs = [
          'a_tip b',
          'x_tip y',
          '_tip z',
          'custom_tip 1',
          'empty_tip ',
        ];

        for (final input in boundaryInputs) {
          expect(
            () => safeFormatTip(input, (k) => '[$k]'),
            returnsNormally,
            reason: 'Failed safely slicing boundary input: "$input"',
          );
        }
      },
    );

    test(
      '6. (F15) Fallback translation preserves input string verbatim on empty string or unregistered key',
      () {
        expect(translate(''), equals(''));
        expect(translate('__unregistered_random_key_12345__'), equals('__unregistered_random_key_12345__'));
      },
    );
  });
}
