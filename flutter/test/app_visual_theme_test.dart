import 'package:flutter/material.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/desktop/widgets/tabbar_widget.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:flutter_test/flutter_test.dart';

class _VisualSnapshot {
  const _VisualSnapshot({
    required this.brightness,
    required this.tokens,
    required this.tones,
    required this.toneContainers,
    required this.surface,
    required this.raisedSurface,
  });

  final Brightness brightness;
  final AppDesignTokens tokens;
  final Map<AppTone, Color> tones;
  final Map<AppTone, Color> toneContainers;
  final BoxDecoration surface;
  final BoxDecoration raisedSurface;
}

void main() {
  testWidgets('semantic surfaces resolve from light and dark theme tokens', (
    tester,
  ) async {
    for (final (theme, expectedTokens) in [
      (MyTheme.lightTheme, AppDesignTokens.light),
      (MyTheme.darkTheme, AppDesignTokens.dark),
    ]) {
      _VisualSnapshot? snapshot;
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Builder(
            builder: (context) {
              snapshot = _VisualSnapshot(
                brightness: Theme.of(context).brightness,
                tokens: AppVisual.tokens(context),
                tones: {
                  for (final tone in AppTone.values)
                    tone: AppVisual.tone(context, tone),
                },
                toneContainers: {
                  for (final tone in AppTone.values)
                    tone: AppVisual.toneContainer(context, tone),
                },
                surface: AppVisual.surfaceDecoration(context),
                raisedSurface: AppVisual.surfaceDecoration(
                  context,
                  elevated: true,
                ),
              );
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      final visual = snapshot!;
      expect(visual.brightness, theme.brightness);
      expect(visual.tokens.page, expectedTokens.page);
      expect(visual.tokens.surface, expectedTokens.surface);
      expect(visual.tokens.surfaceContainer, expectedTokens.surfaceContainer);
      expect(visual.tokens.surfaceElevated, expectedTokens.surfaceElevated);
      expect(visual.tokens.border, expectedTokens.border);
      expect(visual.tokens.controlHeight, 44);
      expect(visual.tokens.touchTarget, 48);
      expect(
        theme.focusColor,
        CamelliaColors.azure.withValues(
          alpha: theme.brightness == Brightness.light ? 0.18 : 0.28,
        ),
      );
      expect(
        theme.filledButtonTheme.style?.minimumSize?.resolve({}),
        Size(0, expectedTokens.controlHeight),
      );
      expect(visual.surface.color, expectedTokens.surface);
      expect(visual.surface.border!.top.color, expectedTokens.border);
      expect(visual.surface.boxShadow, isEmpty);
      expect(visual.raisedSurface.color, expectedTokens.surfaceElevated);
      expect(visual.raisedSurface.border!.top.color, expectedTokens.border);
      expect(visual.raisedSurface.boxShadow, hasLength(1));
      expect(
        visual.raisedSurface.boxShadow!.single.color,
        expectedTokens.shadowStrong,
      );

      expect(visual.tones[AppTone.brand], theme.colorScheme.primary);
      expect(visual.tones[AppTone.secondary], expectedTokens.secondary);
      expect(visual.tones[AppTone.info], expectedTokens.info);
      expect(visual.tones[AppTone.success], expectedTokens.success);
      expect(visual.tones[AppTone.warning], expectedTokens.warning);
      expect(visual.tones[AppTone.danger], expectedTokens.danger);
      expect(visual.tones[AppTone.neutral], expectedTokens.muted);
      expect(
        visual.toneContainers[AppTone.brand],
        expectedTokens.accentContainer,
      );
      expect(
        visual.toneContainers[AppTone.success],
        expectedTokens.success.withValues(
          alpha: theme.brightness == Brightness.light ? 0.10 : 0.18,
        ),
      );
    }
  });

  test('MyTheme constants map cleanly to CamelliaColors and design tokens', () {
    expect(MyTheme.grayBg, CamelliaColors.lightCanvas);
    expect(MyTheme.accent, CamelliaColors.indigo);
    expect(MyTheme.accent50, CamelliaColors.indigo50);
    expect(MyTheme.accent80, CamelliaColors.indigo80);
    expect(MyTheme.canvasColor, CamelliaColors.darkCanvas);
    expect(MyTheme.border, CamelliaColors.lightBorder);
    expect(MyTheme.idColor, CamelliaColors.azureStrong);
    expect(MyTheme.darkGray, CamelliaColors.lightMuted);
    expect(MyTheme.cmIdColor, CamelliaColors.aquaStrong);
    expect(MyTheme.dark, CamelliaColors.lightText);
    expect(MyTheme.button, CamelliaColors.indigo);
    expect(MyTheme.hoverBorder, CamelliaColors.indigo);
  });

  testWidgets(
    'TabbarTheme integrates with design tokens in light theme',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          key: const ValueKey('light-app'),
          theme: MyTheme.lightTheme,
          home: Builder(
            builder: (context) {
              final tabbarTheme = TabbarTheme.of(context);
              final tokens = MyTheme.tokens(context);
              expect(tabbarTheme, isNotNull);
              expect(tabbarTheme.selectedTabIconColor, CamelliaColors.indigo);
              expect(tabbarTheme.unSelectedTabIconColor, tokens.muted);
              expect(tabbarTheme.selectedTextColor, CamelliaColors.lightText);
              expect(tabbarTheme.unSelectedTextColor, tokens.muted);
              expect(tabbarTheme.dividerColor, tokens.border);
              expect(tabbarTheme.hoverColor, tokens.accentContainer);
              expect(tabbarTheme.selectedTabBackgroundColor, tokens.surface);
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'TabbarTheme integrates with design tokens in dark theme',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          key: const ValueKey('dark-app'),
          theme: MyTheme.darkTheme,
          home: Builder(
            builder: (context) {
              final tabbarTheme = TabbarTheme.of(context);
              final tokens = MyTheme.tokens(context);
              expect(tabbarTheme, isNotNull);
              expect(
                tabbarTheme.selectedTabIconColor,
                const Color(0xFFAAA7FF),
              );
              expect(tabbarTheme.unSelectedTabIconColor, tokens.muted);
              expect(tabbarTheme.selectedTextColor, CamelliaColors.darkText);
              expect(tabbarTheme.unSelectedTextColor, tokens.muted);
              expect(tabbarTheme.dividerColor, tokens.border);
              expect(tabbarTheme.hoverColor, tokens.accentContainer);
              expect(tabbarTheme.selectedTabBackgroundColor, tokens.surface);
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
    },
  );
}
