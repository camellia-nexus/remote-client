import 'dart:io';

import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('language resolver normalizes supported locale families', () {
    expect(
      CamelliaTypography.resolve(
        savedLanguage: 'default',
        systemLocale: const Locale.fromSubtags(
          languageCode: 'zh',
          scriptCode: 'Hant',
          countryCode: 'HK',
        ),
      ),
      CamelliaLanguage.traditionalChinese,
    );
    expect(
      CamelliaTypography.resolve(
        savedLanguage: '',
        systemLocale: const Locale('zh', 'SG'),
      ),
      CamelliaLanguage.simplifiedChinese,
    );
    expect(
      CamelliaTypography.resolve(
        savedLanguage: 'zh-tw',
        systemLocale: const Locale('en', 'US'),
      ),
      CamelliaLanguage.traditionalChinese,
    );
    expect(
      CamelliaTypography.resolve(
        savedLanguage: 'fr',
        systemLocale: const Locale('zh', 'TW'),
      ),
      CamelliaLanguage.english,
    );
  });

  test('theme applies one bundled family to every text style', () {
    for (final family in [
      CamelliaTypography.simplifiedFamily,
      CamelliaTypography.traditionalFamily,
    ]) {
      final theme = CamelliaTheme.build(
        brightness: Brightness.light,
        desktopDensity: true,
        fontFamily: family,
      );
      expect(theme.textTheme.bodyMedium?.fontFamily, family);
      expect(theme.textTheme.titleLarge?.fontFamily, family);
      expect(theme.tooltipTheme.textStyle?.fontFamily, family);
    }
  });

  test('Flutter advertises only English and Chinese regional locales', () {
    expect(supportedLocales.map((locale) => locale.toLanguageTag()).toSet(), {
      'en-US',
      'zh-Hans',
      'zh-Hant',
      'zh-CN',
      'zh-SG',
      'zh-TW',
      'zh-HK',
      'zh-MO',
    });
  });

  test(
    'script code takes precedence over regional code for script-tagged locales',
    () {
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
    },
  );

  test(
    'theme applies system font fallbacks without forcing bundled heavy CJK fonts (PERF-006)',
    () {
      expect(CamelliaTypography.systemFontFallbacks, [
        'PingFang SC',
        'Microsoft YaHei',
        'Heiti SC',
        'sans-serif',
      ]);

      final lightTheme = CamelliaTheme.build(
        brightness: Brightness.light,
        desktopDensity: true,
      );
      expect(
        lightTheme.textTheme.bodyMedium?.fontFamilyFallback,
        CamelliaTypography.systemFontFallbacks,
      );
      expect(
        lightTheme.textTheme.titleLarge?.fontFamilyFallback,
        CamelliaTypography.systemFontFallbacks,
      );

      final darkTheme = CamelliaTheme.build(
        brightness: Brightness.dark,
        desktopDensity: true,
      );
      expect(
        darkTheme.textTheme.bodyMedium?.fontFamilyFallback,
        CamelliaTypography.systemFontFallbacks,
      );
      expect(
        darkTheme.textTheme.titleLarge?.fontFamilyFallback,
        CamelliaTypography.systemFontFallbacks,
      );
    },
  );

  test('pubspec.yaml decouples massive CJK variable fonts from static bundle (PERF-006)', () {
    Directory flutterDir;
    if (Directory.current.path.endsWith('flutter')) {
      flutterDir = Directory.current;
    } else if (Directory.current.path.endsWith('client')) {
      flutterDir = Directory('${Directory.current.path}/flutter');
    } else {
      flutterDir = Directory('${Directory.current.path}/client/flutter');
    }

    final pubspec = File('${flutterDir.path}/pubspec.yaml');
    expect(pubspec.existsSync(), isTrue);

    final lines = pubspec.readAsLinesSync();
    // Ensure no active (uncommented) line references NotoSansSC-VF or NotoSansTC-VF
    final activeFontDeclarations = lines.where((line) {
      final trimmed = line.trim();
      return !trimmed.startsWith('#') &&
          (trimmed.contains('NotoSansSC-VF.ttf') ||
              trimmed.contains('NotoSansTC-VF.ttf'));
    }).toList();

    expect(
      activeFontDeclarations,
      isEmpty,
      reason:
          'Massive CJK variable fonts must not be statically declared in pubspec.yaml fonts section',
    );
  });
}
