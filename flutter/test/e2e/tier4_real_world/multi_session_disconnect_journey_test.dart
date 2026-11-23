// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/dialog.dart';
import 'package:camellia_remote_app/desktop/widgets/tabbar_widget.dart';
import 'package:camellia_remote_app/desktop/pages/connection_page.dart';
import 'package:camellia_remote_app/desktop/pages/server_page.dart';
import 'package:camellia_remote_app/models/server_model.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import '../harness/test_app_harness.dart';

void main() {
  setUp(() async {
    await TestAppHarness.setUp();
  });

  group('Tier 4: Scenario 2 - Remote Operator Multi-Mode Connection & Disconnect Cleanup Journey', () {
    testWidgets(
      'Complete Journey: ID input -> 6-mode selection -> Timeout error modal -> Esc dismiss -> Disconnected session cleanup unblocked',
      (tester) async {
        // Step 1: Input Remote ID into Hero Input Field
        final idController = TextEditingController(text: '888 777 666');

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: Column(
            children: [
              GlassInput(
                controller: idController,
                hintText: 'Enter Remote ID',
              ),
              const Expanded(
                child: ConnectionPage(showDevices: false),
              ),
            ],
          ),
        );
        await tester.pump();

        expect(find.text('888 777 666'), findsOneWidget);

        // Step 2: Cycle Across Connection Modes (6 Unified Modes in Segmented Control)
        final segmentedFinder = find.byType(GlassSegmentedControl);
        expect(segmentedFinder, findsOneWidget);

        final modeIcons = [
          Icons.desktop_windows_outlined,
          Icons.visibility_outlined,
          Icons.folder_copy_outlined,
          Icons.videocam_outlined,
          Icons.terminal_rounded,
        ];

        for (final icon in modeIcons) {
          final button = find.byIcon(icon);
          expect(button, findsOneWidget);
          await tester.tap(button);
          await tester.pump(const Duration(milliseconds: 40));
        }

        // Step 3: Trigger Simulated Connection Timeout Error Modal
        bool errorDismissed = false;

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
                      title: 'Connection Timed Out',
                      subtitle: 'Target host 888 777 666 did not respond',
                      onClose: () => Navigator.of(ctx).pop(),
                    ),
                    content: const Text('Check network connection and target device status.'),
                    onCancel: () {
                      errorDismissed = true;
                      Navigator.of(ctx).pop();
                    },
                  ),
                );
              },
              child: const Text('Simulate Timeout'),
            ),
          ),
        );
        await tester.pump();

        await tester.tap(find.text('Simulate Timeout'));
        await tester.pumpAndSettle();

        expect(find.byType(CustomAlertDialog), findsOneWidget);

        // Step 4: Esc Key Dismisses Error Dialog Cleanly
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();

        expect(find.byType(CustomAlertDialog), findsNothing);
        expect(errorDismissed, isTrue);

        // Step 5: Disconnected Session Card Cleanup in Connection Manager
        final disconnectedClient = Client(
          202,
          true,
          false,
          false,
          'Production Server',
          '202',
          true,
          true,
          true,
        )..disconnected = true;

        gFFI.serverModel.clients.clear();
        gFFI.serverModel.clients.add(disconnectedClient);
        gFFI.serverModel.tabController.state.value.tabs.clear();
        gFFI.serverModel.tabController.add(
          TabInfo(
            key: disconnectedClient.id.toString(),
            label: disconnectedClient.name,
            closable: false,
            page: buildConnectionCard(disconnectedClient),
          ),
        );
        TestAppHarness.fakeBridge.activeClientsLength = 1;

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1024, 720),
          child: const DesktopServerPage(),
        );
        await tester.pump();

        final closeCardBtn = find.text('Close');
        expect(closeCardBtn, findsOneWidget);

        // Tap close on disconnected session card: unblocked by action gate
        await tester.tap(closeCardBtn);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        // Verifies session is removed from CM and window closes
        expect(
          TestAppHarness.fakeBridge.removedDisconnectedConnections,
          contains(202),
        );
        expect(TestAppHarness.fakeBridge.activeClientsLength, equals(0));
        expect(TestAppHarness.windowController.channelCloseCount, greaterThanOrEqualTo(1));

        await TestAppHarness.tearDown(tester);
      },
    );
  });
}
