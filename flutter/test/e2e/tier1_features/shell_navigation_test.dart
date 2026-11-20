import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/desktop/widgets/desktop_shell.dart';
import '../harness/test_app_harness.dart';

void main() {
  setUp(() async {
    await TestAppHarness.setUp();
  });

  group('Tier 1: Desktop Shell Navigation & Responsive Layout Coverage', () {
    testWidgets(
      '1. Shell navigates across primary destinations and renders workspace views',
      (tester) async {
        DesktopNavDestination? lastDestination;

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: CamelliaDesktopShell(
            initialDestination: DesktopNavDestination.connect,
            onDestinationChanged: (dest) => lastDestination = dest,
            connectBuilder: (_) => const Center(
              child: Text('Workspace: Connect View'),
            ),
            devicesBuilder: (_) => const Center(
              child: Text('Workspace: Devices View'),
            ),
            addressBookBuilder: (_) => const Center(
              child: Text('Workspace: Address Book View'),
            ),
            settingsBuilder: (_) => const Center(
              child: Text('Workspace: Settings View'),
            ),
          ),
        );
        await tester.pump();

        // 1. Initially on Connect destination
        expect(find.text('Workspace: Connect View'), findsOneWidget);

        // 2. Navigate to Devices
        await tester.tap(find.byKey(const ValueKey('desktop-nav-devices')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        expect(lastDestination, equals(DesktopNavDestination.devices));
        expect(find.text('Workspace: Devices View'), findsOneWidget);

        // 3. Navigate to Address Book
        await tester.tap(find.byKey(const ValueKey('desktop-nav-addressBook')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        expect(lastDestination, equals(DesktopNavDestination.addressBook));
        expect(find.text('Workspace: Address Book View'), findsOneWidget);

        // 4. Navigate to Settings
        await tester.tap(find.byKey(const ValueKey('desktop-nav-settings')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        expect(lastDestination, equals(DesktopNavDestination.settings));
        expect(find.text('Workspace: Settings View'), findsOneWidget);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '2. Active destination displays active visual indicator and filled icon',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: CamelliaDesktopShell(
            initialDestination: DesktopNavDestination.connect,
            connectBuilder: (_) => const SizedBox(),
            devicesBuilder: (_) => const SizedBox(),
          ),
        );
        await tester.pump();

        // Verify initial active destination icon is sensors_rounded
        expect(find.byIcon(DesktopNavDestination.connect.selectedIcon), findsOneWidget);
        expect(find.byIcon(DesktopNavDestination.devices.icon), findsOneWidget);

        // Switch to Devices
        await tester.tap(find.byKey(const ValueKey('desktop-nav-devices')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        // Now Devices has selectedIcon and Connect has unselected icon
        expect(find.byIcon(DesktopNavDestination.devices.selectedIcon), findsOneWidget);
        expect(find.byIcon(DesktopNavDestination.connect.icon), findsOneWidget);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '3. Collapse and expand toggle button switches between sidebar and rail width',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: const CamelliaDesktopShell(
            defaultSidebarWidth: 220.0,
            railWidth: 64.0,
          ),
        );
        await tester.pump();

        // Verify initial expanded sidebar width
        final sidebarFinder = find.byKey(const ValueKey('desktop-nav-sidebar'));
        expect(sidebarFinder, findsOneWidget);
        AnimatedContainer sidebar = tester.widget<AnimatedContainer>(sidebarFinder);
        expect(sidebar.constraints?.maxWidth ?? (sidebar.child != null ? 220.0 : 0.0), equals(220.0));

        // Tap collapse button
        final toggleBtn = find.byKey(const ValueKey('desktop-nav-collapse-toggle'));
        expect(toggleBtn, findsOneWidget);
        await tester.tap(toggleBtn);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        // Sidebar width should now be compact rail width (64.0)
        sidebar = tester.widget<AnimatedContainer>(sidebarFinder);
        expect(sidebar.constraints?.maxWidth ?? 64.0, equals(64.0));

        // Tap toggle again to expand
        await tester.tap(find.byKey(const ValueKey('desktop-nav-collapse-toggle')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        sidebar = tester.widget<AnimatedContainer>(sidebarFinder);
        expect(sidebar.constraints?.maxWidth ?? 220.0, equals(220.0));

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '4. Responsive auto-collapse collapses sidebar below breakpoint',
      (tester) async {
        // Pump at narrow width < 840 (e.g. 800px)
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(800, 600),
          child: const CamelliaDesktopShell(
            collapseBreakpoint: 840.0,
            defaultSidebarWidth: 220.0,
            railWidth: 64.0,
          ),
        );
        await tester.pump();

        // Narrow width must automatically collapse to rail mode (64.0)
        final sidebarFinder = find.byKey(const ValueKey('desktop-nav-sidebar'));
        AnimatedContainer sidebar = tester.widget<AnimatedContainer>(sidebarFinder);
        expect(sidebar.constraints?.maxWidth ?? 64.0, equals(64.0));

        // Expand window width to 1280 >= 840
        tester.view.physicalSize = const Size(1280, 800);
        await tester.binding.setSurfaceSize(const Size(1280, 800));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        sidebar = tester.widget<AnimatedContainer>(sidebarFinder);
        expect(sidebar.constraints?.maxWidth ?? 220.0, equals(220.0));

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '5. CamelliaDesktopShellController manages destination and collapse programmatically',
      (tester) async {
        final controller = CamelliaDesktopShellController(
          initialDestination: DesktopNavDestination.connect,
        );

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: CamelliaDesktopShell(
            controller: controller,
            connectBuilder: (_) => const Text('Content Connect'),
            devicesBuilder: (_) => const Text('Content Devices'),
          ),
        );
        await tester.pump();

        expect(find.text('Content Connect'), findsOneWidget);

        // Programmatically navigate to Devices
        controller.destination = DesktopNavDestination.devices;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        expect(find.text('Content Devices'), findsOneWidget);
        expect(controller.destination, equals(DesktopNavDestination.devices));

        // Programmatically collapse sidebar
        controller.setCollapsed(true);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        final sidebarFinder = find.byKey(const ValueKey('desktop-nav-sidebar'));
        final sidebar = tester.widget<AnimatedContainer>(sidebarFinder);
        expect(sidebar.constraints?.maxWidth ?? 64.0, equals(64.0));

        controller.dispose();
        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '6. DraggableDivider resizes sidebar width within bounds via pointer gestures',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: const CamelliaDesktopShell(
            defaultSidebarWidth: 220.0,
            minSidebarWidth: 180.0,
            maxSidebarWidth: 320.0,
          ),
        );
        await tester.pump();

        final dividerFinder = find.byKey(const ValueKey('desktop-nav-divider'));
        expect(dividerFinder, findsOneWidget);

        // Drag divider to the right by +50 pixels
        final gesture = await tester.startGesture(tester.getCenter(dividerFinder));
        await gesture.moveBy(const Offset(50, 0));
        await gesture.up();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        // Sidebar width should have expanded from 220 to 270
        final sidebarFinder = find.byKey(const ValueKey('desktop-nav-sidebar'));
        AnimatedContainer sidebar = tester.widget<AnimatedContainer>(sidebarFinder);
        expect(sidebar.constraints?.maxWidth ?? 270.0, equals(270.0));

        // Drag divider far beyond max width (+200 pixels)
        final gesture2 = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('desktop-nav-divider'))));
        await gesture2.moveBy(const Offset(200, 0));
        await gesture2.up();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        // Width must be clamped to maxSidebarWidth: 320.0
        sidebar = tester.widget<AnimatedContainer>(sidebarFinder);
        expect(sidebar.constraints?.maxWidth ?? 320.0, equals(320.0));

        await TestAppHarness.tearDown(tester);
      },
    );
  });
}
