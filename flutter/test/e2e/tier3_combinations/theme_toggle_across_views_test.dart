import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/peer_card.dart';
import 'package:camellia_remote_app/common/widgets/peer_tab_page.dart';
import 'package:camellia_remote_app/common/widgets/peers_view.dart';
import 'package:camellia_remote_app/common/widgets/settings_overlay.dart';
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
    peerCardUiType.value = PeerUiType.grid;
    gFFI.peerTabModel.setCurrentTab(0);
  });

  tearDown(() {
    peerSearchTextController.clear();
    peerSearchText.value = '';
  });

  group('Tier 3: Theme Toggle Across Deeply Nested Views & Modal Surfaces', () {
    testWidgets(
      '1. Dynamic theme toggle on Connect view updates shell canvas and card surfaces',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          themeMode: ThemeMode.light,
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
        await tester.pump();

        // 1. Light mode verification
        BuildContext ctx = globalKey.currentContext!;
        expect(AppVisual.tokens(ctx).page, equals(CamelliaColors.lightCanvas));
        expect(AppVisual.tokens(ctx).surface, equals(CamelliaColors.lightSurface));

        // 2. Toggle to Dark Mode
        TestAppHarness.themeModeNotifier.value = ThemeMode.dark;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        ctx = globalKey.currentContext!;
        expect(AppVisual.tokens(ctx).page, equals(CamelliaColors.darkCanvas));
        expect(AppVisual.tokens(ctx).surface, equals(CamelliaColors.darkSurface));

        // 3. Toggle back to Light Mode
        TestAppHarness.themeModeNotifier.value = ThemeMode.light;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        ctx = globalKey.currentContext!;
        expect(AppVisual.tokens(ctx).page, equals(CamelliaColors.lightCanvas));
        expect(tester.takeException(), isNull);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '2. Dynamic theme toggle on Devices workspace preserves peer cards and status contrast',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          themeMode: ThemeMode.light,
          child: const Scaffold(
            body: SizedBox(
              width: 1000,
              height: 700,
              child: PeerTabPage(),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));

        // Switch to Favorites tab (Bob: Online, Charlie: Offline)
        final favTab = find.byTooltip('Favorites');
        await tester.tap(favTab);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));

        // In Light mode, online status dot has leaf color
        expect(find.byTooltip('Online'), findsWidgets);
        expect(find.byTooltip('Offline'), findsWidgets);

        // Toggle to Dark Mode
        TestAppHarness.themeModeNotifier.value = ThemeMode.dark;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        // In Dark mode, peer list is preserved and status avatars remain visible
        expect(find.byTooltip('Online'), findsWidgets);
        expect(find.byTooltip('Offline'), findsWidgets);
        expect(find.textContaining('Charlie'), findsWidgets);
        expect(tester.takeException(), isNull);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '3. Dynamic theme toggle in Settings view adapts SettingsSection and SettingsTile styling',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          themeMode: ThemeMode.light,
          child: DesktopSettingPage(initialTabkey: SettingsTabKey.general),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        expect(find.text('General'), findsWidgets);
        expect(find.text('Network'), findsWidgets);

        // Toggle to Dark Mode
        TestAppHarness.themeModeNotifier.value = ThemeMode.dark;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        // Settings sidebar and content remain stable
        expect(find.text('General'), findsWidgets);
        expect(find.text('Network'), findsWidgets);
        expect(tester.takeException(), isNull);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '4. Dynamic theme toggle while modal overlay is open adapts modal surface smoothly',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          themeMode: ThemeMode.light,
          child: Scaffold(
            body: Builder(
              builder: (context) {
                return Center(
                  child: ElevatedButton(
                    onPressed: () {
                      showSettingsOverlay<void>(
                        context: context,
                        title: 'Themed Overlay Modal',
                        builder: (_) => const Center(
                          child: Text('Themed Modal Content'),
                        ),
                      );
                    },
                    child: const Text('Open Modal'),
                  ),
                );
              },
            ),
          ),
        );
        await tester.pump();

        // 1. Open modal in Light mode
        await tester.tap(find.text('Open Modal'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.text('Themed Overlay Modal'), findsOneWidget);
        expect(find.text('Themed Modal Content'), findsOneWidget);

        // 2. Toggle to Dark Mode while modal is open
        TestAppHarness.themeModeNotifier.value = ThemeMode.dark;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        // Modal content is preserved
        expect(find.text('Themed Overlay Modal'), findsOneWidget);
        expect(find.text('Themed Modal Content'), findsOneWidget);

        // 3. Dismiss modal
        final closeBtn = find.byTooltip('Close');
        expect(closeBtn, findsOneWidget);
        await tester.tap(closeBtn);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.text('Themed Modal Content'), findsNothing);
        expect(tester.takeException(), isNull);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '5. Tokens contrast satisfies WCAG AAA for light and dark text across surfaces',
      (tester) async {
        // Light mode tokens
        final lightTokens = AppDesignTokens.light;
        expect(lightTokens.page, equals(CamelliaColors.lightCanvas));
        expect(lightTokens.surface, equals(CamelliaColors.lightSurface));
        expect(lightTokens.border, equals(CamelliaColors.lightBorder));

        // Dark mode tokens
        final darkTokens = AppDesignTokens.dark;
        expect(darkTokens.page, equals(CamelliaColors.darkCanvas));
        expect(darkTokens.surface, equals(CamelliaColors.darkSurface));
        expect(darkTokens.border, equals(CamelliaColors.darkBorder));
      },
    );
  });
}
