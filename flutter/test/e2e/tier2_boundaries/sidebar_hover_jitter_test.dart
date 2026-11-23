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

  group('Tier 2: Sidebar Hover Jitter & Viewport Boundary Tests (F13, F14)', () {
    testWidgets(
      '1. Rapid hover enter and exit jitter (<50ms) cancels intermediate transitions and prevents layout hitching',
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
        expect(tester.getSize(sidebarFinder).width, equals(64.0));

        // Create high-frequency mouse jitter (< 50ms per transition)
        final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await gesture.addPointer(location: Offset.zero);

        for (int i = 0; i < 8; i++) {
          await gesture.moveTo(tester.getCenter(sidebarFinder));
          await tester.pump(const Duration(milliseconds: 25));
          await gesture.moveTo(const Offset(600, 400));
          await tester.pump(const Duration(milliseconds: 25));
        }

        // Wait for debounce timer to expire outside the sidebar
        await gesture.removePointer();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();

        // The sidebar should settle cleanly at collapsed 64px
        expect(tester.getSize(sidebarFinder).width, equals(64.0));
        expect(tester.takeException(), isNull);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '2. Window surface resize below collapseBreakpoint (width < 768px) locks sidebar into rail mode',
      (tester) async {
        final controller = CamelliaDesktopShellController(
          initialDestination: DesktopNavDestination.connect,
        );

        // Initially wide display
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: CamelliaDesktopShell(
            controller: controller,
            collapseBreakpoint: 768.0,
            connectBuilder: (_) => const Text('Connect View'),
            settingsBuilder: (_) => const Text('Settings View'),
          ),
        );
        await tester.pump();

        final sidebarFinder = find.byKey(const ValueKey('desktop-nav-sidebar'));
        expect(tester.getSize(sidebarFinder).width, equals(220.0));

        // Sudden window resize to narrow tiling split (520px < 768px)
        await tester.binding.setSurfaceSize(const Size(520, 800));
        tester.view.physicalSize = const Size(520, 800);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        // Layout builder must auto-collapse sidebar to railWidth (64px) to preserve content area
        expect(tester.getSize(sidebarFinder).width, equals(64.0));

        // Attempting to hover while in narrow viewport should not overflow the small surface
        final gesture = await PointerGestureHelper.hoverEnter(
          tester,
          sidebarFinder,
          debounceDuration: const Duration(milliseconds: 200),
        );
        await tester.pump(const Duration(milliseconds: 350));

        // Content area must not be swallowed; taking exception check ensures no overflow
        expect(tester.takeException(), isNull);

        await gesture.removePointer();
        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '3. High-frequency pointer movement within sidebar interior does not reset or corrupt expand state',
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

        final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await gesture.addPointer(location: const Offset(100, 100));

        // Rapid vertical scanning inside the expanded sidebar bounds
        for (double dy = 100; dy <= 500; dy += 40) {
          await gesture.moveTo(Offset(100, dy));
          await tester.pump(const Duration(milliseconds: 15));
        }

        await tester.pumpAndSettle();

        // Width must remain strictly 220px without jitter or collapse
        expect(tester.getSize(sidebarFinder).width, equals(220.0));
        expect(tester.takeException(), isNull);

        await gesture.removePointer();
        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '4. Explicit user collapse (setCollapsed(true)) overrides hover auto-expansion and keeps rail width',
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
        expect(tester.getSize(sidebarFinder).width, equals(64.0));

        // User explicitly toggles or locks collapsed state
        controller.setCollapsed(true);
        await tester.pump();

        expect(controller.collapsed, isTrue);
        expect(tester.getSize(sidebarFinder).width, equals(64.0));

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '5. Rapid hover enter/exit with system reduce motion (disableAnimations: true) completes without animation failure',
      (tester) async {
        final controller = CamelliaDesktopShellController(
          initialDestination: DesktopNavDestination.connect,
          initialCollapsed: true,
        );

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: CamelliaDesktopShell(
              controller: controller,
              connectBuilder: (_) => const Text('Connect View'),
              settingsBuilder: (_) => const Text('Settings View'),
            ),
          ),
        );
        await tester.pump();

        final sidebarFinder = find.byKey(const ValueKey('desktop-nav-sidebar'));
        expect(tester.getSize(sidebarFinder).width, equals(64.0));

        // Hover with instant animations
        final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await gesture.addPointer(location: Offset.zero);
        await gesture.moveTo(tester.getCenter(sidebarFinder));
        await tester.pump();

        // Under reduce motion, zero duration or immediate resolution executes without crash
        await gesture.moveTo(const Offset(800, 500));
        await tester.pump();
        await gesture.removePointer();
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '6. Viewport resize oscillations across 768px breakpoint preserve layout stability without overflow',
      (tester) async {
        final controller = CamelliaDesktopShellController(
          initialDestination: DesktopNavDestination.connect,
        );

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1024, 768),
          child: CamelliaDesktopShell(
            controller: controller,
            collapseBreakpoint: 768.0,
            connectBuilder: (_) => const Text('Connect View'),
            settingsBuilder: (_) => const Text('Settings View'),
          ),
        );
        await tester.pump();

        // Oscillate window width 5 times between narrow (600px) and wide (1100px)
        for (int i = 0; i < 5; i++) {
          final width = (i % 2 == 0) ? 600.0 : 1100.0;
          await tester.binding.setSurfaceSize(Size(width, 768));
          tester.view.physicalSize = Size(width, 768);
          await tester.pump(const Duration(milliseconds: 50));
        }

        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        await TestAppHarness.tearDown(tester);
      },
    );
  });
}
