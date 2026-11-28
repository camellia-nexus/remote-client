// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/desktop/pages/desktop_setting_page.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import '../harness/test_app_harness.dart';

void main() {
  setUp(() async {
    await TestAppHarness.setUp();
  });

  group('Tier 1: i18n Widget Coverage & Translation Fallback', () {
    testWidgets(
      '1. Settings About section and GlassInput clear button use localized translate() strings',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: DesktopSettingPage(initialTabkey: SettingsTabKey.about),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.byType(DesktopSettingPage), findsOneWidget);

        final controller = TextEditingController(text: '123 456 789');
        addTearDown(controller.dispose);
        await TestAppHarness.pumpWidget(
          tester,
          child: GlassInput(
            controller: controller,
            showClearButton: true,
          ),
        );
        await tester.pump();

        expect(find.byTooltip(translate('Clear')), findsOneWidget);

        await TestAppHarness.tearDown(tester);
      },
    );

    test(
      '2. Fallback translation preserves input string verbatim on empty string or unregistered key',
      () {
        expect(translate(''), equals(''));
        expect(
          translate('__unregistered_random_key_12345__'),
          equals('__unregistered_random_key_12345__'),
        );
      },
    );
  });
}
