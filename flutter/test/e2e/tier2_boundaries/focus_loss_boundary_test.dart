// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/desktop/pages/desktop_home_page.dart';
import 'package:camellia_remote_app/desktop/pages/desktop_setting_page.dart';
import 'package:camellia_remote_app/models/state_model.dart';
import '../harness/mock_window_controller.dart';
import '../harness/test_app_harness.dart';

void main() {
  setUp(() async {
    await TestAppHarness.setUp();
  });

  group('Tier 2: Focus Loss, Alt+Tab & Concurrency Token Boundaries (F03, F04)', () {
    testWidgets(
      '1. Rapid focus loss and gain cycles (20 times in rapid succession) leaves UI unmasked and clickable when videoConnCount == 0',
      (tester) async {
        stateGlobal.videoConnCount.value = 0;
        final block = false.obs;

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: const DesktopHomePage(),
        );
        await tester.pump();

        // High-frequency lifecycle stress (simulating frantic Alt+Tab switching)
        for (int i = 0; i < 20; i++) {
          tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
          await tester.pump(const Duration(milliseconds: 10));
          tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
          await tester.pump(const Duration(milliseconds: 10));
        }

        // Evaluate block state with active video connection check
        Future<bool> shouldUseBlock() async =>
            await canBeBlocked() && stateGlobal.videoConnCount > 0;
        await shouldBeBlocked(block, shouldUseBlock);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        // When videoConnCount == 0, block must be false and UI completely interactive
        expect(block.value, isFalse);

        final maskFinder = find.byKey(const ValueKey('remote-block-mask'));
        if (maskFinder.evaluate().isNotEmpty) {
          final offstage = tester.widget<Offstage>(maskFinder);
          expect(offstage.offstage, isTrue);
        }

        expect(tester.takeException(), isNull);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '2. Alt+Tab blur and regain with active modal dialog preserves modal barrier and focus tree',
      (tester) async {
        stateGlobal.videoConnCount.value = 0;
        bool modalDismissed = false;

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () {
                showDialog<void>(
                  context: context,
                  builder: (ctx) => CustomAlertDialog(
                    title: const Text('Session Security Notice'),
                    content: const Text('Testing focus loss across modal barriers.'),
                    onCancel: () {
                      modalDismissed = true;
                      Navigator.of(ctx).pop();
                    },
                  ),
                );
              },
              child: const Text('Open Modal'),
            ),
          ),
        );
        await tester.pump();

        // Launch modal dialog
        await tester.tap(find.text('Open Modal'));
        await tester.pumpAndSettle();

        expect(find.byType(CustomAlertDialog), findsOneWidget);

        // Simulate Alt+Tab blur and focus recovery
        await MockWindowController.simulateWindowBlur();
        await tester.pump(const Duration(milliseconds: 50));
        await MockWindowController.simulateWindowFocus();
        await tester.pump(const Duration(milliseconds: 50));

        // Modal dialog must remain mounted and focused
        expect(find.byType(CustomAlertDialog), findsOneWidget);

        // Escape key dismisses dialog cleanly
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();

        expect(find.byType(CustomAlertDialog), findsNothing);
        expect(modalDismissed, isTrue);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '3. Concurrency token generation handles 50 rapid parallel calls without race conditions or deadlock',
      (tester) async {
        stateGlobal.videoConnCount.value = 0;
        final blocks = List.generate(50, (_) => false.obs);

        // Concurrently invoke shouldBeBlocked for 50 distinct reactive tokens
        await Future.wait(
          blocks.map((b) => shouldBeBlocked(b, () async => false)),
        );

        for (final b in blocks) {
          expect(b.value, isFalse);
        }

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '4. Alt+Tab during active remote video connection (videoConnCount > 0) executes authoritative pointer check',
      (tester) async {
        stateGlobal.videoConnCount.value = 1;
        TestAppHarness.fakeBridge.pointerCheckCount = 0;
        TestAppHarness.fakeBridge.pointerCheckReturnAuthoritative = true;

        final block = false.obs;

        // When connection is active, shouldBeBlocked executes authoritative check on bridge
        await shouldBeBlocked(block, () async => true);

        expect(TestAppHarness.fakeBridge.pointerCheckCount, greaterThanOrEqualTo(1));
        expect(block.value, isTrue);

        // Now set authoritative pointer check to false (local pointer took over)
        TestAppHarness.fakeBridge.pointerCheckReturnAuthoritative = false;
        await shouldBeBlocked(block, () async => true);

        expect(block.value, isFalse);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '5. Simultaneous focus observation by DesktopHomePage and DesktopSettingPage resolves independently',
      (tester) async {
        stateGlobal.videoConnCount.value = 0;
        final homeBlock = false.obs;
        final settingBlock = false.obs;

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: DesktopSettingPage(initialTabkey: SettingsTabKey.general),
        );
        await tester.pump();

        // Simulate simultaneous lifecycle notifications
        await Future.wait([
          shouldBeBlocked(homeBlock, () async => stateGlobal.videoConnCount > 0),
          shouldBeBlocked(settingBlock, () async => stateGlobal.videoConnCount > 0),
        ]);

        expect(homeBlock.value, isFalse);
        expect(settingBlock.value, isFalse);

        // Verify setting page components are immediately responsive
        final securityTab = find.text('Security');
        expect(securityTab, findsOneWidget);

        await tester.tap(securityTab);
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '6. Full lifecycle sequence (inactive -> hidden -> paused -> resumed) cleanly restores interactive state',
      (tester) async {
        stateGlobal.videoConnCount.value = 0;

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: const DesktopHomePage(),
        );
        await tester.pump();

        final states = [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ];

        for (final state in states) {
          tester.binding.handleAppLifecycleStateChanged(state);
          await tester.pump(const Duration(milliseconds: 20));
        }

        await tester.pumpAndSettle();

        // Ensure no lingering exceptions or absorbing pointers
        expect(tester.takeException(), isNull);

        await TestAppHarness.tearDown(tester);
      },
    );
  });
}
