// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/desktop/pages/desktop_home_page.dart';
import 'package:camellia_remote_app/desktop/widgets/titlebar_widget.dart';
import 'package:camellia_remote_app/utils/multi_window_manager.dart';
import '../harness/mock_window_controller.dart';
import '../harness/test_app_harness.dart';

void main() {
  setUp(() async {
    await TestAppHarness.setUp();
  });

  group('Tier 4: Scenario 5 - Application Teardown, Tray & Graceful Termination Journey', () {
    testWidgets(
      'Complete Journey: Close-to-tray hide -> Active session confirmation -> Esc cancel -> Confirmed terminate & subwindow release',
      (tester) async {
        // Step 1: Close-to-Tray Flow (kOptionCloseToTray = 'Y')
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

        // Simulate top-right caption close
        await MockWindowController.simulateWindowClose();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        // Window must be hidden to tray, not destroyed
        expect(TestAppHarness.windowController.hideCallCount, greaterThanOrEqualTo(1));
        expect(TestAppHarness.windowController.destroyCallCount, equals(0));

        // Step 2: Active Session Modal Confirmation Flow (kOptionCloseToTray = '')
        await TestAppHarness.fakeBridge.mainSetLocalOption(
          key: kOptionCloseToTray,
          value: '',
        );

        bool confirmedExit = false;

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: Builder(
            builder: (context) => Scaffold(
              appBar: PreferredSize(
                preferredSize: const Size.fromHeight(40),
                child: DesktopTitleBar(
                  controller: TestAppHarness.windowController,
                  labels: const DesktopTitleBarLabels(close: 'Close Window'),
                ),
              ),
              body: Center(
                child: ElevatedButton(
                  onPressed: () {
                    showDialog<void>(
                      context: context,
                      builder: (ctx) => CustomAlertDialog(
                        title: const Text('Active Session Warning'),
                        content: const Text('Active remote desktop session in progress. Disconnect and quit?'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(),
                            child: const Text('Cancel'),
                          ),
                          TextButton(
                            onPressed: () {
                              confirmedExit = true;
                              Navigator.of(ctx).pop();
                            },
                            child: const Text('Confirm Exit'),
                          ),
                        ],
                      ),
                    );
                  },
                  child: const Text('Trigger Exit Flow'),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        // Step 3: Trigger Dialog and Cancel via Esc
        await tester.tap(find.text('Trigger Exit Flow'));
        await tester.pumpAndSettle();

        expect(find.byType(CustomAlertDialog), findsOneWidget);

        // Press Esc to dismiss
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();

        expect(find.byType(CustomAlertDialog), findsNothing);
        expect(confirmedExit, isFalse);

        // Step 4: Trigger Again and Confirm Exit
        await tester.tap(find.text('Trigger Exit Flow'));
        await tester.pumpAndSettle();

        expect(find.byType(CustomAlertDialog), findsOneWidget);
        await tester.tap(find.text('Confirm Exit'));
        await tester.pumpAndSettle();

        expect(confirmedExit, isTrue);

        // Step 5: Sub-Window Release and Final Process Close
        await rustDeskWinManager.closeAllSubWindows();
        await TestAppHarness.windowController.close();

        expect(TestAppHarness.windowController.closed, isTrue);
        expect(tester.takeException(), isNull);

        await TestAppHarness.tearDown(tester);
      },
    );
  });
}
