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
}
