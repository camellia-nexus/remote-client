import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/desktop/widgets/identity_board_widgets.dart';
import '../harness/test_app_harness.dart';

/// Test fixture representing the desktop ID board component.
class IdBoardFixture extends StatelessWidget {
  const IdBoardFixture({super.key});

  @override
  Widget build(BuildContext context) => const IdentityIdBoard();
}

/// Test fixture representing the desktop Password board component.
class PasswordBoardFixture extends StatelessWidget {
  const PasswordBoardFixture({super.key});

  @override
  Widget build(BuildContext context) => const IdentityPasswordBoard();
}

/// Composite widget of both boards.
class IdentityBoardsFixture extends StatelessWidget {
  const IdentityBoardsFixture({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        children: const [
          IdBoardFixture(),
          PasswordBoardFixture(),
        ],
      ),
    );
  }
}

void main() {
  final List<String> clipboardLog = [];

  setUp(() async {
    clipboardLog.clear();
    await TestAppHarness.setUp(
      initialServerId: '888 999 111',
      initialPassword: 'SecretPassword99',
    );

    // Mock clipboard system channel
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (
          MethodCall methodCall,
        ) async {
          if (methodCall.method == 'Clipboard.setData') {
            final text = methodCall.arguments['text'] as String?;
            if (text != null) {
              clipboardLog.add(text);
            }
            return null;
          }
          if (methodCall.method == 'Clipboard.getData') {
            return <String, dynamic>{'text': clipboardLog.lastOrNull ?? ''};
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  group('Tier 1: ID & Password Access Boards Coverage', () {
    testWidgets('1. ID board displays configured server ID', (tester) async {
      await TestAppHarness.pumpWidget(
        tester,
        child: const IdentityBoardsFixture(),
      );

      // Verify ID label and server ID text are visible
      expect(find.text('ID'), findsOneWidget);
      expect(find.text('888 999 111'), findsOneWidget);

      await TestAppHarness.tearDown(tester);
    });

    testWidgets('2. Double-tap on ID board copies server ID to clipboard', (
      tester,
    ) async {
      await TestAppHarness.pumpWidget(
        tester,
        child: const IdentityBoardsFixture(),
      );

      final idFinder = find.text('888 999 111');
      expect(idFinder, findsOneWidget);

      // Double-tap the ID to trigger copy
      await tester.tap(idFinder);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(idFinder);
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));

      expect(clipboardLog, contains('888 999 111'));

      await TestAppHarness.tearDown(tester);
    });

    testWidgets('3. Password board displays one-time password', (
      tester,
    ) async {
      await TestAppHarness.pumpWidget(
        tester,
        child: const IdentityBoardsFixture(),
      );

      // Verify One-time Password section
      expect(find.text('One-time Password'), findsOneWidget);
      expect(find.text('SecretPassword99'), findsOneWidget);

      await TestAppHarness.tearDown(tester);
    });

    testWidgets(
      '4. Double-tap on password board copies password to clipboard',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          child: const IdentityBoardsFixture(),
        );

        final passwordFinder = find.text('SecretPassword99');
        expect(passwordFinder, findsOneWidget);

        // Double-tap password to copy
        await tester.tap(passwordFinder);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(passwordFinder);
        await tester.pump();
        await tester.pump(const Duration(seconds: 4));

        expect(clipboardLog, contains('SecretPassword99'));

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '5. Refresh password button updates temporary password',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          child: const IdentityBoardsFixture(),
        );

        expect(find.text('SecretPassword99'), findsOneWidget);

        final refreshBtn = find.byTooltip('Refresh Password');
        expect(refreshBtn, findsOneWidget);

        // Tap refresh button
        await tester.tap(refreshBtn);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(
          TestAppHarness.fakeBridge.refreshPasswordCallCount,
          equals(1),
        );
        expect(find.text('UpdatedPass1'), findsOneWidget);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '6. Change password action triggers settings safety navigation',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: const IdentityBoardsFixture(),
        );

        final editBtn = find.byTooltip('Change Password');
        expect(editBtn, findsOneWidget);

        // Tapping Change Password triggers navigation
        await tester.tap(editBtn);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        // Safety settings should be opened
        expect(find.text('Security'), findsWidgets);

        // Dismiss settings overlay before tear down
        Navigator.of(globalKey.currentContext!).pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '7. One-click copy button on ID board copies ID to clipboard with checkmark transition',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          child: const IdentityBoardsFixture(),
        );

        final copyIdBtn = find.byTooltip('Copy ID');
        expect(copyIdBtn, findsOneWidget);

        // Tap copy button
        await tester.tap(copyIdBtn);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        expect(clipboardLog, contains('888 999 111'));
        // Checkmark icon rendered during feedback
        expect(find.byIcon(Icons.check_rounded), findsWidgets);

        await tester.pump(const Duration(seconds: 4));
        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '8. One-click copy button on Password board copies password to clipboard with checkmark transition',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          child: const IdentityBoardsFixture(),
        );

        final copyPwBtn = find.byTooltip('Copy Password');
        expect(copyPwBtn, findsOneWidget);

        // Tap copy password button
        await tester.tap(copyPwBtn);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        expect(clipboardLog, contains('SecretPassword99'));
        expect(find.byIcon(Icons.check_rounded), findsWidgets);

        await tester.pump(const Duration(seconds: 4));
        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '9. Password visibility eye toggle switches obscure password state',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          child: const IdentityBoardsFixture(),
        );

        // Initial state: password not obscured, eye shows "Hide Password"
        final hideBtn = find.byTooltip('Hide Password');
        expect(hideBtn, findsOneWidget);

        // Tap to hide/obscure password
        await tester.tap(hideBtn);
        await tester.pump();

        // Button should switch tooltip to "Show Password"
        final showBtn = find.byTooltip('Show Password');
        expect(showBtn, findsOneWidget);

        // TextField obscureText is now true
        final textField = tester.widget<TextField>(
          find.descendant(
            of: find.byType(IdentityPasswordBoard),
            matching: find.byType(TextField),
          ),
        );
        expect(textField.obscureText, isTrue);

        await TestAppHarness.tearDown(tester);
      },
    );
  });
}
