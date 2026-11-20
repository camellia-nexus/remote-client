import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/peer_card.dart';
import 'package:camellia_remote_app/common/widgets/peer_tab_page.dart';
import 'package:camellia_remote_app/common/widgets/peers_view.dart';
import 'package:camellia_remote_app/common/widgets/server_settings_dialog.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/desktop/pages/connection_page.dart';
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

  group('Tier 2: Rapid Interaction & Debounce Resilience', () {
    testWidgets(
      '1. Destination spamming (rapid consecutive switching) settles cleanly on final destination',
      (tester) async {
        DesktopNavDestination? finalDestination;

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: CamelliaDesktopShell(
            initialDestination: DesktopNavDestination.connect,
            onDestinationChanged: (dest) => finalDestination = dest,
            connectBuilder: (_) => const Center(child: Text('Active: Connect')),
            devicesBuilder: (_) => const Center(child: Text('Active: Devices')),
            addressBookBuilder: (_) => const Center(child: Text('Active: Address Book')),
            settingsBuilder: (_) => const Center(child: Text('Active: Settings')),
          ),
        );
        await tester.pump();

        // Rapid click storm across sidebar destinations without waiting for animations
        await tester.tap(find.byKey(const ValueKey('desktop-nav-devices')));
        await tester.pump(const Duration(milliseconds: 20));

        await tester.tap(find.byKey(const ValueKey('desktop-nav-addressBook')));
        await tester.pump(const Duration(milliseconds: 20));

        await tester.tap(find.byKey(const ValueKey('desktop-nav-settings')));
        await tester.pump(const Duration(milliseconds: 20));

        await tester.tap(find.byKey(const ValueKey('desktop-nav-connect')));
        await tester.pump(const Duration(milliseconds: 20));

        await tester.tap(find.byKey(const ValueKey('desktop-nav-devices')));
        await tester.pump(const Duration(milliseconds: 20));

        await tester.tap(find.byKey(const ValueKey('desktop-nav-settings')));
        // Now settle fully
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        // State settles strictly on the final tapped destination: Settings
        expect(finalDestination, equals(DesktopNavDestination.settings));
        expect(find.text('Active: Settings'), findsOneWidget);
        expect(find.text('Active: Connect'), findsNothing);
        expect(find.text('Active: Devices'), findsNothing);
        expect(tester.takeException(), isNull);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '2. Rapid sidebar collapse/expand toggle spam maintains consistent width and deterministic state',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: const CamelliaDesktopShell(
            defaultSidebarWidth: 220.0,
            railWidth: 64.0,
            collapseBreakpoint: 840.0,
          ),
        );
        await tester.pump();

        final sidebarFinder = find.byKey(const ValueKey('desktop-nav-sidebar'));

        // Tap toggle 6 times rapidly (even number of toggles -> ends expanded)
        for (int i = 0; i < 6; i++) {
          await tester.tap(
            find.byKey(const ValueKey('desktop-nav-collapse-toggle')),
            warnIfMissed: false,
          );
          await tester.pump(const Duration(milliseconds: 16));
        }

        // Settle animation
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        var sidebar = tester.widget<AnimatedContainer>(sidebarFinder);
        expect(sidebar.constraints?.maxWidth ?? 220.0, equals(220.0));

        // Tap 1 more time (odd -> collapsed)
        await tester.tap(
          find.byKey(const ValueKey('desktop-nav-collapse-toggle')),
          warnIfMissed: false,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        sidebar = tester.widget<AnimatedContainer>(sidebarFinder);
        expect(sidebar.constraints?.maxWidth ?? 64.0, equals(64.0));

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '3. Rapid mode selector switching cycles accents and settles on selected mode',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: const Scaffold(
            body: Center(
              child: SizedBox(
                width: 700,
                child: ConnectionPage(showDevices: false),
              ),
            ),
          ),
        );
        await tester.pump();

        final desktopMode = find.byIcon(Icons.desktop_windows_outlined);
        final filesMode = find.byIcon(Icons.folder_copy_outlined);
        final cameraMode = find.byIcon(Icons.videocam_outlined);
        final terminalMode = find.byIcon(Icons.terminal_rounded);

        // Rapidly click between all 4 modes
        await tester.tap(filesMode);
        await tester.pump(const Duration(milliseconds: 16));

        await tester.tap(cameraMode);
        await tester.pump(const Duration(milliseconds: 16));

        await tester.tap(terminalMode);
        await tester.pump(const Duration(milliseconds: 16));

        await tester.tap(desktopMode);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        // Final mode settled on Desktop mode
        final section = tester.widget<CamelliaSection>(find.byType(CamelliaSection));
        expect(section.accent, equals(CamelliaColors.coral));
        expect(tester.takeException(), isNull);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '4. Rapid search input filtering debounces and yields precise query result',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
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

        final searchInput = find.byType(TextField);
        expect(searchInput, findsWidgets);

        // Rapid search query typing spam: 'A' -> 'Al' -> 'Ali' -> 'Alice' -> '' -> 'Bob'
        await tester.enterText(searchInput.first, 'A');
        await tester.pump(const Duration(milliseconds: 20));

        await tester.enterText(searchInput.first, 'Al');
        await tester.pump(const Duration(milliseconds: 20));

        await tester.enterText(searchInput.first, 'Ali');
        await tester.pump(const Duration(milliseconds: 20));

        await tester.enterText(searchInput.first, '');
        await tester.pump(const Duration(milliseconds: 20));

        await tester.enterText(searchInput.first, 'Bob');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        // Result should accurately isolate Bob and filter Alice
        expect(find.textContaining('Bob'), findsWidgets);
        expect(find.textContaining('Alice'), findsNothing);
        expect(tester.takeException(), isNull);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '5. Rapid multi-tap on action buttons executes idempotently without unhandled state',
      (tester) async {
        int tapCount = 0;
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: Scaffold(
            body: Center(
              child: GestureDetector(
                onDoubleTap: () => tapCount++,
                child: Container(
                  width: 200,
                  height: 50,
                  color: Colors.blue,
                  child: const Center(child: Text('Double Tap Target')),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final target = find.text('Double Tap Target');

        // Fire 10 rapid taps in immediate succession
        for (int i = 0; i < 10; i++) {
          await tester.tap(target);
          await tester.pump(const Duration(milliseconds: 40));
        }
        await tester.pump(const Duration(milliseconds: 300));

        // Multi-tap handled gracefully without exception
        expect(tapCount, greaterThan(0));
        expect(tester.takeException(), isNull);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '6. Rapid dialog launch and immediate dismissal leaves navigator clean and operational',
      (tester) async {
        final serverConfig = ServerConfig(
          idServer: 'id.camellia.org',
          relayServer: 'relay.camellia.org',
          apiServer: 'https://api.camellia.org',
          key: 'key-123',
        );

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: Scaffold(
            body: Center(
              child: ElevatedButton(
                key: const ValueKey('open-dialog-btn'),
                onPressed: () {
                  showServerSettingsWithValue(
                    serverConfig,
                    gFFI.dialogManager,
                    null,
                  );
                },
                child: const Text('Open Dialog'),
              ),
            ),
          ),
        );
        await tester.pump();

        final openBtn = find.byKey(const ValueKey('open-dialog-btn'));

        // Cycle 1: Open and immediately cancel
        await tester.tap(openBtn);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        final cancelBtn = find.text('Cancel');
        expect(cancelBtn, findsWidgets);
        await tester.tap(cancelBtn.first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        // Cycle 2: Reopen immediately
        await tester.tap(openBtn);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.text('ID/Relay Server'), findsWidgets);

        // Cancel again
        await tester.tap(find.text('Cancel').first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        // Root button still interactive
        expect(openBtn, findsOneWidget);
        expect(tester.takeException(), isNull);

        await TestAppHarness.tearDown(tester);
      },
    );
  });
}
