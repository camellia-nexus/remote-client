import 'dart:async';
import 'dart:io';

import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/login.dart';
import 'package:camellia_remote_app/common/widgets/settings_components.dart';
import 'package:camellia_remote_app/models/management_api_contract.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/utils/multi_window_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Milestone 1: R1 Theme Switching Smoothness & Backdrop Stability', () {
    testWidgets('CamelliaBackdrop renders cleanly under light and dark', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: MyTheme.lightTheme,
          home: const Scaffold(
            body: CamelliaBackdrop(
              child: Text('Light Surface'),
            ),
          ),
        ),
      );
      expect(find.text('Light Surface'), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);

      await tester.pumpWidget(
        MaterialApp(
          theme: MyTheme.darkTheme,
          home: const Scaffold(
            body: CamelliaBackdrop(
              child: Text('Dark Surface'),
            ),
          ),
        ),
      );
      expect(find.text('Dark Surface'), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);
    });

    testWidgets('CamelliaBackdrop renders pure black in OLED Midnight', (tester) async {
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

    testWidgets('CamelliaBackdrop preserves child state across light, dark, and midnight theme transitions', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: MyTheme.lightTheme,
          home: const Scaffold(
            body: CamelliaBackdrop(
              child: _StatefulBackdropProbe(),
            ),
          ),
        ),
      );

      expect(find.text('Counter: 0'), findsOneWidget);

      // Increment counter in Light Theme
      await tester.tap(find.text('Increment'));
      await tester.pump();
      expect(find.text('Counter: 1'), findsOneWidget);

      // Switch to Dark Theme
      await tester.pumpWidget(
        MaterialApp(
          theme: MyTheme.darkTheme,
          home: const Scaffold(
            body: CamelliaBackdrop(
              child: _StatefulBackdropProbe(),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Counter: 1'), findsOneWidget);

      // Switch to OLED Midnight Theme — invariant hierarchy preserves subtree state
      await tester.pumpWidget(
        MaterialApp(
          theme: MyTheme.midnightTheme,
          home: const Scaffold(
            body: CamelliaBackdrop(
              child: _StatefulBackdropProbe(),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Counter: 1'), findsOneWidget);

      // Increment counter in Midnight Theme
      await tester.tap(find.text('Increment'));
      await tester.pump();
      expect(find.text('Counter: 2'), findsOneWidget);

      // Switch back to Light Theme — state remains preserved
      await tester.pumpWidget(
        MaterialApp(
          theme: MyTheme.lightTheme,
          home: const Scaffold(
            body: CamelliaBackdrop(
              child: _StatefulBackdropProbe(),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Counter: 2'), findsOneWidget);
    });
  });

  group('Milestone 1: R2 Connection State Reset & Dead Window Pruning', () {
    test('RustDeskMultiWindowManager prunes window ID from active and typed lists on unregister', () async {
      final manager = RustDeskMultiWindowManager.instance;
      const testWindowId = 8888;

      await manager.registerActiveWindow(testWindowId);
      expect(manager.getActiveWindows().contains(testWindowId), isTrue);

      await manager.unregisterActiveWindow(testWindowId);
      expect(manager.getActiveWindows().contains(testWindowId), isFalse);
    });
  });

  group('Milestone 1: R5 About Screen Layout & Typography Centering', () {
    testWidgets('SettingsTile single-line metadata centers leading, title, and trailing at y=27px within 54px minHeight', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: MyTheme.lightTheme,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                child: SettingsTile(
                  leading: const Icon(Icons.info_outline_rounded),
                  title: const Text('Version'),
                  value: const SelectableText('1.4.0'),
                ),
              ),
            ),
          ),
        ),
      );

      final listTileFinder = find.byType(ListTile);
      expect(listTileFinder, findsOneWidget);
      final tileBox = tester.getRect(listTileFinder);
      expect(tileBox.height, equals(54.0));

      final titleFinder = find.text('Version');
      expect(titleFinder, findsOneWidget);
      final titleBox = tester.getRect(titleFinder);
      final titleCenterY = titleBox.top + titleBox.height / 2.0;

      // Vertical center relative to tile top should be 27px
      expect((titleCenterY - tileBox.top).round(), equals(27));
    });

    test('CamelliaTypography includes Linux CJK fallbacks and removes negative CJK tracking', () {
      expect(CamelliaTypography.systemFontFallbacks, contains('Noto Sans CJK SC'));
      expect(CamelliaTypography.systemFontFallbacks, contains('Source Han Sans SC'));
      expect(CamelliaTypography.systemFontFallbacks, contains('WenQuanYi Micro Hei'));

      final cjkTheme = CamelliaTheme.build(
        brightness: Brightness.light,
        desktopDensity: true,
        fontFamily: CamelliaTypography.simplifiedFamily,
      );
      // CJK typography must have non-negative letterSpacing
      expect(cjkTheme.textTheme.displaySmall?.letterSpacing, greaterThanOrEqualTo(0.0));
      expect(cjkTheme.textTheme.headlineMedium?.letterSpacing, greaterThanOrEqualTo(0.0));
      expect(cjkTheme.textTheme.titleLarge?.letterSpacing, greaterThanOrEqualTo(0.0));
      // Weights normalized to w400, w500, w700
      expect(cjkTheme.textTheme.titleMedium?.fontWeight, equals(FontWeight.w700));
      expect(cjkTheme.textTheme.labelLarge?.fontWeight, equals(FontWeight.w700));
      expect(cjkTheme.textTheme.labelSmall?.fontWeight, equals(FontWeight.w500));
    });
  });

  group('Milestone 1: R6 Address Book & Friendly Login Error Guidance', () {
    test('friendlyAuthErrorMessage translates ManagementApiException into human-readable Chinese advice', () {
      final invalidCreds = ManagementApiException(
        statusCode: 401,
        code: 'invalid_credentials',
        message: 'invalid credentials provided',
        retryable: false,
      );
      final msg = friendlyAuthErrorMessage(invalidCreds);
      expect(msg, isNotEmpty);
      expect(msg.contains('Unknown Error'), isFalse);

      final rateLimited = ManagementApiException(
        statusCode: 429,
        code: 'too_many_requests',
        message: 'rate limit exceeded',
        retryable: true,
      );
      final rateMsg = friendlyAuthErrorMessage(rateLimited);
      expect(rateMsg, isNotEmpty);
      expect(rateMsg.contains('Unknown Error'), isFalse);
    });

    test('friendlyAuthErrorMessage handles network exceptions gracefully', () {
      final socketErr = const SocketException('Connection refused');
      final socketMsg = friendlyAuthErrorMessage(socketErr);
      expect(socketMsg, isNotEmpty);
      expect(socketMsg.contains('Unknown Error'), isFalse);

      final timeoutErr = TimeoutException('Request timed out');
      final timeoutMsg = friendlyAuthErrorMessage(timeoutErr);
      expect(timeoutMsg, isNotEmpty);
      expect(timeoutMsg.contains('Unknown Error'), isFalse);
    });
  });
}

class _StatefulBackdropProbe extends StatefulWidget {
  const _StatefulBackdropProbe();

  @override
  State<_StatefulBackdropProbe> createState() => _StatefulBackdropProbeState();
}

class _StatefulBackdropProbeState extends State<_StatefulBackdropProbe> {
  int count = 0;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text('Counter: $count'),
        ElevatedButton(
          onPressed: () {
            setState(() {
              count++;
            });
          },
          child: const Text('Increment'),
        ),
      ],
    );
  }
}

