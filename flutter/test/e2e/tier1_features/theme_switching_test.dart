import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/models/platform_model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import '../harness/test_app_harness.dart';
import '../harness/fake_rustdesk_bridge.dart';

/// Standard WCAG 2.1 Relative Luminance calculation.
double _relativeLuminance(Color color) {
  double linearChannel(int channel) {
    final srgb = channel / 255.0;
    return srgb <= 0.04045
        ? srgb / 12.92
        : math.pow((srgb + 0.055) / 1.055, 2.4).toDouble();
  }

  final argb = color.toARGB32();
  final r = (argb >> 16) & 0xFF;
  final g = (argb >> 8) & 0xFF;
  final b = argb & 0xFF;

  return 0.2126 * linearChannel(r) +
      0.7152 * linearChannel(g) +
      0.0722 * linearChannel(b);
}

/// Standard WCAG 2.1 Contrast Ratio calculation: (L1 + 0.05) / (L2 + 0.05).
double _contrastRatio(Color c1, Color c2) {
  final l1 = _relativeLuminance(c1);
  final l2 = _relativeLuminance(c2);
  final lighter = math.max(l1, l2);
  final darker = math.min(l1, l2);
  return (lighter + 0.05) / (darker + 0.05);
}

class _ThrowingRustdeskBridge extends FakeRustdeskBridge {
  @override
  String mainGetLocalOption({required String key}) {
    throw Exception('simulated bridge failure');
  }
}

void main() {
  setUp(() async {
    await TestAppHarness.setUp();
  });

  group('Tier 1: Theme Switching & Camellia Design Tokens Coverage', () {
    testWidgets('1. Dynamic light to dark theme switching resolves brightness', (
      tester,
    ) async {
      Brightness? observedBrightness;

      await TestAppHarness.pumpWidget(
        tester,
        themeMode: ThemeMode.light,
        child: Builder(
          builder: (context) {
            observedBrightness = Theme.of(context).brightness;
            return Center(
              child: Text(
                'Current Brightness: ${observedBrightness?.name}',
              ),
            );
          },
        ),
      );
      await tester.pump();

      // Verify initial light brightness
      expect(observedBrightness, equals(Brightness.light));
      expect(find.text('Current Brightness: light'), findsOneWidget);

      // Switch dynamically to Dark mode
      TestAppHarness.themeModeNotifier.value = ThemeMode.dark;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(observedBrightness, equals(Brightness.dark));
      expect(find.text('Current Brightness: dark'), findsOneWidget);

      // Switch back to Light mode
      TestAppHarness.themeModeNotifier.value = ThemeMode.light;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(observedBrightness, equals(Brightness.light));
      expect(find.text('Current Brightness: light'), findsOneWidget);

      await TestAppHarness.tearDown(tester);
    });

    testWidgets(
      '2. AppDesignTokens resolves background, surface, and border across modes',
      (tester) async {
        AppDesignTokens? activeTokens;

        await TestAppHarness.pumpWidget(
          tester,
          themeMode: ThemeMode.light,
          child: Builder(
            builder: (context) {
              activeTokens = AppVisual.tokens(context);
              return Container(
                color: activeTokens?.surface,
                child: Text('Surface Page: ${activeTokens?.page}'),
              );
            },
          ),
        );
        await tester.pump();

        // Verify Light mode tokens
        expect(activeTokens, isNotNull);
        expect(activeTokens!.page, equals(CamelliaColors.lightCanvas));
        expect(activeTokens!.surface, equals(CamelliaColors.lightSurface));
        expect(activeTokens!.border, equals(CamelliaColors.lightBorder));
        expect(activeTokens!.muted, equals(CamelliaColors.lightMuted));

        // Switch to Dark mode
        TestAppHarness.themeModeNotifier.value = ThemeMode.dark;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        // Verify Dark mode tokens
        expect(activeTokens!.page, equals(CamelliaColors.darkCanvas));
        expect(activeTokens!.surface, equals(CamelliaColors.darkSurface));
        expect(activeTokens!.border, equals(CamelliaColors.darkBorder));
        expect(activeTokens!.muted, equals(CamelliaColors.darkMuted));

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '3. CamelliaColors palette constants match canonical design specification',
      (tester) async {
        // Assert hex value constants of brand palette
        expect(CamelliaColors.indigo.toARGB32(), equals(0xFF4F46E5));
        expect(CamelliaColors.indigoStrong.toARGB32(), equals(0xFF4338CA));
        expect(CamelliaColors.indigoSoft.toARGB32(), equals(0xFFEEF2FF));
        expect(CamelliaColors.azure.toARGB32(), equals(0xFF3B82F6));
        expect(CamelliaColors.azureStrong.toARGB32(), equals(0xFF2563EB));
        expect(CamelliaColors.coral.toARGB32(), equals(0xFFE11D48));
        expect(CamelliaColors.coralStrong.toARGB32(), equals(0xFFBE123C));
        expect(CamelliaColors.aqua.toARGB32(), equals(0xFF06B6D4));
        expect(CamelliaColors.aquaStrong.toARGB32(), equals(0xFF0891B2));
        expect(CamelliaColors.sun.toARGB32(), equals(0xFFD97706));
        expect(CamelliaColors.sunStrong.toARGB32(), equals(0xFFB45309));
        expect(CamelliaColors.leaf.toARGB32(), equals(0xFF10B981));

        // Background neutrals
        expect(CamelliaColors.lightCanvas.toARGB32(), equals(0xFFF4F7FB));
        expect(CamelliaColors.lightSurface.toARGB32(), equals(0xFFFCFDFF));
        expect(CamelliaColors.darkCanvas.toARGB32(), equals(0xFF080D18));
        expect(CamelliaColors.darkSurface.toARGB32(), equals(0xFF101829));
      },
    );

    testWidgets(
      '4. WCAG contrast ratios meet accessibility standards for text and accents',
      (tester) async {
        // Light theme text on surface (WCAG AAA requires >= 7.0:1)
        final lightTextRatio = _contrastRatio(
          CamelliaColors.lightText,
          CamelliaColors.lightSurface,
        );
        expect(
          lightTextRatio,
          greaterThanOrEqualTo(7.0),
          reason: 'Light text on surface must meet AAA contrast ratio',
        );

        // Dark theme text on surface (WCAG AAA requires >= 7.0:1)
        final darkTextRatio = _contrastRatio(
          CamelliaColors.darkText,
          CamelliaColors.darkSurface,
        );
        expect(
          darkTextRatio,
          greaterThanOrEqualTo(7.0),
          reason: 'Dark text on surface must meet AAA contrast ratio',
        );

        // Light theme muted text on surface (WCAG AA requires >= 4.5:1)
        final lightMutedRatio = _contrastRatio(
          CamelliaColors.lightMuted,
          CamelliaColors.lightSurface,
        );
        expect(
          lightMutedRatio,
          greaterThanOrEqualTo(4.5),
          reason: 'Light muted text must meet AA contrast ratio',
        );

        // Dark theme muted text on surface (WCAG AA requires >= 4.5:1)
        final darkMutedRatio = _contrastRatio(
          CamelliaColors.darkMuted,
          CamelliaColors.darkSurface,
        );
        expect(
          darkMutedRatio,
          greaterThanOrEqualTo(4.5),
          reason: 'Dark muted text must meet AA contrast ratio',
        );

        // Brand accent indigo on soft wash background (WCAG AA >= 3.0:1 for graphical elements)
        final accentRatio = _contrastRatio(
          CamelliaColors.indigo,
          CamelliaColors.indigoSoft,
        );
        expect(
          accentRatio,
          greaterThanOrEqualTo(3.0),
          reason: 'Brand accent on wash background must meet 3:1 graphical threshold',
        );
      },
    );

    testWidgets(
      '5. Surface components adhere to CamelliaRadius geometry and elevation',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          themeMode: ThemeMode.light,
          child: const Scaffold(
            body: Center(
              child: AppSurface(
                child: Text('Elevated Card Content'),
              ),
            ),
          ),
        );
        await tester.pump();

        // Verify AppSurface renders
        expect(find.text('Elevated Card Content'), findsOneWidget);
        final surfaceFinder = find.byType(AppSurface);
        expect(surfaceFinder, findsOneWidget);

        // Verify CamelliaRadius surface token is 14.0 and control is 10.0
        expect(CamelliaRadius.surface, equals(14.0));
        expect(CamelliaRadius.control, equals(10.0));
        expect(CamelliaRadius.sheet, equals(18.0));

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '6. ColorThemeExtension resolves semantic palette across light and dark modes',
      (tester) async {
        ColorThemeExtension? extension;

        await TestAppHarness.pumpWidget(
          tester,
          themeMode: ThemeMode.light,
          child: Builder(
            builder: (context) {
              extension = Theme.of(context).extension<ColorThemeExtension>();
              return Container(
                color: extension?.toastBg,
                child: Text('Toast Text: ${extension?.toastText}'),
              );
            },
          ),
        );
        await tester.pump();

        // Verify extension is registered in light theme
        expect(extension, isNotNull);
        expect(extension?.border, equals(ColorThemeExtension.light.border));
        expect(extension?.highlight, equals(ColorThemeExtension.light.highlight));
        expect(extension?.toastBg, equals(ColorThemeExtension.light.toastBg));
        expect(extension?.toastText, equals(ColorThemeExtension.light.toastText));

        // Switch to Dark theme
        TestAppHarness.themeModeNotifier.value = ThemeMode.dark;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        // Verify extension updates to dark theme
        expect(extension?.border, equals(ColorThemeExtension.dark.border));
        expect(extension?.highlight, equals(ColorThemeExtension.dark.highlight));
        expect(extension?.toastBg, equals(ColorThemeExtension.dark.toastBg));
        expect(extension?.toastText, equals(ColorThemeExtension.dark.toastText));

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '7. changeThemeStyle preserves style in memory and does not get clobbered by disk options',
      (tester) async {
        TestAppHarness.fakeBridge.localOptions['theme_style'] = 'auroraFrost';
        MyTheme.themeStyleNotifier.value = CamelliaThemeStyle.auroraFrost;
        MyTheme.themeNotifier.value = CamelliaThemePreference.light;

        await MyTheme.changeThemeStyle(CamelliaThemeStyle.nordicTitanium);

        expect(
          MyTheme.themeStyleNotifier.value,
          equals(CamelliaThemeStyle.nordicTitanium),
        );
        expect(
          MyTheme.getThemeStyle(),
          equals(CamelliaThemeStyle.nordicTitanium),
        );
        expect(
          MyTheme.lightTheme.extension<AppDesignTokens>()!.page,
          equals(const Color(0xFFF4F4F6)),
        );

        // Calling getThemePreference must not mutate themeStyleNotifier
        MyTheme.getThemePreference();
        expect(
          MyTheme.themeStyleNotifier.value,
          equals(CamelliaThemeStyle.nordicTitanium),
        );
      },
    );

    testWidgets(
      '8. getThemeModePreference safely falls back when native bridge option retrieval fails',
      (tester) async {
        MyTheme.themeNotifier.value = CamelliaThemePreference.light;
        final originalBind = platformFFI.ffiBind;
        try {
          platformFFI.ffiBind = _ThrowingRustdeskBridge();

          expect(MyTheme.getThemeModePreference(), equals(ThemeMode.light));

          MyTheme.themeNotifier.value = CamelliaThemePreference.dark;
          expect(MyTheme.getThemeModePreference(), equals(ThemeMode.dark));

          MyTheme.themeNotifier.value = CamelliaThemePreference.midnight;
          expect(MyTheme.getThemeModePreference(), equals(ThemeMode.dark));

          MyTheme.themeNotifier.value = CamelliaThemePreference.system;
          expect(MyTheme.getThemeModePreference(), equals(ThemeMode.system));
        } finally {
          platformFFI.ffiBind = originalBind;
        }
      },
    );
  });
}
