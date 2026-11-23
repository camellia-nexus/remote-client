import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/desktop/pages/connection_page.dart';
import 'package:camellia_remote_app/desktop/widgets/identity_board_widgets.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/device_workspace_controls.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'e2e/harness/test_app_harness.dart';

void main() {
  setUp(() async {
    await TestAppHarness.setUp(
      initialServerId: '123 456 789',
      initialPassword: 'SafePassword123',
    );
  });

  group('Button Border Normalization & Focus Glow Standardization', () {
    testWidgets(
      'GlassButton and GlassIconButton do not produce sharp 0-blur fake border outlines',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          child: Column(
            children: [
              GlassButton(
                onPressed: () {},
                child: const Text('Test GlassButton'),
              ),
              GlassIconButton(
                icon: Icons.refresh,
                onPressed: () {},
              ),
            ],
          ),
        );
        await tester.pump();

        // Tap both buttons
        await tester.tap(find.byType(GlassButton));
        await tester.pump();
        await tester.tap(find.byType(GlassIconButton));
        await tester.pump();

        final containers = tester.widgetList<AnimatedContainer>(
          find.byType(AnimatedContainer),
        );

        for (final container in containers) {
          final decoration = container.decoration as BoxDecoration?;
          if (decoration?.boxShadow != null) {
            final hasSharpBorder = decoration!.boxShadow!.any(
              (s) => s.spreadRadius >= 2.0 && s.blurRadius == 0,
            );
            expect(
              hasSharpBorder,
              isFalse,
              reason: 'Zero-blur fake border outlines must not exist on buttons',
            );
          }
        }

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      'GlassSegmentedControl tap target does not generate sharp 2.0px solid border on tap and segment thumb has no inner SpecularEdgePainter',
      (tester) async {
        String selected = 'a';
        await TestAppHarness.pumpWidget(
          tester,
          child: Center(
            child: GlassSegmentedControl<String>(
              items: const [
                GlassSegmentItem(value: 'a', label: 'Tab A'),
                GlassSegmentItem(value: 'b', label: 'Tab B'),
              ],
              selected: selected,
              onChanged: (v) => selected = v,
            ),
          ),
        );
        await tester.pump();

        // Tap unselected segment
        await tester.tap(find.text('Tab B'));
        await tester.pump();

        final decoratedBoxes = tester.widgetList<DecoratedBox>(
          find.descendant(
            of: find.byType(GlassSegmentedControl<String>),
            matching: find.byType(DecoratedBox),
          ),
        );

        for (final box in decoratedBoxes) {
          final decoration = box.decoration as BoxDecoration?;
          if (decoration?.boxShadow != null) {
            final hasSharpBorder = decoration!.boxShadow!.any(
              (s) => s.spreadRadius >= 2.0 && s.blurRadius == 0,
            );
            expect(
              hasSharpBorder,
              isFalse,
              reason: 'Segmented tap targets must not render sharp 0-blur borders',
            );
          }
        }

        // Only the outer shell GlassSurface should have SpecularEdgePainter;
        // individual segment item thumbs must not render redundant inner specular borders.
        final customPaints = tester.widgetList<CustomPaint>(
          find.descendant(
            of: find.byType(GlassSegmentedControl<String>),
            matching: find.byType(CustomPaint),
          ),
        );
        final specularPainters = customPaints
            .where((p) => p.foregroundPainter is SpecularEdgePainter)
            .toList();
        // At most 1 SpecularEdgePainter (on outer shell GlassSurface), not duplicated on items
        expect(
          specularPainters.length,
          lessThanOrEqualTo(1),
          reason: 'Segment thumbs must not have redundant inner SpecularEdgePainter borders',
        );

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      'AppCopyFeedbackButton and _SpinRefreshButton use clean borderless shape and transparent focus/highlight/splash',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          child: Column(
            children: [
              const AppCopyFeedbackButton(
                text: '123 456 789',
                tooltip: 'Copy ID',
              ),
              const IdentityPasswordBoard(),
            ],
          ),
        );
        await tester.pump();

        final iconButtons = tester.widgetList<IconButton>(
          find.byType(IconButton),
        );
        expect(iconButtons, isNotEmpty);

        for (final btn in iconButtons) {
          final style = btn.style;
          if (style != null) {
            expect(style.side?.resolve({}), BorderSide.none);
            expect(style.overlayColor?.resolve({WidgetState.focused}), Colors.transparent);
            expect(style.overlayColor?.resolve({WidgetState.pressed}), Colors.transparent);
            expect(style.splashFactory, NoSplash.splashFactory);
          }
        }

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      'OnlineStatusWidget PopupMenuButton configures pill border radius and NoSplash theme',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          child: const OnlineStatusWidget(compact: true),
        );
        await tester.pump();

        final popup = tester.widget<PopupMenuButton<String>>(
          find.byType(PopupMenuButton<String>),
        );
        expect(popup.borderRadius, BorderRadius.circular(CamelliaRadius.pill));

        // Must be wrapped in Theme with NoSplash and transparent highlight/focus
        final themeWidget = tester.widget<Theme>(
          find.ancestor(
            of: find.byType(PopupMenuButton<String>),
            matching: find.byType(Theme),
          ).first,
        );
        expect(themeWidget.data.splashFactory, NoSplash.splashFactory);
        expect(themeWidget.data.highlightColor, Colors.transparent);
        expect(themeWidget.data.focusColor, Colors.transparent);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      'DeviceOptionMenuButton configures control border radius, NoSplash theme, and no inner SpecularEdgePainter',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          child: Center(
            child: DeviceOptionMenuButton<String>(
              tooltip: 'Sort',
              icon: Icons.sort,
              selectedValue: 'id',
              options: const [
                DeviceOptionMenuItem(value: 'id', label: 'ID', icon: Icons.sort),
              ],
              onSelected: (_) {},
            ),
          ),
        );
        await tester.pump();

        final popup = tester.widget<PopupMenuButton<String>>(
          find.byType(PopupMenuButton<String>),
        );
        expect(popup.borderRadius, BorderRadius.circular(CamelliaRadius.control));

        // Must be wrapped in Theme with NoSplash and transparent highlight/focus
        final themeWidget = tester.widget<Theme>(
          find.ancestor(
            of: find.byType(PopupMenuButton<String>),
            matching: find.byType(Theme),
          ).first,
        );
        expect(themeWidget.data.splashFactory, NoSplash.splashFactory);
        expect(themeWidget.data.highlightColor, Colors.transparent);
        expect(themeWidget.data.focusColor, Colors.transparent);

        // Child must not have redundant SpecularEdgePainter border
        final customPaints = tester.widgetList<CustomPaint>(
          find.descendant(
            of: find.byType(DeviceOptionMenuButton<String>),
            matching: find.byType(CustomPaint),
          ),
        );
        expect(
          customPaints.any((p) => p.foregroundPainter is SpecularEdgePainter),
          isFalse,
          reason: 'DeviceOptionMenuButton must not render inner SpecularEdgePainter border',
        );

        await TestAppHarness.tearDown(tester);
      },
    );
  });
}
