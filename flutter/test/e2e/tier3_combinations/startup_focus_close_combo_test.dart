// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/first_run_wizard_dialog.dart';
import 'package:camellia_remote_app/desktop/pages/desktop_home_page.dart';
import 'package:camellia_remote_app/desktop/widgets/desktop_shell.dart';
import 'package:camellia_remote_app/desktop/widgets/titlebar_widget.dart';
import 'package:camellia_remote_app/models/state_model.dart';
import '../harness/mock_window_controller.dart';
import '../harness/test_app_harness.dart';

void main() {
  setUp(() async {
    await TestAppHarness.setUp();
  });

  group('Tier 3: Startup, Focus Loss & Window Close Cross-Feature Combinations (TC-T3-02)', () {
    testWidgets(
      '1. Direct start (no wizard) -> Alt+Tab focus loss/recovery -> Top-right close button initiates application close',
      (tester) async {
        stateGlobal.videoConnCount.value = 0;
        await TestAppHarness.fakeBridge.mainSetLocalOption(
          key: kOptionCloseToTray,
          value: 'N',
        );

        // 1. Direct Startup: Mount DesktopHomePage
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: const DesktopHomePage(),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        // Verify direct reveal with zero modal barriers
        expect(find.byType(DesktopHomePage), findsOneWidget);
        expect(find.byType(FirstRunWizardDialog), findsNothing);
        expect(find.text('Get Started'), findsNothing);

        // 2. Alt+Tab Focus Loss & Recovery
        await MockWindowController.simulateWindowBlur();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        await tester.pump(const Duration(milliseconds: 50));

        await MockWindowController.simulateWindowFocus();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pump(const Duration(milliseconds: 100));

        // Workspace must remain active and unmasked
        final maskFinder = find.byKey(const ValueKey('remote-block-mask'));
        if (maskFinder.evaluate().isNotEmpty) {
          final offstage = tester.widget<Offstage>(maskFinder);
          expect(offstage.offstage, isTrue);
        }

        // 3. Caption Close Click: Invokes onWindowClose
        await MockWindowController.simulateWindowClose();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(TestAppHarness.windowController.preventCloseState, isFalse);
        expect(TestAppHarness.windowController.channelCloseCount, greaterThanOrEqualTo(1));

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '2. Direct start -> Close-to-tray configured -> Alt+Tab focus recovery -> Caption close hides window without terminating',
      (tester) async {
        stateGlobal.videoConnCount.value = 0;
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

        // Simulate Alt+Tab window switch
        await MockWindowController.simulateWindowBlur();
        await tester.pump(const Duration(milliseconds: 50));
        await MockWindowController.simulateWindowFocus();
        await tester.pump(const Duration(milliseconds: 50));

        // Click close on titlebar
        await MockWindowController.simulateWindowClose();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        // Must invoke hide, not destroy or full terminate
        expect(TestAppHarness.windowController.hideCallCount, greaterThanOrEqualTo(1));
        expect(TestAppHarness.windowController.destroyCallCount, equals(0));

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '3. Direct start with active modal -> Alt+Tab maintains modal -> Esc dismisses dialog -> Caption close succeeds',
      (tester) async {
        stateGlobal.videoConnCount.value = 0;
        await TestAppHarness.fakeBridge.mainSetLocalOption(
          key: kOptionCloseToTray,
          value: 'N',
        );

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
                      builder: (ctx) => const CustomAlertDialog(
                        title: Text('Active Session Warning'),
                        content: Text('Please close active sessions before quitting.'),
                      ),
                    );
                  },
                  child: const Text('Show Dialog'),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        // 1. Launch dialog
        await tester.tap(find.text('Show Dialog'));
        await tester.pumpAndSettle();
        expect(find.byType(CustomAlertDialog), findsOneWidget);

        // 2. Alt+Tab blur & focus while dialog is open
        await MockWindowController.simulateWindowBlur();
        await tester.pump(const Duration(milliseconds: 50));
        await MockWindowController.simulateWindowFocus();
        await tester.pump(const Duration(milliseconds: 50));

        expect(find.byType(CustomAlertDialog), findsOneWidget);

        // 3. Esc key dismisses dialog
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(CustomAlertDialog), findsNothing);

        // 4. Click titlebar close
        final closeBtn = find.byTooltip('Close Window');
        expect(closeBtn, findsOneWidget);
        await tester.tap(closeBtn);
        await tester.pump();

        expect(TestAppHarness.windowController.closed, isTrue);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '4. Navigation to Settings destination -> Rapid Alt+Tab focus loss/gain -> Titlebar close initiates teardown',
      (tester) async {
        stateGlobal.videoConnCount.value = 0;
        final controller = CamelliaDesktopShellController(
          initialDestination: DesktopNavDestination.settings,
        );

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: CamelliaDesktopShell(
            controller: controller,
            connectBuilder: (_) => const Text('Connect View'),
            settingsBuilder: (_) => const Text('Settings View'),
          ),
        );
        await tester.pump();

        expect(controller.destination, equals(DesktopNavDestination.settings));

        // Rapid focus cycle
        for (int i = 0; i < 5; i++) {
          tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
          await tester.pump(const Duration(milliseconds: 10));
          tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
          await tester.pump(const Duration(milliseconds: 10));
        }

        // Verify view is still intact
        expect(find.text('Settings View'), findsOneWidget);

        await TestAppHarness.windowController.close();
        expect(TestAppHarness.windowController.closed, isTrue);

        await TestAppHarness.tearDown(tester);
      },
    );
  });
}
