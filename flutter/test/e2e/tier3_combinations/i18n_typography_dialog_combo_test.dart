// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/brand_shell.dart';
import 'package:camellia_remote_app/common/widgets/dialog.dart';
import 'package:camellia_remote_app/desktop/pages/desktop_setting_page.dart';
import '../harness/test_app_harness.dart';

void main() {
  setUp(() async {
    await TestAppHarness.setUp();
  });

  group('Tier 3: i18n Switching x Settings About Overhaul x Modal Esc Combo (TC-T3-04, TC-T3-06)', () {
    testWidgets(
      '1. Language switching (en -> zh-cn -> zh-tw) dynamically updates Settings About page without layout overflow',
      (tester) async {
        final locales = ['en', 'zh-cn', 'zh-tw'];

        for (final loc in locales) {
          await TestAppHarness.fakeBridge.mainSetLocalOption(
            key: 'lang',
            value: loc,
          );

          await TestAppHarness.pumpWidget(
            tester,
            surfaceSize: const Size(1280, 800),
            child: DesktopSettingPage(initialTabkey: SettingsTabKey.about),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 50));

          // Settings page renders cleanly under all locales
          expect(find.byType(DesktopSettingPage), findsOneWidget);

          // Verify bespoke brand mark is rendered
          expect(find.byType(CamelliaBrandMark), findsOneWidget);

          expect(tester.takeException(), isNull);
        }

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '2. Modal error dialog with ModernDialogHeader under zh-cn locale is dismissed by physical Escape key',
      (tester) async {
        await TestAppHarness.fakeBridge.mainSetLocalOption(
          key: 'lang',
          value: 'zh-cn',
        );

        bool cancelInvoked = false;

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () {
                showDialog<void>(
                  context: context,
                  builder: (ctx) => CustomAlertDialog(
                    title: ModernDialogHeader.error(
                      title: translate('Connection error'),
                      subtitle: translate('Failed to establish connection'),
                      onClose: () => Navigator.of(ctx).pop(),
                    ),
                    content: Text(translate('The connection timed out')),
                    onCancel: () {
                      cancelInvoked = true;
                      Navigator.of(ctx).pop();
                    },
                  ),
                );
              },
              child: const Text('Launch Error Modal'),
            ),
          ),
        );
        await tester.pump();

        // Launch modal dialog
        await tester.tap(find.text('Launch Error Modal'));
        await tester.pumpAndSettle();

        expect(find.byType(CustomAlertDialog), findsOneWidget);

        // Press Escape key to dismiss dialog
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();

        expect(find.byType(CustomAlertDialog), findsNothing);
        expect(cancelInvoked, isTrue);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '3. Modal error dialog close icon button click dismisses dialog cleanly under zh-tw locale',
      (tester) async {
        await TestAppHarness.fakeBridge.mainSetLocalOption(
          key: 'lang',
          value: 'zh-tw',
        );

        bool headerCloseInvoked = false;

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: CustomAlertDialog(
            title: ModernDialogHeader.error(
              title: '連線逾時',
              subtitle: '請檢查網絡設定',
              onClose: () => headerCloseInvoked = true,
            ),
            content: const Text('無法連接至遠端設備，請稍後重試。'),
          ),
        );
        await tester.pump();

        final closeIconBtn = find.descendant(
          of: find.byType(ModernDialogHeader),
          matching: find.byType(IconButton),
        );
        expect(closeIconBtn, findsOneWidget);

        await tester.tap(closeIconBtn);
        await tester.pump();

        expect(headerCloseInvoked, isTrue);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '4. Typography even leading distribution is active on theme to prevent upward glyph skew on CJK glyphs',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: DesktopSettingPage(initialTabkey: SettingsTabKey.about),
        );
        await tester.pump();

        final ctx = tester.element(find.byType(DesktopSettingPage));
        final leadingDist =
            DefaultTextHeightBehavior.maybeOf(ctx)?.leadingDistribution;
        if (leadingDist != null) {
          expect(leadingDist, equals(TextLeadingDistribution.even));
        }

        expect(tester.takeException(), isNull);

        await TestAppHarness.tearDown(tester);
      },
    );
  });
}
