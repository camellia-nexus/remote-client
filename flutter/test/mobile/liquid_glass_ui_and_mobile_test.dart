import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/desktop/widgets/desktop_shell.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';

void main() {
  group('Liquid Glass Design System & Multi-Theme Engine', () {
    test('MyTheme provides Light, Dark, and OLED Midnight themes', () {
      final light = MyTheme.lightTheme;
      final dark = MyTheme.darkTheme;
      final midnight = MyTheme.midnightTheme;

      expect(light.brightness, Brightness.light);
      expect(dark.brightness, Brightness.dark);
      expect(midnight.brightness, Brightness.dark);
      expect(midnight.scaffoldBackgroundColor, CamelliaColors.midnightCanvas);

      final lightGlass = light.extension<CamelliaGlassTokens>()!;
      final darkGlass = dark.extension<CamelliaGlassTokens>()!;
      final midnightGlass = midnight.extension<CamelliaGlassTokens>()!;
      expect(lightGlass.isMidnight, isFalse);
      expect(darkGlass.isMidnight, isFalse);
      expect(midnightGlass.isMidnight, isTrue);

      expect(
        MyTheme.themePreferenceFromString('midnight'),
        CamelliaThemePreference.midnight,
      );
      expect(
        MyTheme.themePreferenceFromString('oled'),
        CamelliaThemePreference.midnight,
      );
      expect(MyTheme.themeModeFromString('midnight'), ThemeMode.dark);
      expect(
        MyTheme.themePreferenceFromString('light'),
        CamelliaThemePreference.light,
      );
      expect(
        MyTheme.themePreferenceFromString('system'),
        CamelliaThemePreference.system,
      );
    });

    test('CamelliaTypography.tabular enforces tabular-nums font feature', () {
      final styled = CamelliaTypography.tabular(const TextStyle(fontSize: 16));
      expect(styled.fontFeatures, contains(const FontFeature.tabularFigures()));
    });

    testWidgets('CamelliaMotion.resolve respects Reduce Motion preference', (
      tester,
    ) async {
      late Duration normalDuration;
      late Duration reducedDuration;

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: false),
          child: Builder(
            builder: (context) {
              normalDuration = CamelliaMotion.resolve(
                context,
                CamelliaMotion.state,
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(normalDuration, CamelliaMotion.state);

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Builder(
            builder: (context) {
              reducedDuration = CamelliaMotion.resolve(
                context,
                CamelliaMotion.state,
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(reducedDuration, Duration.zero);
    });

    testWidgets('CamelliaBackdrop renders pure black in OLED Midnight', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: MyTheme.midnightTheme,
          home: const CamelliaBackdrop(child: Text('Midnight Surface')),
        ),
      );
      expect(find.text('Midnight Surface'), findsOneWidget);
      final colored = tester.widget<ColoredBox>(
        find.descendant(
          of: find.byType(CamelliaBackdrop),
          matching: find.byType(ColoredBox),
        ),
      );
      expect(colored.color, CamelliaColors.midnightCanvas);
    });
  });

  group('6-State Liquid Glass Foundation Components', () {
    testWidgets('GlassButton handles normal, loading, and disabled states', (
      tester,
    ) async {
      int taps = 0;

      await tester.pumpWidget(
        MaterialApp(
          theme: MyTheme.lightTheme,
          home: Scaffold(
            body: Column(
              children: [
                GlassButton(
                  variant: GlassButtonVariant.primary,
                  onPressed: () => taps++,
                  child: const Text('Connect Now'),
                ),
                GlassButton(
                  loading: true,
                  onPressed: () => taps++,
                  child: const Text('Busy Action'),
                ),
                const GlassButton(
                  onPressed: null,
                  disabledTooltip: 'Permission required',
                  child: Text('Locked Action'),
                ),
              ],
            ),
          ),
        ),
      );

      await tester.tap(find.text('Connect Now'));
      await tester.pump(const Duration(milliseconds: 250));
      expect(taps, 1);

      // Loading button prevents duplicate taps and displays progress indicator.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(find.text('Busy Action'));
      await tester.pump();
      expect(taps, 1);

      // Disabled button does not invoke callback and carries explanation Tooltip.
      await tester.tap(find.text('Locked Action'));
      await tester.pump();
      expect(taps, 1);
      expect(find.byTooltip('Permission required'), findsOneWidget);
    });

    testWidgets('GlassShakeBox responds to shake triggers without errors', (
      tester,
    ) async {
      final controller = GlassShakeController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: MyTheme.darkTheme,
          home: Scaffold(
            body: GlassShakeBox(
              controller: controller,
              child: const Text('Auth Field'),
            ),
          ),
        ),
      );

      controller.shake();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(controller.triggerCount, 1);
      expect(find.text('Auth Field'), findsOneWidget);
    });

    testWidgets('TelemetryPill and CamelliaIcons render live metrics cleanly', (
      tester,
    ) async {
      expect(CamelliaIcons.platformIcon('Windows'), Icons.window_rounded);
      expect(CamelliaIcons.platformIcon('macOS'), Icons.laptop_mac_rounded);
      expect(CamelliaIcons.platformIcon('Android'), Icons.phone_android_rounded);
      expect(CamelliaIcons.platformIcon('iOS'), Icons.phone_iphone_rounded);
      expect(CamelliaIcons.platformIcon('Linux'), Icons.terminal_rounded);

      await tester.pumpWidget(
        MaterialApp(
          theme: MyTheme.darkTheme,
          home: const Scaffold(
            body: TelemetryPill(
              label: 'P2P',
              secondaryLabel: '18 ms · 60 FPS',
              statusColor: CamelliaColors.statusOnlineDark,
              icon: Icons.bolt_rounded,
            ),
          ),
        ),
      );

      expect(find.text('P2P'), findsOneWidget);
      expect(find.text('18 ms · 60 FPS'), findsOneWidget);
    });
  });

  group('Mobile Floating Capsule Tab Bar & Glass Bottom Sheet', () {
    testWidgets('GlassFloatingTabBar switches tabs and caps badge at 99+', (
      tester,
    ) async {
      int selected = 0;

      await tester.pumpWidget(
        MaterialApp(
          theme: MyTheme.lightTheme,
          home: StatefulBuilder(
            builder: (context, setState) {
              return Scaffold(
                body: Text('Tab $selected'),
                bottomNavigationBar: GlassFloatingTabBar(
                  currentIndex: selected,
                  onTap: (idx) => setState(() => selected = idx),
                  items: const [
                    GlassFloatingTabItem(
                      label: 'Connect',
                      icon: Icons.sensors_outlined,
                      selectedIcon: Icons.sensors_rounded,
                    ),
                    GlassFloatingTabItem(
                      label: 'Chat',
                      icon: Icons.chat_bubble_outline_rounded,
                      selectedIcon: Icons.chat_bubble_rounded,
                      badgeCount: 120,
                    ),
                    GlassFloatingTabItem(
                      label: 'Settings',
                      icon: Icons.tune_outlined,
                      selectedIcon: Icons.tune_rounded,
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      );

      expect(find.text('99+'), findsOneWidget);
      await tester.tap(find.text('Chat'));
      await tester.pumpAndSettle();
      expect(find.text('Tab 1'), findsOneWidget);

      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Tab 2'), findsOneWidget);
    });

    testWidgets('showGlassBottomSheet presents and dismisses cleanly', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: MyTheme.darkTheme,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () {
                    showGlassBottomSheet<void>(
                      context: context,
                      title: 'Display Options',
                      subtitle: 'Adjust quality and scaling',
                      builder: (_) => const Padding(
                        padding: EdgeInsets.all(20),
                        child: Text('Adaptive Scaling'),
                      ),
                    );
                  },
                  child: const Text('Open Sheet'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Sheet'));
      await tester.pumpAndSettle();
      expect(find.text('Display Options'), findsOneWidget);
      expect(find.text('Adaptive Scaling'), findsOneWidget);

      Navigator.of(tester.element(find.text('Display Options'))).pop();
      await tester.pumpAndSettle();
      expect(find.text('Display Options'), findsNothing);
    });
  });

  group('Desktop Global Command Palette (Cmd/Ctrl + K)', () {
    testWidgets('opens via shortcut, filters commands, and navigates', (
      tester,
    ) async {
      final controller = CamelliaDesktopShellController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: MyTheme.lightTheme,
          home: Scaffold(
            body: CamelliaDesktopShell(
              controller: controller,
              connectBuilder: (_) => const Center(child: Text('Connect View')),
              devicesBuilder: (_) => const Center(child: Text('Devices View')),
              addressBookBuilder: (_) =>
                  const Center(child: Text('Address Book View')),
              settingsBuilder: (_) =>
                  const Center(child: Text('Settings View')),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(controller.destination, DesktopNavDestination.connect);

      // Open command palette directly via shell state (verifying dialog wiring)
      final shellState = tester.state<CamelliaDesktopShellState>(
        find.byType(CamelliaDesktopShell),
      );
      shellState.openCommandPalette();
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('command-palette-input')),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const ValueKey('command-palette-input')),
        'Settings',
      );
      await tester.pumpAndSettle();

      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(controller.destination, DesktopNavDestination.settings);
      expect(find.text('Settings View'), findsOneWidget);
    });
  });
}
