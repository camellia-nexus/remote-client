// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:camellia_remote_app/common/widgets/brand_shell.dart';
import 'package:camellia_remote_app/common/widgets/first_run_wizard_dialog.dart';
import 'package:camellia_remote_app/desktop/pages/connection_page.dart';
import 'package:camellia_remote_app/desktop/pages/desktop_home_page.dart';
import 'package:camellia_remote_app/desktop/pages/desktop_setting_page.dart';
import 'package:camellia_remote_app/desktop/widgets/desktop_shell.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import '../harness/test_app_harness.dart';

void main() {
  setUp(() async {
    await TestAppHarness.setUp();
    Get.lazyPut<RxBool>(() => false.obs, tag: 'stop-service', fenix: true);
  });

  group('Tier 4: Scenario 1 - Operator First-Run Onboarding & Customization Journey', () {
    testWidgets(
      'Complete Journey: Cold start -> Obsidian Cyber dark theme -> zh-cn translation -> Settings About verification -> Return to Workspace',
      (tester) async {
        // Step 1: Clean Cold Start Without Configuration
        TestAppHarness.fakeBridge.localOptions.clear();

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: const DesktopHomePage(),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        // Direct reveal: DesktopHomePage rendered; no wizard dialog or loading spinner
        expect(find.byType(DesktopHomePage), findsOneWidget);
        expect(find.byType(FirstRunWizardDialog), findsNothing);
        expect(find.text('Get Started'), findsNothing);
        expect(find.text('Checking...'), findsNothing);

        // Unmount DesktopHomePage cleanly to complete its dispose() cycle
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        Get.put<RxBool>(false.obs, tag: 'stop-service');

        // Step 2: Navigate to Appearance Settings & Select Obsidian Cyber Dark
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          themeMode: ThemeMode.dark,
          themeStyle: 'obsidianCyber',
          child: DesktopSettingPage(initialTabkey: SettingsTabKey.general),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.byType(DesktopSettingPage), findsOneWidget);

        // Verify ThemeMode is dark
        final settingsElement = tester.element(find.byType(DesktopSettingPage));
        expect(Theme.of(settingsElement).brightness, equals(Brightness.dark));

        // Step 3: Switch Language to Simplified Chinese (zh-cn)
        await TestAppHarness.fakeBridge.mainSetLocalOption(
          key: 'lang',
          value: 'zh-cn',
        );

        // Unmount Settings Page cleanly before switching tab key
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        Get.put<RxBool>(false.obs, tag: 'stop-service');

        // Step 4: Navigate to Settings -> About
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          themeMode: ThemeMode.dark,
          themeStyle: 'obsidianCyber',
          child: DesktopSettingPage(initialTabkey: SettingsTabKey.about),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        // Verify About section branding and typography
        expect(find.byType(CamelliaBrandMark), findsOneWidget);
        expect(find.byIcon(Icons.desktop_windows_rounded), findsNothing);

        // Step 5: Return to Connect Workspace with Dark Obsidian Styling Intact
        final controller = CamelliaDesktopShellController(
          initialDestination: DesktopNavDestination.connect,
        );

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          themeMode: ThemeMode.dark,
          themeStyle: 'obsidianCyber',
          child: CamelliaDesktopShell(
            controller: controller,
            connectBuilder: (_) => const Text('Customized Connect Workspace'),
            settingsBuilder: (_) => const Text('Settings View'),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.text('Customized Connect Workspace'), findsOneWidget);
        final shellCtx = tester.element(find.byType(CamelliaDesktopShell));
        expect(Theme.of(shellCtx).brightness, equals(Brightness.dark));

        expect(tester.takeException(), isNull);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      'Step Verification: First-run online status dot initializes without infinite oval pulsing loop',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          child: const OnlineStatusWidget(compact: true),
        );
        await tester.pump();

        final badge = tester.widget<GlassBadge>(find.byType(GlassBadge));
        expect(badge.pulse, isFalse);

        await TestAppHarness.tearDown(tester);
      },
    );
  });
}
