import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/desktop/pages/desktop_home_page.dart';
import 'package:camellia_remote_app/desktop/pages/desktop_setting_page.dart';
import 'package:camellia_remote_app/desktop/widgets/desktop_shell.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'e2e/harness/test_app_harness.dart';

void _setScreenSize(WidgetTester tester, {double width = 1024, double height = 768}) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = Size(width, height);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _testApp({
  CamelliaDesktopShellController? controller,
  DesktopNavDestination initialDestination = DesktopNavDestination.connect,
  ValueChanged<DesktopNavDestination>? onDestinationChanged,
  WidgetBuilder? connectBuilder,
  WidgetBuilder? devicesBuilder,
  WidgetBuilder? addressBookBuilder,
  WidgetBuilder? settingsBuilder,
}) {
  return MaterialApp(
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: CamelliaColors.indigo),
    ),
    home: Scaffold(
      body: CamelliaDesktopShell(
        controller: controller,
        initialDestination: initialDestination,
        onDestinationChanged: onDestinationChanged,
        connectBuilder: connectBuilder ??
            (context) => const Center(
                  child: Text(
                    'CONNECT_WORKSPACE_ACTIVE',
                    key: ValueKey('connect-content'),
                  ),
                ),
        devicesBuilder: devicesBuilder ??
            (context) => const Center(
                  child: Text(
                    'DEVICES_WORKSPACE_ACTIVE',
                    key: ValueKey('devices-content'),
                  ),
                ),
        addressBookBuilder: addressBookBuilder ??
            (context) => const Center(
                  child: Text(
                    'ADDRESS_BOOK_WORKSPACE_ACTIVE',
                    key: ValueKey('address-book-content'),
                  ),
                ),
        settingsBuilder: settingsBuilder ??
            (context) => const Center(
                  child: Text(
                    'IN_SHELL_SETTINGS_ACTIVE',
                    key: ValueKey('settings-content'),
                  ),
                ),
      ),
    ),
  );
}

void main() {
  group('CamelliaDesktopShell Navigation', () {
    testWidgets('initializes to connect destination and displays connect view', (
      tester,
    ) async {
      _setScreenSize(tester, width: 1024);
      await tester.pumpWidget(_testApp());
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('connect-content')), findsOneWidget);
      expect(find.byKey(const ValueKey('devices-content')), findsNothing);
      expect(find.byKey(const ValueKey('address-book-content')), findsNothing);
      expect(find.byKey(const ValueKey('settings-content')), findsNothing);
    });

    testWidgets('switches between all 4 destinations smoothly', (tester) async {
      _setScreenSize(tester, width: 1024);
      DesktopNavDestination? lastSelected;
      await tester.pumpWidget(
        _testApp(
          onDestinationChanged: (dest) => lastSelected = dest,
        ),
      );
      await tester.pumpAndSettle();

      // Switch to Devices
      await tester.tap(find.byKey(const ValueKey('desktop-nav-devices')));
      await tester.pumpAndSettle();
      expect(lastSelected, DesktopNavDestination.devices);
      expect(find.byKey(const ValueKey('devices-content')), findsOneWidget);
      expect(find.byKey(const ValueKey('connect-content')), findsNothing);

      // Switch to Address Book
      await tester.tap(find.byKey(const ValueKey('desktop-nav-addressBook')));
      await tester.pumpAndSettle();
      expect(lastSelected, DesktopNavDestination.addressBook);
      expect(find.byKey(const ValueKey('address-book-content')), findsOneWidget);
      expect(find.byKey(const ValueKey('devices-content')), findsNothing);

      // Switch to Settings (in-shell)
      await tester.tap(find.byKey(const ValueKey('desktop-nav-settings')));
      await tester.pumpAndSettle();
      expect(lastSelected, DesktopNavDestination.settings);
      expect(find.byKey(const ValueKey('settings-content')), findsOneWidget);
      expect(find.byKey(const ValueKey('address-book-content')), findsNothing);

      // Switch back to Connect
      await tester.tap(find.byKey(const ValueKey('desktop-nav-connect')));
      await tester.pumpAndSettle();
      expect(lastSelected, DesktopNavDestination.connect);
      expect(find.byKey(const ValueKey('connect-content')), findsOneWidget);
    });

    testWidgets('CamelliaDesktopShell.switchTo switches destination programmatically', (
      tester,
    ) async {
      _setScreenSize(tester, width: 1024);
      late BuildContext shellChildContext;
      await tester.pumpWidget(
        _testApp(
          connectBuilder: (context) {
            shellChildContext = context;
            return const Center(child: Text('CHILD_VIEW'));
          },
        ),
      );
      await tester.pumpAndSettle();

      CamelliaDesktopShell.switchTo(
        shellChildContext,
        DesktopNavDestination.settings,
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('settings-content')), findsOneWidget);
    });
  });

  group('CamelliaDesktopShell Responsive Collapse & Expansion', () {
    testWidgets('expanded sidebar at wide viewport (>=840px) shows full labels and header', (
      tester,
    ) async {
      _setScreenSize(tester, width: 1024);
      await tester.pumpWidget(_testApp());
      await tester.pumpAndSettle();

      final sidebarFinder = find.byKey(const ValueKey('desktop-nav-sidebar'));
      final sidebarBox = tester.renderObject(sidebarFinder) as RenderBox;
      expect(sidebarBox.size.width, 220.0);

      // Verify text labels are visible in expanded mode
      expect(find.text('Connect'), findsOneWidget);
      expect(find.text('Devices'), findsOneWidget);
      expect(find.text('Address Book'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Camellia Remote'), findsOneWidget);
      expect(find.byTooltip('Collapse navigation'), findsOneWidget);
    });

    testWidgets('collapses into rail at narrow width (<840px)', (
      tester,
    ) async {
      _setScreenSize(tester, width: 750);
      await tester.pumpWidget(_testApp());
      await tester.pumpAndSettle();

      final sidebarFinder = find.byKey(const ValueKey('desktop-nav-sidebar'));
      final sidebarBox = tester.renderObject(sidebarFinder) as RenderBox;
      expect(sidebarBox.size.width, 64.0);

      // In rail mode, expand button is shown
      expect(find.byTooltip('Expand navigation'), findsOneWidget);
    });

    testWidgets('explicit collapse toggle switches between sidebar and rail', (
      tester,
    ) async {
      _setScreenSize(tester, width: 1024);
      await tester.pumpWidget(_testApp());
      await tester.pumpAndSettle();

      // Tap collapse toggle
      await tester.tap(find.byKey(const ValueKey('desktop-nav-collapse-toggle')));
      await tester.pumpAndSettle();

      var sidebarBox = tester.renderObject(
        find.byKey(const ValueKey('desktop-nav-sidebar')),
      ) as RenderBox;
      expect(sidebarBox.size.width, 64.0);

      // Tap expand toggle
      await tester.tap(find.byKey(const ValueKey('desktop-nav-collapse-toggle')));
      await tester.pumpAndSettle();

      sidebarBox = tester.renderObject(
        find.byKey(const ValueKey('desktop-nav-sidebar')),
      ) as RenderBox;
      expect(sidebarBox.size.width, 220.0);
    });

    testWidgets('fluid responsive layout works down to 600px width', (
      tester,
    ) async {
      _setScreenSize(tester, width: 600, height: 600);
      await tester.pumpWidget(_testApp());
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final contentFinder = find.byKey(const ValueKey('desktop-nav-content'));
      expect(contentFinder, findsOneWidget);

      final contentBox = tester.renderObject(contentFinder) as RenderBox;
      // 600 - 64 (rail) - 1 (divider) = 535
      expect(contentBox.size.width, closeTo(535.0, 1.0));
    });
  });

  group('CamelliaDesktopShell Draggable Divider & Styling', () {
    testWidgets('DraggableDivider resizes expanded sidebar smoothly within bounds', (
      tester,
    ) async {
      _setScreenSize(tester, width: 1024);
      await tester.pumpWidget(_testApp());
      await tester.pumpAndSettle();

      final dividerFinder = find.byKey(const ValueKey('desktop-nav-divider'));
      expect(dividerFinder, findsOneWidget);

      // Drag divider to expand sidebar right by 50px
      await tester.drag(dividerFinder, const Offset(50, 0));
      await tester.pumpAndSettle();

      var sidebarBox = tester.renderObject(
        find.byKey(const ValueKey('desktop-nav-sidebar')),
      ) as RenderBox;
      expect(sidebarBox.size.width, 270.0);

      // Drag divider beyond max bound (320)
      await tester.drag(dividerFinder, const Offset(200, 0));
      await tester.pumpAndSettle();

      sidebarBox = tester.renderObject(
        find.byKey(const ValueKey('desktop-nav-sidebar')),
      ) as RenderBox;
      expect(sidebarBox.size.width, 320.0);
    });

    testWidgets('active navigation item has rounded corner geometry and capsule highlight', (
      tester,
    ) async {
      _setScreenSize(tester, width: 1024);
      await tester.pumpWidget(_testApp());
      await tester.pumpAndSettle();

      final connectItem = find.descendant(
        of: find.byKey(const ValueKey('desktop-nav-connect')),
        matching: find.byType(AnimatedContainer),
      );
      expect(connectItem, findsOneWidget);

      final containerWidget = tester.widget<AnimatedContainer>(connectItem);
      final dec = containerWidget.decoration as BoxDecoration?;
      expect(dec?.borderRadius, BorderRadius.circular(CamelliaRadius.control));
      expect(
        dec?.color,
        CamelliaColors.indigo.withValues(alpha: 0.12),
      );
    });
  });

  group('DesktopHomePage Workspace Builders & Bounded Layout Defect Remediation', () {
    setUp(() async {
      await TestAppHarness.setUp();
    });

    testWidgets('buildDevicesWorkspace renders cleanly with bounded constraints', (tester) async {
      await TestAppHarness.pumpWidget(
        tester,
        surfaceSize: const Size(1024, 768),
        child: Scaffold(
          body: SizedBox(
            width: 800,
            height: 600,
            child: Builder(
              builder: (context) => DesktopHomePage.buildDevicesWorkspace(context),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('desktop-devices-workspace')), findsOneWidget);
      await TestAppHarness.tearDown(tester);
    });

    testWidgets('buildDevicesWorkspace defensively bounds height even when parent height is unbounded', (tester) async {
      await TestAppHarness.pumpWidget(
        tester,
        surfaceSize: const Size(1024, 768),
        child: Scaffold(
          body: SingleChildScrollView(
            child: Builder(
              builder: (context) => DesktopHomePage.buildDevicesWorkspace(context),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('desktop-devices-workspace')), findsOneWidget);
      await TestAppHarness.tearDown(tester);
    });

    testWidgets('buildAddressBookWorkspace renders cleanly with bounded constraints', (tester) async {
      await TestAppHarness.pumpWidget(
        tester,
        surfaceSize: const Size(1024, 768),
        child: Scaffold(
          body: SizedBox(
            width: 800,
            height: 600,
            child: Builder(
              builder: (context) => DesktopHomePage.buildAddressBookWorkspace(context),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('desktop-address-book-workspace')), findsOneWidget);
      await TestAppHarness.tearDown(tester);
    });

    testWidgets('buildAddressBookWorkspace defensively bounds height even when parent height is unbounded', (tester) async {
      await TestAppHarness.pumpWidget(
        tester,
        surfaceSize: const Size(1024, 768),
        child: Scaffold(
          body: SingleChildScrollView(
            child: Builder(
              builder: (context) => DesktopHomePage.buildAddressBookWorkspace(context),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('desktop-address-book-workspace')), findsOneWidget);
      await TestAppHarness.tearDown(tester);
    });

    testWidgets('CamelliaDesktopShell hosts real Devices and AddressBook workspaces without layout exception', (tester) async {
      await TestAppHarness.pumpWidget(
        tester,
        surfaceSize: const Size(1024, 768),
        child: Scaffold(
          body: CamelliaDesktopShell(
            initialDestination: DesktopNavDestination.devices,
            devicesBuilder: (context) => DesktopHomePage.buildDevicesWorkspace(context),
            addressBookBuilder: (context) => DesktopHomePage.buildAddressBookWorkspace(context),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('desktop-devices-workspace')), findsOneWidget);

      // Switch to address book destination
      await tester.tap(find.byKey(const ValueKey('desktop-nav-addressBook')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('desktop-address-book-workspace')), findsOneWidget);

      // Switch back to devices destination
      await tester.tap(find.byKey(const ValueKey('desktop-nav-devices')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('desktop-devices-workspace')), findsOneWidget);

      await TestAppHarness.tearDown(tester);
    });

    testWidgets('DesktopHomePage renders cleanly at 800x600 without RenderFlex overflow', (tester) async {
      await TestAppHarness.pumpWidget(
        tester,
        surfaceSize: const Size(800, 600),
        child: const DesktopHomePage(),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      expect(tester.takeException(), isNull);
      expect(find.byType(DesktopHomePage), findsOneWidget);
      await TestAppHarness.tearDown(tester);
    });

    testWidgets('DesktopHomePage renders cleanly at 1024x600 without RenderFlex overflow', (tester) async {
      await TestAppHarness.pumpWidget(
        tester,
        surfaceSize: const Size(1024, 600),
        child: const DesktopHomePage(),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      expect(tester.takeException(), isNull);
      expect(find.byType(DesktopHomePage), findsOneWidget);
      await TestAppHarness.tearDown(tester);
    });

    testWidgets('tapping Settings in access pane displays in-shell DesktopSettingPage with no modal overlay', (tester) async {
      await TestAppHarness.pumpWidget(
        tester,
        surfaceSize: const Size(1280, 800),
        child: const DesktopHomePage(),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      final settingsButton = find.widgetWithText(OutlinedButton, 'Settings');
      expect(settingsButton, findsOneWidget);

      await tester.tap(settingsButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull);
      // Assert exactly 1 DesktopSettingPage widget in-shell
      expect(find.byType(DesktopSettingPage), findsOneWidget);
      // Assert no modal dialog barrier overlay was spawned
      expect(find.byType(Dialog), findsNothing);
      expect(
        find.byWidgetPredicate((w) => w is ModalBarrier && w.dismissible),
        findsNothing,
      );

      await TestAppHarness.tearDown(tester);
    });
  });
}
