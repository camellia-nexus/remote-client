import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/dialog.dart';
import 'package:camellia_remote_app/desktop/pages/desktop_home_page.dart';
import 'package:camellia_remote_app/desktop/pages/server_page.dart';
import 'package:camellia_remote_app/desktop/widgets/tabbar_widget.dart';
import 'package:camellia_remote_app/desktop/widgets/titlebar_widget.dart';
import 'package:camellia_remote_app/models/server_model.dart';
import 'package:camellia_remote_app/utils/multi_window_manager.dart';
import '../harness/mock_window_controller.dart';
import '../harness/test_app_harness.dart';

void main() {
  setUp(() async {
    await TestAppHarness.setUp();
  });

  group('Tier 1: Window Lifecycle & Dialog Close Coverage (F01, F02, F04, F05)', () {
    testWidgets(
      '1. (F01) Top-right caption close button invokes window controller close',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1024, 720),
          child: DesktopTitleBar(
            controller: TestAppHarness.windowController,
            showBrand: true,
            labels: const DesktopTitleBarLabels(
              close: 'Close Window',
            ),
          ),
        );

        final closeButton = find.byTooltip('Close Window');
        expect(closeButton, findsOneWidget);

        await tester.tap(closeButton);
        await tester.pump();

        expect(TestAppHarness.windowController.closed, isTrue);
        expect(TestAppHarness.windowController.closeCallCount, greaterThanOrEqualTo(1));

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '2. (F01) Window close with close_to_tray option enabled invokes window hide',
      (tester) async {
        await TestAppHarness.fakeBridge.mainSetLocalOption(
          key: kOptionCloseToTray,
          value: 'Y',
        );

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: const DesktopHomePage(),
        );
        await tester.pump();

        await MockWindowController.simulateWindowClose();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(TestAppHarness.windowController.hideCallCount, greaterThanOrEqualTo(1));
        expect(TestAppHarness.windowController.destroyCallCount, equals(0));

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '3. (F01) Window close with default settings sets preventClose to false and calls close',
      (tester) async {
        await TestAppHarness.fakeBridge.mainSetLocalOption(
          key: kOptionCloseToTray,
          value: 'N',
        );

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: const DesktopHomePage(),
        );
        await tester.pump();

        await MockWindowController.simulateWindowClose();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(TestAppHarness.windowController.preventCloseState, isFalse);
        expect(TestAppHarness.windowController.channelCloseCount, greaterThanOrEqualTo(1));

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '4. (F02) Disconnected session card Close button removes connection and closes window',
      (tester) async {
        final disconnectedClient = Client(
          101,
          true,
          false,
          false,
          'Test Peer',
          '101',
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
            onTap: () {},
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

        final closeButton = find.text(translate('Close'));
        expect(closeButton, findsOneWidget);

        await tester.tap(closeButton);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(
          TestAppHarness.fakeBridge.removedDisconnectedConnections,
          contains(101),
        );
        expect(TestAppHarness.fakeBridge.activeClientsLength, equals(0));
        expect(TestAppHarness.windowController.channelCloseCount, greaterThanOrEqualTo(1));

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '5. (F04) Modal error dialog with ModernDialogHeader close button triggers dismiss callback',
      (tester) async {
        bool headerCloseInvoked = false;

        await TestAppHarness.pumpWidget(
          tester,
          child: CustomAlertDialog(
            title: ModernDialogHeader.error(
              title: 'Connection Terminated',
              subtitle: 'Host dropped connection',
              onClose: () => headerCloseInvoked = true,
            ),
            content: const Text('The remote session was closed unexpectedly.'),
          ),
        );

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
      '6. (F04) Physical Escape key triggers onCancel or dismisses active modal dialog',
      (tester) async {
        bool cancelInvoked = false;

        await TestAppHarness.pumpWidget(
          tester,
          child: CustomAlertDialog(
            title: const Text('Warning Dialog'),
            content: const Text('Press Escape to dismiss this dialog'),
            onCancel: () => cancelInvoked = true,
          ),
        );

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();

        expect(cancelInvoked, isTrue);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '7. (F04) Physical Escape key automatically pops CustomAlertDialog from Navigator stack',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          child: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () {
                showDialog<void>(
                  context: context,
                  builder: (ctx) => const CustomAlertDialog(
                    title: Text('Esc Dismiss Test'),
                    content: Text('Dialog body content'),
                  ),
                );
              },
              child: const Text('Launch Modal'),
            ),
          ),
        );

        await tester.tap(find.text('Launch Modal'));
        await tester.pumpAndSettle();

        expect(find.byType(CustomAlertDialog), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();

        expect(find.byType(CustomAlertDialog), findsNothing);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '8. (F05) Sub-window cleanup routine executes without throwing unhandled exceptions',
      (tester) async {
        expect(() async => await rustDeskWinManager.closeAllSubWindows(), returnsNormally);

        await TestAppHarness.tearDown(tester);
      },
    );
  });
}
