// ignore_for_file: deprecated_member_use
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/desktop/widgets/desktop_shell.dart';
import '../harness/pointer_gesture_helper.dart';
import '../harness/test_app_harness.dart';

void main() {
  setUp(() async {
    await TestAppHarness.setUp();
  });

  group('Tier 1: Sidebar Dynamic Hover & Redundancy Removal Coverage (F13, F14)', () {
    testWidgets(
      '1. (F13) Streamlined sidebar displays connect and settings and omits redundant devices and addressBook destinations',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: CamelliaDesktopShell(
            initialDestination: DesktopNavDestination.connect,
            connectBuilder: (_) => const Text('Connect View'),
            settingsBuilder: (_) => const Text('Settings View'),
          ),
        );
        await tester.pump();

        // Connect and Settings destinations must be present
        expect(find.byKey(const ValueKey('desktop-nav-connect')), findsOneWidget);
        expect(find.byKey(const ValueKey('desktop-nav-settings')), findsOneWidget);

        // Redundant devices and addressBook items must be removed from the sidebar rail
        expect(find.byKey(const ValueKey('desktop-nav-devices')), findsNothing);
        expect(find.byKey(const ValueKey('desktop-nav-addressBook')), findsNothing);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '2. (F13) DesktopNavDestination enum preserves 4 members with stable indexing for test and model compatibility',
      (tester) async {
        expect(DesktopNavDestination.values.length, equals(4));
        expect(DesktopNavDestination.values[0], equals(DesktopNavDestination.connect));
        expect(DesktopNavDestination.values[1], equals(DesktopNavDestination.devices));
        expect(DesktopNavDestination.values[2], equals(DesktopNavDestination.addressBook));
        expect(DesktopNavDestination.values[3], equals(DesktopNavDestination.settings));

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '3. (F14) Moving mouse pointer into collapsed sidebar rail auto-expands width to 220px after debounce',
      (tester) async {
        final controller = CamelliaDesktopShellController(
          initialDestination: DesktopNavDestination.connect,
          initialCollapsed: true,
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

        final sidebarFinder = find.byKey(const ValueKey('desktop-nav-sidebar'));
        expect(sidebarFinder, findsOneWidget);

        // Initially collapsed to 64px
        expect(tester.getSize(sidebarFinder).width, equals(64.0));

        // Hover mouse pointer over the sidebar
        final gesture = await PointerGestureHelper.hoverEnter(
          tester,
          sidebarFinder,
          debounceDuration: const Duration(milliseconds: 150),
        );

        // Allow spring animation to complete
        await tester.pump(const Duration(milliseconds: 350));

        expect(tester.getSize(sidebarFinder).width, equals(220.0));

        await gesture.removePointer();
        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '4. (F14) Moving mouse pointer out of expanded sidebar triggers spring rebound collapse to 64px',
      (tester) async {
        final controller = CamelliaDesktopShellController(
          initialDestination: DesktopNavDestination.connect,
          initialCollapsed: true,
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

        final sidebarFinder = find.byKey(const ValueKey('desktop-nav-sidebar'));

        // Hover to expand
        final gesture = await PointerGestureHelper.hoverEnter(
          tester,
          sidebarFinder,
          debounceDuration: const Duration(milliseconds: 150),
        );
        await tester.pump(const Duration(milliseconds: 350));

        // Move pointer away outside the sidebar
        await PointerGestureHelper.hoverExit(
          tester,
          gesture,
          exitOffset: const Offset(800, 500),
          reboundDuration: const Duration(milliseconds: 350),
        );

        expect(tester.getSize(sidebarFinder).width, equals(64.0));

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '5. (F14) High-frequency mouse jitter (<50ms) across sidebar rail boundary is debounced without layout hitching',
      (tester) async {
        final controller = CamelliaDesktopShellController(
          initialDestination: DesktopNavDestination.connect,
          initialCollapsed: true,
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

        final sidebarFinder = find.byKey(const ValueKey('desktop-nav-sidebar'));

        // Rapid jitter in and out
        final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await gesture.addPointer(location: Offset.zero);

        for (int i = 0; i < 5; i++) {
          await gesture.moveTo(tester.getCenter(sidebarFinder));
          await tester.pump(const Duration(milliseconds: 30));
          await gesture.moveTo(const Offset(500, 400));
          await tester.pump(const Duration(milliseconds: 30));
        }

        await gesture.removePointer();
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '6. (F14) Manual collapse toggle locks sidebar width and ignores hover collapse on exit',
      (tester) async {
        final controller = CamelliaDesktopShellController(
          initialDestination: DesktopNavDestination.connect,
          initialCollapsed: false,
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

        final sidebarFinder = find.byKey(const ValueKey('desktop-nav-sidebar'));
        expect(tester.getSize(sidebarFinder).width, equals(220.0));

        // When mouse hovers out while pinned/uncollapsed, it remains 220px
        final gesture = await PointerGestureHelper.hoverEnter(
          tester,
          sidebarFinder,
          debounceDuration: const Duration(milliseconds: 50),
        );
        await PointerGestureHelper.hoverExit(
          tester,
          gesture,
          exitOffset: const Offset(700, 500),
          reboundDuration: const Duration(milliseconds: 300),
        );

        expect(tester.getSize(sidebarFinder).width, equals(220.0));

        await TestAppHarness.tearDown(tester);
      },
    );
  });
}
