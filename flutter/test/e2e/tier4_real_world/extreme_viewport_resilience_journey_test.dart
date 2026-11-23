// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/desktop/pages/connection_page.dart';
import 'package:camellia_remote_app/desktop/pages/desktop_setting_page.dart';
import 'package:camellia_remote_app/desktop/widgets/desktop_shell.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import '../harness/test_app_harness.dart';

void main() {
  setUp(() async {
    await TestAppHarness.setUp();
  });

  group('Tier 4: Scenario 4 - Extreme Viewport Boundaries, String Extremes & i18n Stress Journey', () {
    testWidgets(
      'Complete Journey: Narrow 480px tiling split -> Extreme string input -> zh-tw text expansion -> 4K ultra-wide 3440x1440 expansion',
      (tester) async {
        // Step 1: Narrow Tiling Viewport (480x700)
        final controller = CamelliaDesktopShellController(
          initialDestination: DesktopNavDestination.connect,
        );

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(480, 700),
          child: CamelliaDesktopShell(
            controller: controller,
            collapseBreakpoint: 768.0,
            connectBuilder: (_) => const SingleChildScrollView(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: ConnectionPage(showDevices: false),
              ),
            ),
            settingsBuilder: (_) => DesktopSettingPage(initialTabkey: SettingsTabKey.general),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        // Sidebar must auto-collapse to rail mode (64px)
        final sidebarFinder = find.byKey(const ValueKey('desktop-nav-sidebar'));
        expect(tester.getSize(sidebarFinder).width, equals(64.0));

        // 6-mode segmented control rendered without RenderFlex overflow
        expect(find.byType(GlassSegmentedControl), findsOneWidget);
        expect(tester.takeException(), isNull);

        // Step 2: Extreme String Input in Glass Input Field
        const extremeRemoteId =
            'cluster-us-west-production-gateway-01.internal.network.example.com.camellia.datacenter.zone-a';
        final inputController = TextEditingController(text: extremeRemoteId);

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(480, 700),
          child: GlassInput(
            controller: inputController,
            hintText: 'Remote Address / ID',
          ),
        );
        await tester.pump();

        expect(find.text(extremeRemoteId), findsOneWidget);
        expect(tester.takeException(), isNull);

        // Step 3: Multilingual Stress with Traditional Chinese (zh-tw)
        await TestAppHarness.fakeBridge.mainSetLocalOption(
          key: 'lang',
          value: 'zh-tw',
        );

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(600, 800),
          child: DesktopSettingPage(initialTabkey: SettingsTabKey.about),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.byType(DesktopSettingPage), findsOneWidget);
        expect(tester.takeException(), isNull);

        // Step 4: Ultra-Wide 4K Viewport Expansion (3440x1440)
        await tester.binding.setSurfaceSize(const Size(3440, 1440));
        tester.view.physicalSize = const Size(3440, 1440);

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(3440, 1440),
          child: CamelliaDesktopShell(
            controller: controller,
            connectBuilder: (_) => const Center(child: Text('Ultra-Wide Canvas')),
            settingsBuilder: (_) => const Text('Settings View'),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.text('Ultra-Wide Canvas'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await TestAppHarness.tearDown(tester);
      },
    );
  });
}
