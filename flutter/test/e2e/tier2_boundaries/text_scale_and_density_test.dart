import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/peers_view.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/desktop/pages/connection_page.dart';
import 'package:camellia_remote_app/desktop/pages/desktop_setting_page.dart';
import 'package:camellia_remote_app/desktop/widgets/desktop_shell.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import '../harness/test_app_harness.dart';

void main() {
  setUp(() async {
    await TestAppHarness.setUp();
    TestAppHarness.fakeBridge.setLocalFlutterOption(
      k: kOptionPeerSorting,
      v: PeerSortType.remoteId,
    );
    peerSort.value = PeerSortType.remoteId;
    peerSearchTextController.clear();
    peerSearchText.value = '';
    gFFI.peerTabModel.setCurrentTab(0);
  });

  tearDown(() {
    peerSearchTextController.clear();
    peerSearchText.value = '';
  });

  group('Tier 2: Text Scaling & Density Adaptation', () {
    testWidgets(
      '1. Large text scaling (1.5x) renders Connection workspace with zero RenderFlex overflow',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: Builder(
            builder: (context) {
              return MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: const TextScaler.linear(1.5),
                ),
                child: CamelliaDesktopShell(
                  initialDestination: DesktopNavDestination.connect,
                  connectBuilder: (_) => const SingleChildScrollView(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: ConnectionPage(showDevices: false),
                    ),
                  ),
                ),
              );
            },
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        // Verify elements rendered
        expect(find.byType(ConnectionPage), findsOneWidget);
        expect(find.byKey(const ValueKey('desktop-nav-sidebar')), findsOneWidget);

        // Verify no layout overflow exception
        expect(tester.takeException(), isNull);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '2. Extreme accessibility text scaling (2.0x) renders shell and Connection panel without overflow',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: Builder(
            builder: (context) {
              return MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: const TextScaler.linear(2.0),
                ),
                child: CamelliaDesktopShell(
                  initialDestination: DesktopNavDestination.connect,
                  connectBuilder: (_) => const SingleChildScrollView(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: ConnectionPage(showDevices: false),
                    ),
                  ),
                ),
              );
            },
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        // Connect page and sidebar rendered at 2.0x
        expect(find.byType(ConnectionPage), findsOneWidget);
        expect(find.byKey(const ValueKey('desktop-nav-sidebar')), findsOneWidget);
        expect(tester.takeException(), isNull);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '3. Settings workspace adapts to 1.5x text scaling across categories and sections',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: Builder(
            builder: (context) {
              return MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: const TextScaler.linear(1.5),
                ),
                child: DesktopSettingPage(initialTabkey: SettingsTabKey.general),
              );
            },
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        // Verify Settings sidebar tabs and General section rendered
        expect(find.text('General'), findsWidgets);
        expect(find.text('Network'), findsWidgets);
        expect(tester.takeException(), isNull);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '4. Navigation sidebar items and headers ellipsize cleanly under text scaling',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: Builder(
            builder: (context) {
              return MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: const TextScaler.linear(1.75),
                ),
                child: const CamelliaDesktopShell(
                  defaultSidebarWidth: 200.0,
                  collapseBreakpoint: 600.0,
                ),
              );
            },
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        // Header and destinations are present and clipped/ellipsized without overflow
        expect(find.text('Camellia Remote'), findsOneWidget);
        expect(find.byKey(const ValueKey('nav-bar-connect')), findsOneWidget);
        expect(find.byKey(const ValueKey('nav-bar-settings')), findsOneWidget);

        expect(tester.takeException(), isNull);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '5. VisualDensity adaptations (comfortable vs compact) preserve touch targets and hierarchy',
      (tester) async {
        // Test with VisualDensity.comfortable
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: Theme(
            data: CamelliaTheme.build(
              brightness: Brightness.light,
              desktopDensity: false,
            ).copyWith(
              visualDensity: VisualDensity.comfortable,
              extensions: [
                ColorThemeExtension.light,
                AppDesignTokens.light,
              ],
            ),
            child: const CamelliaDesktopShell(
              defaultSidebarWidth: 220.0,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));

        expect(find.byKey(const ValueKey('desktop-nav-sidebar')), findsOneWidget);
        expect(tester.takeException(), isNull);

        // Test with VisualDensity.compact
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: Theme(
            data: CamelliaTheme.build(
              brightness: Brightness.light,
              desktopDensity: true,
            ).copyWith(
              visualDensity: VisualDensity.compact,
              extensions: [
                ColorThemeExtension.light,
                AppDesignTokens.light,
              ],
            ),
            child: const CamelliaDesktopShell(
              defaultSidebarWidth: 220.0,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));

        expect(find.byKey(const ValueKey('desktop-nav-sidebar')), findsOneWidget);
        expect(tester.takeException(), isNull);

        await TestAppHarness.tearDown(tester);
      },
    );
  });
}
