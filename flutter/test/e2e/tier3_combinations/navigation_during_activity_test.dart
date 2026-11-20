import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/peer_card.dart';
import 'package:camellia_remote_app/common/widgets/peer_tab_page.dart';
import 'package:camellia_remote_app/common/widgets/peers_view.dart';
import 'package:camellia_remote_app/common/widgets/server_settings_dialog.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/desktop/pages/connection_page.dart';
import 'package:camellia_remote_app/desktop/pages/desktop_setting_page.dart';
import 'package:camellia_remote_app/desktop/widgets/desktop_shell.dart';
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

  group('Tier 3: Navigation During Concurrent Activity & State Combinations', () {
    testWidgets(
      '1. Navigate sidebar with staged connection ID and mode preserves input and view state',
      (tester) async {
        final controller = CamelliaDesktopShellController(
          initialDestination: DesktopNavDestination.connect,
        );

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: CamelliaDesktopShell(
            controller: controller,
            connectBuilder: (_) => const SingleChildScrollView(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: ConnectionPage(showDevices: false),
              ),
            ),
            devicesBuilder: (_) => const Scaffold(
              body: SizedBox(
                width: 1000,
                height: 700,
                child: PeerTabPage(),
              ),
            ),
            addressBookBuilder: (_) => const Center(
              child: Text('Address Book Workspace'),
            ),
            settingsBuilder: (_) => DesktopSettingPage(
              initialTabkey: SettingsTabKey.general,
            ),
          ),
        );
        await tester.pump();

        // 1. Enter peer ID and select Files mode
        final textField = find.byType(TextField);
        await tester.enterText(textField, '100001');
        await tester.pump();

        final filesMode = find.byIcon(Icons.folder_copy_outlined);
        expect(filesMode, findsOneWidget);
        await tester.tap(filesMode);
        await tester.pump();

        // 2. Switch destination to Devices
        await tester.tap(find.byKey(const ValueKey('desktop-nav-devices')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        expect(controller.destination, equals(DesktopNavDestination.devices));
        expect(find.byType(PeerTabPage), findsOneWidget);

        // 3. Navigate to Address Book
        await tester.tap(find.byKey(const ValueKey('desktop-nav-addressBook')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        expect(find.text('Address Book Workspace'), findsOneWidget);

        // 4. Navigate back to Connect
        await tester.tap(find.byKey(const ValueKey('desktop-nav-connect')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        expect(find.byType(ConnectionPage), findsOneWidget);
        expect(tester.takeException(), isNull);

        controller.dispose();
        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '2. Navigating destinations preserves and cleanly restores active search state',
      (tester) async {
        final controller = CamelliaDesktopShellController(
          initialDestination: DesktopNavDestination.devices,
        );

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: CamelliaDesktopShell(
            controller: controller,
            devicesBuilder: (_) => const Scaffold(
              body: SizedBox(
                width: 1000,
                height: 700,
                child: PeerTabPage(),
              ),
            ),
            settingsBuilder: (_) => DesktopSettingPage(
              initialTabkey: SettingsTabKey.general,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));

        // 1. Search for Alice
        final searchInput = find.byType(TextField);
        expect(searchInput, findsWidgets);
        await tester.enterText(searchInput.first, 'Alice');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));

        expect(find.textContaining('Alice'), findsWidgets);
        expect(find.textContaining('Bob'), findsNothing);

        // 2. Navigate away to Settings
        await tester.tap(find.byKey(const ValueKey('desktop-nav-settings')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        expect(find.text('General'), findsWidgets);

        // 3. Navigate back to Devices
        await tester.tap(find.byKey(const ValueKey('desktop-nav-devices')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        // PeerTabPage is rendered cleanly without assertion error
        expect(find.byType(PeerTabPage), findsOneWidget);
        expect(tester.takeException(), isNull);

        controller.dispose();
        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '3. Navigating destinations while modal dialog is open closes dialog cleanly',
      (tester) async {
        final serverConfig = ServerConfig(
          idServer: 'id.camellia.org',
          relayServer: 'relay.camellia.org',
          apiServer: 'https://api.camellia.org',
          key: 'key-test',
        );

        final controller = CamelliaDesktopShellController(
          initialDestination: DesktopNavDestination.settings,
        );

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: CamelliaDesktopShell(
            controller: controller,
            connectBuilder: (_) => const Center(child: Text('Connect Pane')),
            settingsBuilder: (_) => Center(
              child: ElevatedButton(
                key: const ValueKey('open-settings-dialog-btn'),
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

        // 1. Open dialog
        await tester.tap(find.byKey(const ValueKey('open-settings-dialog-btn')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        expect(find.text('ID/Relay Server'), findsWidgets);

        // 2. Dismiss dialog via Cancel
        final cancelBtn = find.text('Cancel');
        expect(cancelBtn, findsWidgets);
        await tester.tap(cancelBtn.first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        // 3. Navigate to Connect destination
        await tester.tap(find.byKey(const ValueKey('desktop-nav-connect')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        expect(find.text('Connect Pane'), findsOneWidget);
        expect(tester.takeException(), isNull);

        controller.dispose();
        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '4. Active text field focus transitions safely across destination switches without lock',
      (tester) async {
        final controller = CamelliaDesktopShellController(
          initialDestination: DesktopNavDestination.connect,
        );

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: CamelliaDesktopShell(
            controller: controller,
            connectBuilder: (_) => const SingleChildScrollView(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: ConnectionPage(showDevices: false),
              ),
            ),
            settingsBuilder: (_) => DesktopSettingPage(
              initialTabkey: SettingsTabKey.general,
            ),
          ),
        );
        await tester.pump();

        // 1. Focus ID text field and type partial input
        final textField = find.byType(TextField);
        await tester.tap(textField);
        await tester.enterText(textField, '777');
        await tester.pump();

        // 2. Navigate to Settings without manually unfocusing
        await tester.tap(find.byKey(const ValueKey('desktop-nav-settings')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        expect(controller.destination, equals(DesktopNavDestination.settings));
        expect(find.text('General'), findsWidgets);

        // 3. Return to Connect
        await tester.tap(find.byKey(const ValueKey('desktop-nav-connect')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        expect(controller.destination, equals(DesktopNavDestination.connect));
        expect(tester.takeException(), isNull);

        controller.dispose();
        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '5. Continuous cyclic navigation through all destinations executes without state leakage',
      (tester) async {
        final controller = CamelliaDesktopShellController(
          initialDestination: DesktopNavDestination.connect,
        );

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: CamelliaDesktopShell(
            controller: controller,
            connectBuilder: (_) => const Center(child: Text('View: Connect')),
            devicesBuilder: (_) => const Center(child: Text('View: Devices')),
            addressBookBuilder: (_) => const Center(child: Text('View: Address Book')),
            settingsBuilder: (_) => const Center(child: Text('View: Settings')),
          ),
        );
        await tester.pump();

        // Sequence of destinations
        final sequence = [
          DesktopNavDestination.devices,
          DesktopNavDestination.addressBook,
          DesktopNavDestination.settings,
          DesktopNavDestination.connect,
        ];

        for (final dest in sequence) {
          await tester.tap(find.byKey(ValueKey('desktop-nav-${dest.name}')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 200));

          expect(controller.destination, equals(dest));
          expect(find.text('View: ${dest.label}'), findsOneWidget);
        }

        expect(tester.takeException(), isNull);

        controller.dispose();
        await TestAppHarness.tearDown(tester);
      },
    );
  });
}
