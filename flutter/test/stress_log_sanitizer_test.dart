import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/utils/sanitizer.dart';

void main() {
  group('Empirical Challenge & Stress Tests for LogSanitizer (LOG-006)', () {
    test('adversarial JSON matrix: verifies redaction of standard credential keys', () {
      final jsonTestCases = <String, String>{
        // Standard double quotes
        '{"password":"CANARY_JSON_PW_01"}': 'CANARY_JSON_PW_01',
        '{"connToken":"CANARY_JSON_CT_02"}': 'CANARY_JSON_CT_02',
        '{"token":"CANARY_JSON_TK_03"}': 'CANARY_JSON_TK_03',
        '{"access_token":"CANARY_JSON_AT_04"}': 'CANARY_JSON_AT_04',
        '{"refresh_token":"CANARY_JSON_RT_05"}': 'CANARY_JSON_RT_05',
        '{"secret":"CANARY_JSON_SEC_06"}': 'CANARY_JSON_SEC_06',
        '{"address_book_password":"CANARY_JSON_ABP_07"}': 'CANARY_JSON_ABP_07',
        '{"pin":"CANARY_JSON_PIN_08"}': 'CANARY_JSON_PIN_08',

        // Spaces and no quotes around keys
        '{password: "CANARY_JSON_PW_09"}': 'CANARY_JSON_PW_09',
        '{connToken : "CANARY_JSON_CT_10"}': 'CANARY_JSON_CT_10',
        'token = "CANARY_JSON_TK_11"': 'CANARY_JSON_TK_11',

        // Case insensitivity
        '{"Password":"CANARY_JSON_PW_12"}': 'CANARY_JSON_PW_12',
        '{"CONNTOKEN":"CANARY_JSON_CT_13"}': 'CANARY_JSON_CT_13',
        '{"ACCESS_TOKEN":"CANARY_JSON_AT_14"}': 'CANARY_JSON_AT_14',
        '{"SECRET":"CANARY_JSON_SEC_15"}': 'CANARY_JSON_SEC_15',

        // Nested JSON
        '{"meta":{"id":123},"auth":{"token":"CANARY_JSON_TK_16","secret":"CANARY_JSON_SEC_17"}}':
            'CANARY_JSON_TK_16',

        // Array of JSON objects
        '[{"password":"CANARY_JSON_PW_18"},{"token":"CANARY_JSON_TK_19"}]':
            'CANARY_JSON_PW_18',

        // Multi-line JSON
        '''
        {
          "type": 0,
          "password": "CANARY_JSON_PW_20",
          "connToken": "CANARY_JSON_CT_21"
        }
        ''': 'CANARY_JSON_PW_20',
      };

      for (final entry in jsonTestCases.entries) {
        final sanitized = LogSanitizer.sanitize(entry.key);
        expect(
          sanitized.contains(entry.value),
          isFalse,
          reason: 'Canary token ${entry.value} leaked in: $sanitized',
        );
        expect(
          sanitized.contains('[REDACTED]'),
          isTrue,
          reason: 'Missing [REDACTED] replacement in: $sanitized',
        );
      }
    });

    test('reproduces failure modes in JSON credential pattern (spaces, commas, escaped quotes)', () {
      // 1. Escaped JSON quotes (common in IPC / multi-window serialized arguments)
      final escapedJson = r'{\"password\":\"CANARY_ESCAPED_LEAK\"}';
      final sanitizedEscaped = LogSanitizer.sanitize(escapedJson);
      // Empirical verification: escaped quotes are NOT matched by _credentialJsonPattern
      expect(
        sanitizedEscaped.contains('CANARY_ESCAPED_LEAK'),
        isTrue,
        reason: 'Empirical finding: Escaped quotes in JSON bypass _credentialJsonPattern',
      );

      // 2. Passwords with spaces (passphrases)
      final spacePassphrase = '{"password":"CANARY_START CANARY_REST_LEAK"}';
      final sanitizedSpace = LogSanitizer.sanitize(spacePassphrase);
      // Value regex stops at whitespace: only the first word is redacted
      expect(
        sanitizedSpace.contains('CANARY_REST_LEAK'),
        isTrue,
        reason: 'Empirical finding: Passwords with spaces leak remaining tokens',
      );

      // 3. Passwords with commas
      final commaPassword = '{"password":"CANARY_PREFIX,CANARY_SUFFIX_LEAK"}';
      final sanitizedComma = LogSanitizer.sanitize(commaPassword);
      expect(
        sanitizedComma.contains('CANARY_SUFFIX_LEAK'),
        isTrue,
        reason: 'Empirical finding: Passwords with commas leak after comma',
      );
    });

    test('adversarial URI query parameter matrix', () {
      final uriTestCases = <String, List<String>>{
        'https://example.com/connect?password=CANARY_URI_PW_01': [
          'CANARY_URI_PW_01'
        ],
        'https://example.com/connect?token=CANARY_URI_TK_02': [
          'CANARY_URI_TK_02'
        ],
        'https://example.com/connect?secret=CANARY_URI_SEC_03': [
          'CANARY_URI_SEC_03'
        ],
        'https://example.com/connect?key=CANARY_URI_KEY_04': [
          'CANARY_URI_KEY_04'
        ],
        // Multiple credentials mixed with safe parameters
        'https://gateway.camellia.com:8443/v1/auth?peer_id=123&password=CANARY_URI_PW_05&token=CANARY_URI_TK_06&relay=true&key=CANARY_URI_KEY_07':
            ['CANARY_URI_PW_05', 'CANARY_URI_TK_06', 'CANARY_URI_KEY_07'],
        // Case variations
        'https://example.com/?PASSWORD=CANARY_URI_PW_08&Token=CANARY_URI_TK_09':
            ['CANARY_URI_PW_08', 'CANARY_URI_TK_09'],
        // URL encoded characters
        'https://example.com/?password=CANARY_URI_PW_10%21%40%23': [
          'CANARY_URI_PW_10'
        ],
      };

      for (final entry in uriTestCases.entries) {
        final sanitized = LogSanitizer.sanitize(entry.key);
        for (final canary in entry.value) {
          expect(
            sanitized.contains(canary),
            isFalse,
            reason: 'URI canary $canary leaked in: $sanitized',
          );
        }
        expect(sanitized.contains('[REDACTED]'), isTrue);
      }
    });

    test('reproduces failure modes in URI credential pattern (code, pin, macOS user path)', () {
      // 1. OIDC authorization code in query parameter
      final oidcUri = 'https://gateway.example.com/oauth/callback?code=CANARY_OIDC_CODE_LEAK&state=xyz';
      final sanitizedOidc = LogSanitizer.sanitize(oidcUri);
      expect(
        sanitizedOidc.contains('CANARY_OIDC_CODE_LEAK'),
        isTrue,
        reason: 'Empirical finding: URI pattern does not redact "code=" query parameter',
      );

      // 2. macOS user home directory
      final macPath = '/Users/alice_smith/Library/Application Support/camellia-remote';
      final sanitizedMac = LogSanitizer.sanitize(macPath);
      expect(
        sanitizedMac.contains('alice_smith'),
        isTrue,
        reason: 'Empirical finding: _userPathPattern does not match macOS /Users/ paths',
      );
    });

    test('adversarial deep link password patterns', () {
      final deepLinkCases = <String, String>{
        'camellia-remote://password/CANARY_DEEP_PW_01': 'CANARY_DEEP_PW_01',
        'camellia-remote://password/CANARY_DEEP_PW_02?extra=param':
            'CANARY_DEEP_PW_02',
        'CAMELLIA-REMOTE://PASSWORD/CANARY_DEEP_PW_03': 'CANARY_DEEP_PW_03',
        'camellia-remote://password/CANARY_DEEP_PW_04/subpath':
            'CANARY_DEEP_PW_04',
      };

      for (final entry in deepLinkCases.entries) {
        final sanitized = LogSanitizer.sanitize(entry.key);
        expect(
          sanitized.contains(entry.value),
          isFalse,
          reason: 'Deep link canary ${entry.value} leaked in: $sanitized',
        );
        expect(sanitized.contains('[REDACTED]'), isTrue);
      }
    });

    test('adversarial user home paths for Linux and Windows C: drive', () {
      final pathCases = <String, String>{
        '/home/alice/secret_canary_file.txt': '/home/alice',
        '/home/bob_smith/.config/camellia-remote/key': '/home/bob_smith',
        '/home/developer-123/projects/client': '/home/developer-123',
        '/HOME/UPPERCASE_USER/doc.pdf': '/HOME/UPPERCASE_USER',
        r'C:\Users\Administrator\Desktop\canary.txt': r'C:\Users\Administrator',
        r'C:\Users\JohnDoe\AppData\Roaming\secret': r'C:\Users\JohnDoe',
        r'c:\users\localuser\config.json': r'c:\users\localuser',
      };

      for (final entry in pathCases.entries) {
        final sanitized = LogSanitizer.sanitize(entry.key);
        expect(
          sanitized.contains(entry.value),
          isFalse,
          reason: 'User home directory ${entry.value} leaked in: $sanitized',
        );
        expect(sanitized.contains('[USER_HOME]'), isTrue);
      }
    });

    test('zoneSpecification intercepts nested prints and prevents leaks', () {
      final logs = <String>[];

      runZoned(() {
        runZoned(() {
          print('Launching with {"password":"CANARY_ZONE_PW_1","token":"CANARY_ZONE_TK_2"}');
          print('Connecting to https://api.test/auth?password=CANARY_ZONE_PW_3&key=CANARY_ZONE_KEY_4');
          print('Handling deep link camellia-remote://password/CANARY_ZONE_PW_5');
          print('Config loaded from /home/victim_user/app.conf and C:\\Users\\victim_win\\app.conf');
        }, zoneSpecification: LogSanitizer.zoneSpecification());
      }, zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => logs.add(line),
      ));

      expect(logs.length, equals(4));

      for (var i = 1; i <= 5; i++) {
        final canary = 'CANARY_ZONE_PW_$i';
        for (final line in logs) {
          expect(line.contains(canary), isFalse, reason: 'Canary $canary leaked in zone output: $line');
        }
      }
      expect(logs[0].contains('CANARY_ZONE_TK_2'), isFalse);
      expect(logs[1].contains('CANARY_ZONE_KEY_4'), isFalse);
      expect(logs[3].contains('/home/victim_user'), isFalse);
      expect(logs[3].contains(r'C:\Users\victim_win'), isFalse);
    });

    test('debugPrint redirection intercepts and sanitizes diagnostic outputs', () {
      LogSanitizer.install();

      final captured = <String>[];
      final previousPrint = debugPrint;
      try {
        debugPrint = (String? message, {int? wrapWidth}) {
          if (message != null) captured.add(message);
        };

        // Re-install LogSanitizer over the captured callback
        LogSanitizer.install();

        debugPrint('call kWindowConnect with args {"password":"CANARY_DEBUG_PW_1","connToken":"CANARY_DEBUG_CT_2"}');
        debugPrint('initialLink: https://remote.camellia.com/?token=CANARY_DEBUG_TK_3');
        debugPrint('Config path: /home/admin_canary/config');

        expect(captured.length, equals(3));
        expect(captured[0].contains('CANARY_DEBUG_PW_1'), isFalse);
        expect(captured[0].contains('CANARY_DEBUG_CT_2'), isFalse);
        expect(captured[1].contains('CANARY_DEBUG_TK_3'), isFalse);
        expect(captured[2].contains('/home/admin_canary'), isFalse);

        expect(captured[0], contains('[REDACTED]'));
        expect(captured[1], contains('[REDACTED]'));
        expect(captured[2], contains('[USER_HOME]'));
      } finally {
        debugPrint = previousPrint;
      }
    });
  });
}
