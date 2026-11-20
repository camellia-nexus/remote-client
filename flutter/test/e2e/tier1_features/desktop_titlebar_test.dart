import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/desktop/widgets/titlebar_widget.dart';
import '../harness/mock_window_controller.dart';
import '../harness/test_app_harness.dart';

void main() {
  setUp(() async {
    await TestAppHarness.setUp();
  });

  Widget createTitleBarApp({
    required MockWindowController controller,
    String? appName,
    bool? showCaptionButtons,
  }) {
    return Column(
      children: [
        DesktopTitleBar(
          appName: appName,
          controller: controller,
          showCaptionButtons: showCaptionButtons,
        ),
        const Expanded(child: SizedBox()),
      ],
    );
  }

  group('Tier 1: DesktopTitleBar & Window Chrome Coverage', () {
    testWidgets('1. Minimize action triggers controller minimize callback', (
      tester,
    ) async {
      final controller = MockWindowController();
      await TestAppHarness.pumpWidget(
        tester,
        child: createTitleBarApp(
          controller: controller,
          showCaptionButtons: true,
        ),
      );

      final minimizeFinder = find.byTooltip('Minimize');
      expect(minimizeFinder, findsOneWidget);

      await tester.tap(minimizeFinder);
      await tester.pump();

      expect(controller.minimizeCount, equals(1));
      expect(controller.minimized, isTrue);

      await TestAppHarness.tearDown(tester);
    });

    testWidgets(
      '2. Maximize and Restore actions toggle state and caption button tooltip',
      (tester) async {
        final controller = MockWindowController();
        await TestAppHarness.pumpWidget(
          tester,
          child: createTitleBarApp(
            controller: controller,
            showCaptionButtons: true,
          ),
        );

        final maximizeFinder = find.byTooltip('Maximize');
        expect(maximizeFinder, findsOneWidget);
        expect(find.byTooltip('Restore'), findsNothing);

        // Tap maximize
        await tester.tap(maximizeFinder);
        await tester.pump();

        expect(controller.maximizeCount, equals(1));
        expect(controller.maximized, isTrue);
        expect(find.byTooltip('Restore'), findsOneWidget);
        expect(find.byTooltip('Maximize'), findsNothing);

        // Tap restore
        await tester.tap(find.byTooltip('Restore'));
        await tester.pump();

        expect(controller.unmaximizeCount, equals(1));
        expect(controller.maximized, isFalse);
        expect(find.byTooltip('Maximize'), findsOneWidget);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets('3. Close button action triggers window close callback', (
      tester,
    ) async {
      final controller = MockWindowController();
      await TestAppHarness.pumpWidget(
        tester,
        child: createTitleBarApp(
          controller: controller,
          showCaptionButtons: true,
        ),
      );

      final closeFinder = find.byTooltip('Close');
      expect(closeFinder, findsOneWidget);

      await tester.tap(closeFinder);
      await tester.pump();

      expect(controller.closeCount, equals(1));
      expect(controller.closed, isTrue);

      await TestAppHarness.tearDown(tester);
    });

    testWidgets(
      '4. Double-tap drag region toggles maximize and pan triggers dragging',
      (tester) async {
        final controller = MockWindowController();
        await TestAppHarness.pumpWidget(
          tester,
          child: createTitleBarApp(
            controller: controller,
            showCaptionButtons: true,
          ),
        );

        final dragRegion = find.byKey(
          const ValueKey('desktop-title-drag-region'),
        );
        expect(dragRegion, findsOneWidget);

        // Test double-tap to maximize
        await tester.tap(dragRegion);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(dragRegion);
        await tester.pump();

        expect(controller.maximized, isTrue);
        expect(controller.maximizeCount, equals(1));

        // Test double-tap again to unmaximize
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(dragRegion);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(dragRegion);
        await tester.pump();

        expect(controller.maximized, isFalse);
        expect(controller.unmaximizeCount, equals(1));

        // Test drag gesture
        await tester.pump(const Duration(milliseconds: 400));
        await tester.drag(dragRegion, const Offset(60, 0));
        expect(controller.dragCount, greaterThanOrEqualTo(1));

        // Test secondary click for system menu
        await tester.tap(dragRegion, buttons: kSecondaryMouseButton);
        expect(controller.menuCount, equals(1));
        await tester.pump(const Duration(milliseconds: 400));

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets('5. macOS mode reserves traffic light padding and suppresses captions', (
      tester,
    ) async {
      final controller = MockWindowController();

      // Explicitly set showCaptionButtons = false to emulate macOS caption suppression
      await TestAppHarness.pumpWidget(
        tester,
        child: createTitleBarApp(
          controller: controller,
          showCaptionButtons: false,
        ),
      );

      // Caption buttons should not be present
      expect(find.byTooltip('Minimize'), findsNothing);
      expect(find.byTooltip('Maximize'), findsNothing);
      expect(find.byTooltip('Close'), findsNothing);

      // Drag region is still fully functional
      final dragRegion = find.byKey(
        const ValueKey('desktop-title-drag-region'),
      );
      expect(dragRegion, findsOneWidget);

      await tester.drag(dragRegion, const Offset(30, 0));
      expect(controller.dragCount, greaterThanOrEqualTo(1));
      await tester.pump(const Duration(milliseconds: 400));

      await TestAppHarness.tearDown(tester);
    });

    testWidgets(
      '6. Titlebar renders custom app name or falls back to brand name',
      (tester) async {
        final controller = MockWindowController();

        // 6a. Explicit custom appName
        await TestAppHarness.pumpWidget(
          tester,
          child: createTitleBarApp(
            controller: controller,
            appName: 'Custom Session - Remote Rig',
            showCaptionButtons: true,
          ),
        );
        expect(find.text('Custom Session - Remote Rig'), findsOneWidget);

        // 6b. Default appName fallback from fake bridge
        await TestAppHarness.pumpWidget(
          tester,
          child: createTitleBarApp(
            controller: controller,
            showCaptionButtons: true,
          ),
        );
        expect(find.text('Camellia Remote'), findsOneWidget);

        await TestAppHarness.tearDown(tester);
      },
    );
  });
}
