import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/common/formatter/id_formatter.dart';
import 'package:camellia_remote_app/desktop/pages/connection_page.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import '../harness/test_app_harness.dart';

void main() {
  setUp(() async {
    await TestAppHarness.setUp();
  });

  group('Tier 1: Connection Panel & Mode Selection Coverage', () {
    testWidgets('1. ID formatting and unformatting grouped by triplets', (
      tester,
    ) async {
      await TestAppHarness.pumpWidget(
        tester,
        child: const ConnectionPage(showDevices: false),
      );

      final textField = find.byType(TextField);
      expect(textField, findsOneWidget);

      // Enter unformatted 9-digit ID
      await tester.enterText(textField, '987654321');
      await tester.pump();

      // Formatted text should be displayed with spaces
      final widget = tester.widget<TextField>(textField);
      expect(widget.controller?.text, equals('987 654 321'));
      expect(trimID(widget.controller!.text), equals('987654321'));

      await TestAppHarness.tearDown(tester);
    });

    testWidgets('2. Clear text input resets field and unspaced ID', (
      tester,
    ) async {
      await TestAppHarness.pumpWidget(
        tester,
        child: const ConnectionPage(showDevices: false),
      );

      final textField = find.byType(TextField);
      await tester.enterText(textField, '123456');
      await tester.pump();

      expect(
        tester.widget<TextField>(textField).controller?.text,
        equals('123 456'),
      );

      // Clear input
      await tester.enterText(textField, '');
      await tester.pump();

      expect(tester.widget<TextField>(textField).controller?.text, isEmpty);

      await TestAppHarness.tearDown(tester);
    });

    testWidgets(
      '3. Mode selector switches between Desktop, Files, Camera, and Terminal',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          child: const ConnectionPage(showDevices: false),
        );

        // Verify segmented button modes are present
        expect(find.byIcon(Icons.desktop_windows_outlined), findsOneWidget);
        expect(find.byIcon(Icons.folder_copy_outlined), findsOneWidget);
        expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);
        expect(find.byIcon(Icons.terminal_rounded), findsOneWidget);

        // Tap Files mode
        await tester.tap(find.byIcon(Icons.folder_copy_outlined));
        await tester.pumpAndSettle();

        // Section accent should update to azure for files mode
        final sectionFiles = tester.widget<CamelliaSection>(
          find.byType(CamelliaSection),
        );
        expect(sectionFiles.accent, equals(CamelliaColors.azure));

        // Tap Camera mode
        await tester.tap(find.byIcon(Icons.videocam_outlined));
        await tester.pumpAndSettle();

        final sectionCamera = tester.widget<CamelliaSection>(
          find.byType(CamelliaSection),
        );
        expect(sectionCamera.accent, equals(CamelliaColors.aqua));

        // Tap Terminal mode
        await tester.tap(find.byIcon(Icons.terminal_rounded));
        await tester.pumpAndSettle();

        final sectionTerminal = tester.widget<CamelliaSection>(
          find.byType(CamelliaSection),
        );
        expect(sectionTerminal.accent, equals(CamelliaColors.orchid));

        // Tap Desktop mode
        await tester.tap(find.byIcon(Icons.desktop_windows_outlined));
        await tester.pumpAndSettle();

        final sectionDesktop = tester.widget<CamelliaSection>(
          find.byType(CamelliaSection),
        );
        expect(sectionDesktop.accent, equals(CamelliaColors.coral));

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets('4. Autocomplete dropdown filters and populates selected peer ID', (
      tester,
    ) async {
      await TestAppHarness.pumpWidget(
        tester,
        child: const ConnectionPage(showDevices: false),
      );

      final textField = find.byType(TextField);

      // Focus and enter 'Alice' to trigger autocomplete match from TestDataFixtures
      await tester.tap(textField);
      await tester.enterText(textField, 'Alice');
      await tester.pumpAndSettle();

      // Dropdown suggestion should appear
      final suggestion = find.textContaining('Alice');
      expect(suggestion, findsWidgets);

      // Selecting the autocomplete option fills the peer ID ('100001')
      await tester.tap(suggestion.last);
      await tester.pumpAndSettle();

      final controller = tester.widget<TextField>(textField).controller;
      expect(trimID(controller!.text), equals('100001'));

      await TestAppHarness.tearDown(tester);
    });

    testWidgets('5. Empty ID validation blocks connection attempt', (
      tester,
    ) async {
      await TestAppHarness.pumpWidget(
        tester,
        child: const ConnectionPage(showDevices: false),
      );

      final textField = find.byType(TextField);
      await tester.enterText(textField, '');
      await tester.pump();

      // Tap Connect button
      final connectBtn = find.widgetWithText(FilledButton, 'Connect');
      expect(connectBtn, findsOneWidget);
      await tester.tap(connectBtn);
      await tester.pumpAndSettle();

      // No session should have been started
      expect(TestAppHarness.fakeBridge.addedSessions, isEmpty);

      await TestAppHarness.tearDown(tester);
    });

    testWidgets('6. Online status indicator renders service status state', (
      tester,
    ) async {
      await TestAppHarness.pumpWidget(
        tester,
        child: const ConnectionPage(showDevices: false),
      );

      // OnlineStatusWidget should be rendered in the header trailing area
      expect(find.byType(OnlineStatusWidget), findsOneWidget);

      await TestAppHarness.tearDown(tester);
    });
  });
}
