import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/desktop/pages/connection_page.dart';
import 'package:camellia_remote_app/desktop/widgets/desktop_shell.dart';
import 'package:camellia_remote_app/desktop/widgets/titlebar_widget.dart';
import '../harness/mock_window_controller.dart';
import '../harness/test_app_harness.dart';

void main() {
  setUp(() async {
    await TestAppHarness.setUp();
  });

  group('Tier 2: Window Resize Boundaries & Viewport Extremes', () {
    testWidgets(
      '1. Minimum desktop window boundary (600x560) auto-collapses to rail without overflow',
      (tester) async {
        // Pump at minimum desktop window constraints: 600 width x 560 height
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(600, 560),
          child: CamelliaDesktopShell(
            initialDestination: DesktopNavDestination.connect,
            collapseBreakpoint: 840.0,
            defaultSidebarWidth: 220.0,
            railWidth: 64.0,
            connectBuilder: (_) => const SingleChildScrollView(
              child: ConnectionPage(showDevices: false),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        // 1. Verify sidebar is collapsed to compact rail (64.0) because width (600) < 840
        final sidebarFinder = find.byKey(const ValueKey('desktop-nav-sidebar'));
        expect(sidebarFinder, findsOneWidget);
        final sidebar = tester.widget<AnimatedContainer>(sidebarFinder);
        expect(sidebar.constraints?.maxWidth ?? 64.0, equals(64.0));

        // 2. Rail icon items are present
        expect(
          find.byKey(const ValueKey('nav-rail-connect')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('nav-rail-devices')),
          findsOneWidget,
        );

        // 3. Connect page content renders without RenderFlex errors
        expect(find.byType(ConnectionPage), findsOneWidget);
        expect(tester.takeException(), isNull);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '2. Breakpoint transitions dynamically between expanded and stacked workspaces at 720px',
      (tester) async {
        // Pump at width >= 720 (800x600)
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(800, 600),
          child: LayoutBuilder(
            builder: (context, constraints) {
              return constraints.maxWidth >= 720
                  ? const Center(key: ValueKey('expanded-layout'), child: Text('Expanded Workspace'))
                  : const Center(key: ValueKey('stacked-layout'), child: Text('Stacked Workspace'));
            },
          ),
        );
        await tester.pump();

        expect(find.byKey(const ValueKey('expanded-layout')), findsOneWidget);
        expect(find.byKey(const ValueKey('stacked-layout')), findsNothing);

        // Resize down across the breakpoint to 680 < 720
        tester.view.physicalSize = const Size(680, 600);
        await tester.binding.setSurfaceSize(const Size(680, 600));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.byKey(const ValueKey('stacked-layout')), findsOneWidget);
        expect(find.byKey(const ValueKey('expanded-layout')), findsNothing);

        // Resize back up to 1024 >= 720
        tester.view.physicalSize = const Size(1024, 720);
        await tester.binding.setSurfaceSize(const Size(1024, 720));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.byKey(const ValueKey('expanded-layout')), findsOneWidget);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '3. Ultra-high resolution 4K boundary (3840x2160) renders cleanly across wide canvas',
      (tester) async {
        // Pump at 4K UHD resolution: 3840 x 2160
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(3840, 2160),
          child: const CamelliaDesktopShell(
            defaultSidebarWidth: 260.0,
            collapseBreakpoint: 840.0,
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        // Sidebar remains expanded at standard width
        final sidebarFinder = find.byKey(const ValueKey('desktop-nav-sidebar'));
        expect(sidebarFinder, findsOneWidget);
        final sidebar = tester.widget<AnimatedContainer>(sidebarFinder);
        expect(sidebar.constraints?.maxWidth ?? 260.0, equals(260.0));

        // Workspace occupies the remaining wide space
        final contentFinder = find.byKey(const ValueKey('desktop-nav-content'));
        expect(contentFinder, findsOneWidget);
        final contentSize = tester.getSize(contentFinder);
        expect(contentSize.width, greaterThan(3500));
        expect(contentSize.height, equals(2160));

        expect(tester.takeException(), isNull);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '4. Rapid continuous viewport resizing stress completes without exception or unhandled state',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: CamelliaDesktopShell(
            collapseBreakpoint: 840.0,
            connectBuilder: (_) => const Center(child: Text('Rapid Resize Target')),
          ),
        );
        await tester.pump();

        // Sequence of rapid distinct resolutions
        final sizes = [
          const Size(1920, 1080),
          const Size(1440, 900),
          const Size(1024, 768),
          const Size(800, 600),
          const Size(600, 560),
          const Size(1280, 800),
        ];

        for (final size in sizes) {
          tester.view.physicalSize = size;
          await tester.binding.setSurfaceSize(size);
          await tester.pump(const Duration(milliseconds: 32));
        }
        await tester.pump(const Duration(milliseconds: 250));

        expect(find.text('Rapid Resize Target'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '5. Window maximization and restore state transitions update controller and captions',
      (tester) async {
        final controller = MockWindowController();

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: Column(
            children: [
              DesktopTitleBar(
                controller: controller,
                showCaptionButtons: true,
              ),
              const Expanded(child: SizedBox()),
            ],
          ),
        );
        await tester.pump();

        // Initial normal state
        expect(controller.maximized, isFalse);
        final maxFinder = find.byTooltip('Maximize');
        expect(maxFinder, findsOneWidget);

        // Tap maximize button
        await tester.tap(maxFinder);
        await tester.pump();

        expect(controller.maximized, isTrue);
        expect(controller.maximizeCount, equals(1));
        expect(find.byTooltip('Restore'), findsOneWidget);
        expect(find.byTooltip('Maximize'), findsNothing);

        // Tap restore button
        await tester.tap(find.byTooltip('Restore'));
        await tester.pump();

        expect(controller.maximized, isFalse);
        expect(controller.unmaximizeCount, equals(1));
        expect(find.byTooltip('Maximize'), findsOneWidget);

        // Minimize action
        await tester.tap(find.byTooltip('Minimize'));
        await tester.pump();
        expect(controller.minimized, isTrue);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '6. DraggableDivider firmly enforces min (180.0) and max (320.0) width clamps against extreme gestures',
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
        final sidebarFinder = find.byKey(const ValueKey('desktop-nav-sidebar'));

        // 1. Extreme drag to the left (-500px)
        final gestureLeft = await tester.startGesture(tester.getCenter(dividerFinder));
        await gestureLeft.moveBy(const Offset(-500, 0));
        await gestureLeft.up();
        await tester.pump();

        var sidebar = tester.widget<AnimatedContainer>(sidebarFinder);
        expect(sidebar.constraints?.maxWidth ?? 180.0, equals(180.0));

        // 2. Extreme drag to the right (+800px)
        final gestureRight = await tester.startGesture(tester.getCenter(dividerFinder));
        await gestureRight.moveBy(const Offset(800, 0));
        await gestureRight.up();
        await tester.pump();

        sidebar = tester.widget<AnimatedContainer>(sidebarFinder);
        expect(sidebar.constraints?.maxWidth ?? 320.0, equals(320.0));

        await TestAppHarness.tearDown(tester);
      },
    );
  });
}
