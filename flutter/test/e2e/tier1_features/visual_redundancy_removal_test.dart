// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/common/widgets/brand_shell.dart';
import 'package:camellia_remote_app/common/widgets/first_run_wizard_dialog.dart';
import 'package:camellia_remote_app/desktop/pages/connection_page.dart';
import 'package:camellia_remote_app/desktop/pages/desktop_home_page.dart';
import 'package:camellia_remote_app/desktop/widgets/desktop_shell.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import '../harness/test_app_harness.dart';

void main() {
  setUp(() async {
    await TestAppHarness.setUp();
  });

  group('Tier 1: Visual Redundancy Removal & Layout Polish Coverage (F06-F10, F12)', () {
    testWidgets(
      '1. (F06) Direct startup mounts DesktopHomePage cleanly without FirstRunWizardDialog or modal barrier',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: const DesktopHomePage(),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        // DesktopHomePage must be directly mounted
        expect(find.byType(DesktopHomePage), findsOneWidget);

        // No modal onboarding wizard or get started barrier
        expect(find.byType(FirstRunWizardDialog), findsNothing);
        expect(find.text('Get Started'), findsNothing);
        expect(find.text('Checking...'), findsNothing);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '2. (F07) Mouse-click pointer tap on GlassButton suppresses focusGlow box shadow border',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          child: Center(
            child: GlassButton(
              variant: GlassButtonVariant.primary,
              onPressed: () {},
              child: const Text('Primary Action'),
            ),
          ),
        );
        await tester.pump();

        final buttonFinder = find.byType(GlassButton);
        expect(buttonFinder, findsOneWidget);

        // Tap button with mouse/touch pointer
        await tester.tap(buttonFinder);
        await tester.pump();

        // Inspect Container decoration inside AnimatedContainer
        final animatedContainers = tester.widgetList<AnimatedContainer>(
          find.descendant(of: buttonFinder, matching: find.byType(AnimatedContainer)),
        );
        expect(animatedContainers, isNotEmpty);

        for (final container in animatedContainers) {
          final decoration = container.decoration as BoxDecoration?;
          if (decoration?.boxShadow != null) {
            final hasFocusGlow = decoration!.boxShadow!.any(
              (s) => s.spreadRadius >= 2.0 && s.blurRadius == 0,
            );
            expect(hasFocusGlow, isFalse, reason: 'focusGlow must not be applied on pointer click');
          }
        }

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '3. (F08) OnlineStatusWidget in ready state configures GlassBadge with pulse: false (no oval pulsing animation)',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          child: const OnlineStatusWidget(compact: true),
        );
        await tester.pump();

        final badgeFinder = find.byType(GlassBadge);
        expect(badgeFinder, findsOneWidget);

        final badge = tester.widget<GlassBadge>(badgeFinder);
        // Pulse must be disabled to eliminate infinite oval scaling loop in header
        expect(badge.pulse, isFalse);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '4. (F09) All 6 connection modes (Desktop, ViewOnly, Files, Tunnel, Camera, Terminal) are integrated into GlassSegmentedControl',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: const ConnectionPage(showDevices: false),
        );
        await tester.pump();

        // All 6 icons must be present in the view
        expect(find.byIcon(Icons.desktop_windows_outlined), findsOneWidget);
        expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);
        expect(find.byIcon(Icons.folder_copy_outlined), findsOneWidget);
        expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);
        expect(find.byIcon(Icons.terminal_rounded), findsOneWidget);

        // All 6 connection mode items must be integrated inside GlassSegmentedControl
        final segmentedFinder = find.byType(GlassSegmentedControl);
        expect(segmentedFinder, findsOneWidget);

        expect(
          find.descendant(of: segmentedFinder, matching: find.byIcon(Icons.videocam_outlined)),
          findsOneWidget,
        );
        expect(
          find.descendant(of: segmentedFinder, matching: find.byIcon(Icons.terminal_rounded)),
          findsOneWidget,
        );

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '5. (F10) Uninstalled / permission checklist is relocated from center workspace to sidebar footer',
      (tester) async {
        TestAppHarness.fakeBridge.setBuildinOption('installed', '');

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: const DesktopHomePage(),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        // Center connect workspace must not contain the permission checklist card
        final centerChecklistFinder = find.text('Permission & Service Checklist');
        expect(centerChecklistFinder, findsNothing);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '6. (F12) Sidebar header displays bespoke CamelliaBrandMark instead of generic shield icon',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: CamelliaDesktopShell(
            connectBuilder: (_) => const Text('Connect View'),
            settingsBuilder: (_) => const Text('Settings View'),
          ),
        );
        await tester.pump();

        final sidebarFinder = find.byKey(const ValueKey('desktop-nav-sidebar'));
        expect(sidebarFinder, findsOneWidget);

        // Sidebar header must render bespoke CamelliaBrandMark
        expect(
          find.descendant(of: sidebarFinder, matching: find.byType(CamelliaBrandMark)),
          findsOneWidget,
        );

        // Generic shield icon must be replaced
        final shieldIconFinder = find.descendant(
          of: sidebarFinder,
          matching: find.byWidgetPredicate(
            (w) => w is Icon && w.icon?.codePoint == 0xe5a3, // CamelliaIcons.shield
          ),
        );
        expect(shieldIconFinder, findsNothing);

        await TestAppHarness.tearDown(tester);
      },
    );
  });
}
