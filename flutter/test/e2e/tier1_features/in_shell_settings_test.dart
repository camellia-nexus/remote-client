import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/server_settings_dialog.dart';
import 'package:camellia_remote_app/common/widgets/settings_components.dart';
import 'package:camellia_remote_app/common/widgets/settings_overlay.dart';
import 'package:camellia_remote_app/desktop/pages/desktop_setting_page.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import '../harness/test_app_harness.dart';

SettingsThemeData _buildTestSettingsTheme(bool dark) {
  final surface = dark ? CamelliaColors.darkSurface : CamelliaColors.lightSurface;
  final text = dark ? CamelliaColors.darkText : CamelliaColors.lightText;
  final muted = dark ? CamelliaColors.darkMuted : CamelliaColors.lightMuted;
  final border = dark ? CamelliaColors.darkBorder : CamelliaColors.lightBorder;
  return SettingsThemeData(
    settingsListBackground: Colors.transparent,
    settingsSectionBackground: surface,
    dividerColor: border,
    tileHighlightColor: CamelliaColors.azure.withValues(alpha: dark ? 0.22 : 0.10),
    titleTextColor: CamelliaColors.coral,
    leadingIconsColor: CamelliaColors.azure,
    trailingTextColor: muted,
    tileDescriptionTextColor: muted,
    settingsTileTextColor: text,
    inactiveTitleColor: muted.withValues(alpha: 0.65),
    inactiveSubtitleColor: muted.withValues(alpha: 0.55),
    inactiveSwitchColor: muted.withValues(alpha: 0.35),
    titleTextStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
    tileTextStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
  );
}

void main() {
  setUp(() async {
    await TestAppHarness.setUp();
  });

  group('Tier 1: In-Shell Settings Component & Overlay Coverage', () {
    testWidgets(
      '1. DesktopSettingPage displays sidebar tabs and navigates between categories',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: DesktopSettingPage(initialTabkey: SettingsTabKey.general),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));

        // Verify primary tabs are visible in settings sidebar
        expect(find.text('General'), findsWidgets);
        expect(find.text('Network'), findsWidgets);
        expect(find.text('About'), findsWidgets);

        // Click on Network tab to navigate
        final networkTab = find.text('Network');
        expect(networkTab, findsWidgets);
        await tester.tap(networkTab.first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        // Verify Network settings section content is displayed
        expect(find.text('ID/Relay Server'), findsWidgets);

        // Click on About tab
        final aboutTab = find.text('About');
        await tester.tap(aboutTab.first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        // Verify About section content
        expect(find.textContaining('Camellia Remote'), findsWidgets);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '2. SettingsTile.switchTile renders switch and triggers toggle mutation',
      (tester) async {
        bool toggleValue = false;
        int toggleCallCount = 0;

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                return SettingsList(
                  lightTheme: _buildTestSettingsTheme(false),
                  darkTheme: _buildTestSettingsTheme(true),
                  sections: [
                    SettingsSection(
                      title: const Text('Options'),
                      tiles: [
                        SettingsTile.switchTile(
                          title: const Text('Enable Hardware Acceleration'),
                          description: const Text('Use GPU decoding when available'),
                          initialValue: toggleValue,
                          onToggle: (val) {
                            setState(() {
                              toggleValue = val;
                              toggleCallCount++;
                            });
                            TestAppHarness.fakeBridge.setLocalFlutterOption(
                              k: 'hardware-codec',
                              v: val ? 'Y' : 'N',
                            );
                          },
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        );
        await tester.pump();

        expect(find.text('Enable Hardware Acceleration'), findsOneWidget);
        expect(find.text('Use GPU decoding when available'), findsOneWidget);

        // Find switch widget
        final switchFinder = find.byType(Switch);
        expect(switchFinder, findsOneWidget);
        Switch switchWidget = tester.widget<Switch>(switchFinder);
        expect(switchWidget.value, isFalse);

        // Tap the tile to toggle switch
        await tester.tap(find.text('Enable Hardware Acceleration'));
        await tester.pump();

        expect(toggleCallCount, equals(1));
        expect(toggleValue, isTrue);
        expect(
          TestAppHarness.fakeBridge.getLocalFlutterOption(k: 'hardware-codec'),
          equals('Y'),
        );

        // Re-read switch value
        switchWidget = tester.widget<Switch>(switchFinder);
        expect(switchWidget.value, isTrue);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '3. SettingsTile disabled contract suppresses interactions and applies inactive style',
      (tester) async {
        int pressedCount = 0;
        int toggleCount = 0;

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: Scaffold(
            body: SettingsList(
              lightTheme: _buildTestSettingsTheme(false),
              darkTheme: _buildTestSettingsTheme(true),
              sections: [
                SettingsSection(
                  title: const Text('Security'),
                  tiles: [
                    SettingsTile(
                      title: const Text('Change Master Key'),
                      enabled: false,
                      onPressed: (_) => pressedCount++,
                    ),
                    SettingsTile.switchTile(
                      title: const Text('Direct IP Access'),
                      enabled: false,
                      initialValue: false,
                      onToggle: (_) => toggleCount++,
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
        await tester.pump();

        // Verify tiles are rendered
        expect(find.text('Change Master Key'), findsOneWidget);
        expect(find.text('Direct IP Access'), findsOneWidget);

        // Attempt to tap the disabled action tile
        await tester.tap(find.text('Change Master Key'));
        await tester.pump();
        expect(pressedCount, equals(0));

        // Attempt to tap the disabled switch tile
        await tester.tap(find.text('Direct IP Access'));
        await tester.pump();
        expect(toggleCount, equals(0));

        // Verify Switch has null onChanged (disabled)
        final switchWidget = tester.widget<Switch>(find.byType(Switch));
        expect(switchWidget.onChanged, isNull);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '4. serverSettingsTextFormField enforces literal input preservation contract',
      (tester) async {
        final controller = TextEditingController();

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(24.0),
              child: serverSettingsTextFormField(
                label: 'ID Server',
                controller: controller,
                errorMsg: '',
              ),
            ),
          ),
        );
        await tester.pump();

        final textFieldFinder = find.byType(TextField);
        expect(textFieldFinder, findsOneWidget);
        final TextField field = tester.widget<TextField>(
          textFieldFinder,
        );

        // Verify input preservation contracts
        expect(field.autocorrect, isFalse);
        expect(field.enableSuggestions, isFalse);
        expect(field.smartDashesType, equals(SmartDashesType.disabled));
        expect(field.smartQuotesType, equals(SmartQuotesType.disabled));
        expect(field.keyboardType, equals(TextInputType.visiblePassword));
        expect(
          field.spellCheckConfiguration,
          equals(const SpellCheckConfiguration.disabled()),
        );

        // Enter technical literal host address with symbols
        const literalServer = 'custom-relay.camellia-remote.corp:21117';
        await tester.enterText(textFieldFinder, literalServer);
        await tester.pump();

        expect(controller.text, equals(literalServer));

        controller.dispose();
        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '5. Server settings dialog renders fields and populates configured server values',
      (tester) async {
        final serverConfig = ServerConfig(
          idServer: 'relay1.camellia.corp',
          relayServer: 'relay2.camellia.corp',
          apiServer: 'https://api.camellia.corp',
          key: 'public-key-token-abc',
        );

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () {
                  showServerSettingsWithValue(
                    serverConfig,
                    gFFI.dialogManager,
                    null,
                  );
                },
                child: const Text('Open Server Settings'),
              ),
            ),
          ),
        );
        await tester.pump();

        // Tap button to open server settings dialog
        await tester.tap(find.text('Open Server Settings'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        // Verify Dialog title and seeded fields appear
        expect(find.text('ID/Relay Server'), findsWidgets);
        expect(find.text('relay1.camellia.corp'), findsOneWidget);
        expect(find.text('relay2.camellia.corp'), findsOneWidget);
        expect(find.text('https://api.camellia.corp'), findsOneWidget);
        expect(find.text('public-key-token-abc'), findsOneWidget);

        // Verify Cancel and OK buttons
        expect(find.text('Cancel'), findsWidgets);
        expect(find.text('OK'), findsWidgets);

        // Tap Cancel to dismiss dialog
        await tester.tap(find.text('Cancel').first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '6. showSettingsOverlay presents desktop modal surface and dismisses cleanly',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: Scaffold(
            body: Builder(
              builder: (context) {
                return Center(
                  child: ElevatedButton(
                    onPressed: () {
                      showSettingsOverlay<void>(
                        context: context,
                        title: 'Settings Modal',
                        builder: (_) => const Center(
                          child: Text('Custom Settings Body Content'),
                        ),
                      );
                    },
                    child: const Text('Trigger Overlay'),
                  ),
                );
              },
            ),
          ),
        );
        await tester.pump();

        // Open modal
        await tester.tap(find.text('Trigger Overlay'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        // Verify overlay surface is shown with title and content
        expect(find.text('Settings Modal'), findsOneWidget);
        expect(find.text('Custom Settings Body Content'), findsOneWidget);

        // Find close button
        final closeBtn = find.byTooltip('Close');
        expect(closeBtn, findsOneWidget);

        // Tap close button to dismiss
        await tester.tap(closeBtn);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        // Modal content should no longer be present
        expect(find.text('Custom Settings Body Content'), findsNothing);

        await TestAppHarness.tearDown(tester);
      },
    );
  });
}
