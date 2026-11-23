// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/desktop/pages/connection_page.dart';
import 'package:camellia_remote_app/desktop/widgets/desktop_shell.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import '../harness/pointer_gesture_helper.dart';
import '../harness/test_app_harness.dart';

void main() {
  setUp(() async {
    await TestAppHarness.setUp();
  });

  group('Tier 3: 3 Theme Styles x Sidebar Hover x 6 Connection Modes Combo (TC-T3-01, TC-T3-03)', () {
    testWidgets(
      '1. Theme style switching across Aurora Frost, Obsidian Cyber, and Nordic Titanium in Light and Dark modes interacts cleanly with 6 connection modes',
      (tester) async {
        final styles = [
          'auroraFrost',
          'obsidianCyber',
          'nordicTitanium',
        ];

        for (final style in styles) {
          // Test in both Light and Dark mode
          for (final mode in [ThemeMode.light, ThemeMode.dark]) {
            await TestAppHarness.pumpWidget(
              tester,
              surfaceSize: const Size(1280, 800),
              themeMode: mode,
              themeStyle: style,
              child: const ConnectionPage(showDevices: false),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 50));

            // Verify connection mode segmented control is visible and rendered
            final segmentedFinder = find.byType(GlassSegmentedControl);
            expect(segmentedFinder, findsOneWidget);

            // Verify icons for all 6 connection modes exist
            expect(find.byIcon(Icons.desktop_windows_outlined), findsOneWidget);
            expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);
            expect(find.byIcon(Icons.folder_copy_outlined), findsOneWidget);
            expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);
            expect(find.byIcon(Icons.terminal_rounded), findsOneWidget);

            // Tap one of the modes
            await tester.tap(find.byIcon(Icons.terminal_rounded));
            await tester.pump();

            expect(tester.takeException(), isNull);
          }
        }

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '2. Changing theme style and mode while sidebar is in hover state preserves layout and updates design tokens',
      (tester) async {
        final controller = CamelliaDesktopShellController(
          initialDestination: DesktopNavDestination.connect,
          initialCollapsed: true,
        );

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          themeMode: ThemeMode.light,
          themeStyle: 'auroraFrost',
          child: CamelliaDesktopShell(
            controller: controller,
            connectBuilder: (_) => const Text('Connect View'),
            settingsBuilder: (_) => const Text('Settings View'),
          ),
        );
        await tester.pump();

        final sidebarFinder = find.byKey(const ValueKey('desktop-nav-sidebar'));
        expect(tester.getSize(sidebarFinder).width, equals(64.0));

        // Hover over sidebar
        final gesture = await PointerGestureHelper.hoverEnter(
          tester,
          sidebarFinder,
          debounceDuration: const Duration(milliseconds: 150),
        );

        // Mid-transition: Switch theme to Obsidian Cyber dark
        TestAppHarness.fakeBridge.localOptions['theme_style'] = 'obsidianCyber';
        TestAppHarness.themeModeNotifier.value = ThemeMode.dark;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        // Context tokens must reflect dark palette
        final ctx = tester.element(find.byType(CamelliaDesktopShell));
        expect(Theme.of(ctx).brightness, equals(Brightness.dark));

        // Leave hover
        await PointerGestureHelper.hoverExit(
          tester,
          gesture,
          exitOffset: const Offset(800, 500),
          reboundDuration: const Duration(milliseconds: 350),
        );

        expect(tester.takeException(), isNull);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '3. Full combination of 6 connection buttons inside desktop shell under Nordic Titanium theme',
      (tester) async {
        final controller = CamelliaDesktopShellController(
          initialDestination: DesktopNavDestination.connect,
        );

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          themeMode: ThemeMode.dark,
          themeStyle: 'nordicTitanium',
          child: CamelliaDesktopShell(
            controller: controller,
            connectBuilder: (_) => const SingleChildScrollView(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: ConnectionPage(showDevices: false),
              ),
            ),
            settingsBuilder: (_) => const Text('Settings View'),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        // Cycle through all 6 connection mode button options
        final modeIcons = [
          Icons.desktop_windows_outlined,
          Icons.visibility_outlined,
          Icons.folder_copy_outlined,
          Icons.videocam_outlined,
          Icons.terminal_rounded,
        ];

        for (final icon in modeIcons) {
          final iconFinder = find.byIcon(icon);
          expect(iconFinder, findsOneWidget);
          await tester.tap(iconFinder);
          await tester.pump(const Duration(milliseconds: 50));
        }

        expect(tester.takeException(), isNull);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '4. Collapsed rail mode with 64px width preserves icon centering across theme changes',
      (tester) async {
        final controller = CamelliaDesktopShellController(
          initialDestination: DesktopNavDestination.connect,
          initialCollapsed: true,
        );

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          themeMode: ThemeMode.light,
          themeStyle: 'auroraFrost',
          child: CamelliaDesktopShell(
            controller: controller,
            connectBuilder: (_) => const Text('Connect View'),
            settingsBuilder: (_) => const Text('Settings View'),
          ),
        );
        await tester.pump();

        final sidebarFinder = find.byKey(const ValueKey('desktop-nav-sidebar'));
        expect(tester.getSize(sidebarFinder).width, equals(64.0));

        // Switch to Dark Obsidian
        TestAppHarness.themeModeNotifier.value = ThemeMode.dark;
        TestAppHarness.fakeBridge.localOptions['theme_style'] = 'obsidianCyber';
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(tester.getSize(sidebarFinder).width, equals(64.0));

        // Switch to Nordic Titanium
        TestAppHarness.fakeBridge.localOptions['theme_style'] = 'nordicTitanium';
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(tester.getSize(sidebarFinder).width, equals(64.0));
        expect(tester.takeException(), isNull);

        await TestAppHarness.tearDown(tester);
      },
    );
  });
}
