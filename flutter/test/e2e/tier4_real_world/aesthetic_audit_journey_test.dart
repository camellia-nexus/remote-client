// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/desktop/pages/connection_page.dart';
import 'package:camellia_remote_app/desktop/widgets/desktop_shell.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import '../harness/test_app_harness.dart';

void main() {
  setUp(() async {
    await TestAppHarness.setUp();
  });

  group('Tier 4: Scenario 6 - Nordic Titanium Theme & Full Aesthetic Audit Journey', () {
    testWidgets(
      'Complete Journey: 6-state theme audit -> Nordic Titanium visual polish -> Zero mouse-click focus border verification',
      (tester) async {
        // Step 1: 6-State Theme Audit (Aurora Frost, Obsidian Cyber, Nordic Titanium x Light/Dark)
        final themeStyles = ['auroraFrost', 'obsidianCyber', 'nordicTitanium'];
        final modes = [ThemeMode.light, ThemeMode.dark];

        for (final style in themeStyles) {
          for (final mode in modes) {
            await TestAppHarness.pumpWidget(
              tester,
              surfaceSize: const Size(1280, 800),
              themeMode: mode,
              themeStyle: style,
              child: const ConnectionPage(showDevices: false),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 30));

            // Verify background canvas and tokens
            final ctx = tester.element(find.byType(ConnectionPage));
            final theme = Theme.of(ctx);
            expect(
              theme.brightness,
              equals(mode == ThemeMode.dark ? Brightness.dark : Brightness.light),
            );
            expect(tester.takeException(), isNull);
          }
        }

        // Step 2: Nordic Titanium Theme Visual Polish Audit
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          themeMode: ThemeMode.dark,
          themeStyle: 'nordicTitanium',
          child: CamelliaDesktopShell(
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

        // Step 3: Zero Mouse-Click Focus Border Audit
        // Click 6-mode segmented control buttons
        final modeIcons = [
          Icons.desktop_windows_outlined,
          Icons.visibility_outlined,
          Icons.folder_copy_outlined,
          Icons.videocam_outlined,
          Icons.terminal_rounded,
        ];

        for (final icon in modeIcons) {
          final buttonFinder = find.byIcon(icon);
          expect(buttonFinder, findsOneWidget);

          // Click with mouse pointer
          await tester.tap(buttonFinder);
          await tester.pump();

          // Verify no redundant 2.0px focus glow box shadow is generated on pointer click
          final containers = tester.widgetList<AnimatedContainer>(
            find.descendant(of: buttonFinder, matching: find.byType(AnimatedContainer)),
          );

          for (final container in containers) {
            final decoration = container.decoration as BoxDecoration?;
            if (decoration?.boxShadow != null) {
              final hasFocusGlow = decoration!.boxShadow!.any(
                (s) => s.spreadRadius >= 2.0 && s.blurRadius == 0,
              );
              expect(hasFocusGlow, isFalse, reason: 'Mouse click must not produce focus glow');
            }
          }
        }

        // Click sidebar connect navigation item
        final navConnectFinder = find.byKey(const ValueKey('desktop-nav-connect'));
        expect(navConnectFinder, findsOneWidget);

        await tester.tap(navConnectFinder);
        await tester.pump();

        expect(tester.takeException(), isNull);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      'Step Verification: GlassButton clicked with mouse suppresses focusGlow border',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          child: Center(
            child: GlassButton(
              onPressed: () {},
              child: const Text('Audited Button'),
            ),
          ),
        );
        await tester.pump();

        final btn = find.byType(GlassButton);
        await tester.tap(btn);
        await tester.pump();

        final animatedContainers = tester.widgetList<AnimatedContainer>(
          find.descendant(of: btn, matching: find.byType(AnimatedContainer)),
        );

        for (final container in animatedContainers) {
          final decoration = container.decoration as BoxDecoration?;
          if (decoration?.boxShadow != null) {
            final hasFocusGlow = decoration!.boxShadow!.any(
              (s) => s.spreadRadius >= 2.0 && s.blurRadius == 0,
            );
            expect(hasFocusGlow, isFalse);
          }
        }

        await TestAppHarness.tearDown(tester);
      },
    );
  });
}
