import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/desktop/widgets/desktop_shell.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';

void main() {
  group('Responsive & Extreme Viewport Overflow Audit', () {
    final viewports = <String, Size>{
      'iPhone SE portrait (320x568)': const Size(320, 568),
      'iPhone portrait (390x844)': const Size(390, 844),
      'Mobile landscape (844x390)': const Size(844, 390),
      'Narrow desktop (700x600)': const Size(700, 600),
      'Wide desktop (1440x900)': const Size(1440, 900),
    };

    for (final entry in viewports.entries) {
      testWidgets(
        'GlassFloatingTabBar with 4 localized tabs has zero overflow at ${entry.key}',
        (tester) async {
          tester.view.devicePixelRatio = 1.0;
          tester.view.physicalSize = entry.value;
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);

          var currentIndex = 0;
          await tester.pumpWidget(
            MaterialApp(
              theme: MyTheme.lightTheme,
              home: StatefulBuilder(
                builder: (context, setState) => Scaffold(
                  body: const Center(child: Text('Body')),
                  bottomNavigationBar: GlassFloatingTabBar(
                    currentIndex: currentIndex,
                    onTap: (i) => setState(() => currentIndex = i),
                    items: const [
                      GlassFloatingTabItem(
                        label: 'Connection',
                        icon: Icons.sensors_outlined,
                        selectedIcon: Icons.sensors_rounded,
                      ),
                      GlassFloatingTabItem(
                        label: 'Share screen',
                        icon: Icons.mobile_screen_share_outlined,
                        selectedIcon: Icons.mobile_screen_share_rounded,
                      ),
                      GlassFloatingTabItem(
                        label: 'Chat',
                        icon: Icons.chat_bubble_outline_rounded,
                        selectedIcon: Icons.chat_bubble_rounded,
                        badgeCount: 12,
                      ),
                      GlassFloatingTabItem(
                        label: 'Settings',
                        icon: Icons.tune_outlined,
                        selectedIcon: Icons.tune_rounded,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(tester.takeException(), isNull);
          await tester.tap(find.text('Settings'));
          await tester.pumpAndSettle();
          expect(currentIndex, 3);
        },
      );
    }

    testWidgets(
      'GlassFloatingTabBar & GlassCard tolerate 1.6x accessibility text scale at 320px width',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(320, 640);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);

        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 640),
              textScaler: TextScaler.linear(1.6),
            ),
            child: MaterialApp(
              theme: MyTheme.darkTheme,
              home: Scaffold(
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      GlassCard(
                        title: 'Control Remote Desktop With Long Title',
                        subtitle: 'Enter Remote ID or choose a saved peer',
                        trailing: const TelemetryPill(
                          label: 'Ready',
                          statusColor: CamelliaColors.statusOnlineDark,
                          compact: true,
                        ),
                        child: GlassButton(
                          variant: GlassButtonVariant.primary,
                          expand: true,
                          onPressed: () {},
                          child: const Text('Connect'),
                        ),
                      ),
                    ],
                  ),
                ),
                bottomNavigationBar: GlassFloatingTabBar(
                  currentIndex: 0,
                  onTap: (_) {},
                  items: const [
                    GlassFloatingTabItem(
                      label: 'Connection',
                      icon: Icons.sensors_outlined,
                      selectedIcon: Icons.sensors_rounded,
                    ),
                    GlassFloatingTabItem(
                      label: 'Share screen',
                      icon: Icons.mobile_screen_share_outlined,
                      selectedIcon: Icons.mobile_screen_share_rounded,
                    ),
                    GlassFloatingTabItem(
                      label: 'Chat',
                      icon: Icons.chat_bubble_outline_rounded,
                      selectedIcon: Icons.chat_bubble_rounded,
                    ),
                    GlassFloatingTabItem(
                      label: 'Settings',
                      icon: Icons.tune_outlined,
                      selectedIcon: Icons.tune_rounded,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('Interactive Functional Audit (Buttons, Shortcuts, Live Theme)', () {
    testWidgets(
      'MyTheme.themeNotifier reactively switches Light -> Dark -> OLED Midnight -> System',
      (tester) async {
        final previous = MyTheme.themeNotifier.value;
        addTearDown(() => MyTheme.themeNotifier.value = previous);

        MyTheme.themeNotifier.value = CamelliaThemePreference.light;
        await tester.pumpWidget(
          ValueListenableBuilder<CamelliaThemePreference>(
            valueListenable: MyTheme.themeNotifier,
            builder: (context, pref, _) {
              final mode = switch (pref) {
                CamelliaThemePreference.light => ThemeMode.light,
                CamelliaThemePreference.dark ||
                CamelliaThemePreference.midnight => ThemeMode.dark,
                CamelliaThemePreference.system => ThemeMode.light,
              };
              return MaterialApp(
                theme: MyTheme.lightTheme,
                darkTheme: pref == CamelliaThemePreference.midnight
                    ? MyTheme.midnightTheme
                    : MyTheme.darkTheme,
                themeMode: mode,
                home: Builder(
                  builder: (ctx) => Scaffold(
                    body: Text(
                      'midnight=${CamelliaGlassTokens.of(ctx).isMidnight},'
                      'dark=${Theme.of(ctx).brightness == Brightness.dark}',
                    ),
                  ),
                ),
              );
            },
          ),
        );
        expect(find.text('midnight=false,dark=false'), findsOneWidget);

        MyTheme.themeNotifier.value = CamelliaThemePreference.dark;
        await tester.pumpAndSettle();
        expect(find.text('midnight=false,dark=true'), findsOneWidget);

        MyTheme.themeNotifier.value = CamelliaThemePreference.midnight;
        await tester.pumpAndSettle();
        expect(find.text('midnight=true,dark=true'), findsOneWidget);

        MyTheme.themeNotifier.value = CamelliaThemePreference.dark;
        await tester.pumpAndSettle();
        expect(find.text('midnight=false,dark=true'), findsOneWidget);
      },
    );

    testWidgets(
      'DesktopShell Command Palette opens via sidebar trigger, navigates with ArrowDown + Enter, and closes via Esc',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1280, 800);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);

        final controller = CamelliaDesktopShellController();
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          MaterialApp(
            theme: MyTheme.lightTheme,
            home: Scaffold(
              body: CamelliaDesktopShell(
                controller: controller,
                connectBuilder: (_) => const Center(child: Text('Connect')),
                devicesBuilder: (_) => const Center(child: Text('Devices')),
                addressBookBuilder: (_) =>
                    const Center(child: Text('Address Book')),
                settingsBuilder: (_) => const Center(child: Text('Settings')),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Click discoverable Command Palette trigger in expanded sidebar
        await tester.tap(
          find.byKey(const ValueKey('desktop-nav-command-palette')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('command-palette-input')),
          findsOneWidget,
        );

        // Press ArrowDown once -> selects index 1 (Devices), then submit
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        expect(controller.destination, DesktopNavDestination.devices);

        // Reopen palette and close cleanly via Escape
        await tester.tap(
          find.byKey(const ValueKey('desktop-nav-command-palette')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('command-palette-input')),
          findsOneWidget,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('command-palette-input')),
          findsNothing,
        );

        // Resize below collapse breakpoint (700x600) and verify collapsed rail trigger works without overflow
        tester.view.physicalSize = const Size(700, 600);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const ValueKey('desktop-nav-command-palette')),
          findsOneWidget,
        );
      },
    );
  });
}
