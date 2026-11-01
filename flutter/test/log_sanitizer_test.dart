import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/utils/sanitizer.dart';

void main() {
  group('LogSanitizer Tests', () {
    test('sanitizes password in JSON strings', () {
      final input = '{"type":0,"id":"123","password":"CANARY_SECRET_12345","connToken":"CANARY_TOKEN_67890"}';
      final sanitized = LogSanitizer.sanitize(input);

      expect(sanitized.contains('CANARY_SECRET_12345'), isFalse);
      expect(sanitized.contains('CANARY_TOKEN_67890'), isFalse);
      expect(sanitized, contains('"password":"[REDACTED]"'));
      expect(sanitized, contains('"connToken":"[REDACTED]"'));
    });

    test('sanitizes password and token in URI query parameters', () {
      final input = 'https://example.com/connect?id=123&password=CANARY_SECRET_PASSWORD&token=CANARY_AUTH_TOKEN&relay=true';
      final sanitized = LogSanitizer.sanitize(input);

      expect(sanitized.contains('CANARY_SECRET_PASSWORD'), isFalse);
      expect(sanitized.contains('CANARY_AUTH_TOKEN'), isFalse);
      expect(sanitized, contains('password=[REDACTED]'));
      expect(sanitized, contains('token=[REDACTED]'));
      expect(sanitized, contains('relay=true'));
    });

    test('sanitizes deep link password path', () {
      final input = 'camellia-remote://password/CANARY_PERM_PASS_123';
      final sanitized = LogSanitizer.sanitize(input);

      expect(sanitized.contains('CANARY_PERM_PASS_123'), isFalse);
      expect(sanitized, equals('camellia-remote://password/[REDACTED]'));
    });

    test('sanitizes user home paths', () {
      final inputLinux = '/home/alice/.config/camellia-remote';
      final sanitizedLinux = LogSanitizer.sanitize(inputLinux);
      expect(sanitizedLinux, equals('[USER_HOME]/.config/camellia-remote'));

      final inputWin = r'C:\Users\bob\AppData\Roaming';
      final sanitizedWin = LogSanitizer.sanitize(inputWin);
      expect(sanitizedWin, equals(r'[USER_HOME]\AppData\Roaming'));
    });

    test('zoneSpecification intercepts and sanitizes raw print statements', () {
      final printedLines = <String>[];
      runZoned(() {
        runZoned(() {
          print('Connecting with password=TOP_SECRET_CANARY and token=TOKEN_CANARY_123');
        }, zoneSpecification: LogSanitizer.zoneSpecification());
      }, zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => printedLines.add(line),
      ));

      expect(printedLines.length, equals(1));
      expect(printedLines.first.contains('TOP_SECRET_CANARY'), isFalse);
      expect(printedLines.first.contains('TOKEN_CANARY_123'), isFalse);
      expect(printedLines.first, equals('Connecting with password=[REDACTED] and token=[REDACTED]'));
    });
  });
}

