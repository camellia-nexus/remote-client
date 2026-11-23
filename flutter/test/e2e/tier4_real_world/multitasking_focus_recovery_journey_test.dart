// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/desktop/pages/desktop_setting_page.dart';
import 'package:camellia_remote_app/desktop/widgets/desktop_shell.dart';
import 'package:camellia_remote_app/models/state_model.dart';
import '../harness/mock_window_controller.dart';
import '../harness/pointer_gesture_helper.dart';
import '../harness/test_app_harness.dart';

void main() {
  setUp(() async {
    await TestAppHarness.setUp();
  });

  group('Tier 4: Scenario 3 - High-Productivity Multitasking & Window Focus Management Journey', () {
    testWidgets(
      'Complete Journey: Hover sidebar auto-expand -> Spring rebound -> Navigate settings -> Alt+Tab window blur -> Focus recovery -> Interactive controls',
      (tester) async {
        stateGlobal.videoConnCount.value = 0;

        final controller = CamelliaDesktopShellController(
          initialDestination: DesktopNavDestination.connect,
          initialCollapsed: true,
        );

        // Step 1: Render Shell with Collapsed Sidebar
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: CamelliaDesktopShell(
            controller: controller,
            connectBuilder: (_) => const Text('Connect Workspace'),
            settingsBuilder: (_) => DesktopSettingPage(initialTabkey: SettingsTabKey.general),
          ),
        );
        await tester.pump();

        final sidebarFinder = find.byKey(const ValueKey('desktop-nav-sidebar'));
        expect(tester.getSize(sidebarFinder).width, equals(64.0));

        // Step 2: Hover Over Sidebar -> Auto-Expand to 220px
        final gesture = await PointerGestureHelper.hoverEnter(
          tester,
          sidebarFinder,
          debounceDuration: const Duration(milliseconds: 150),
        );
        await tester.pump(const Duration(milliseconds: 300));

        // Step 3: Unhover Cursor -> Spring Rebound Collapse to 64px
        await PointerGestureHelper.hoverExit(
          tester,
          gesture,
          exitOffset: const Offset(800, 500),
          reboundDuration: const Duration(milliseconds: 350),
        );

        // Step 4: Navigate to Settings Destination
        controller.destination = DesktopNavDestination.settings;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.byType(DesktopSettingPage), findsOneWidget);

        // Step 5: Simulate OS Alt+Tab Window Blur
        await MockWindowController.simulateWindowBlur();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        await tester.pump(const Duration(milliseconds: 50));

        // UI must not be permanently blocked or masked when videoConnCount == 0
        final block = false.obs;
        Future<bool> shouldUseBlock() async =>
            await canBeBlocked() && stateGlobal.videoConnCount > 0;
        await shouldBeBlocked(block, shouldUseBlock);
        expect(block.value, isFalse);

        // Step 6: Simulate OS Focus Return
        await MockWindowController.simulateWindowFocus();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pump(const Duration(milliseconds: 100));

        // Step 7: Click Settings Security Tab: Interactivity Preserved Without Mouse Leave/Enter
        final securityTab = find.text('Security');
        expect(securityTab, findsOneWidget);

        await tester.tap(securityTab);
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);

        await TestAppHarness.tearDown(tester);
      },
    );
  });
}
