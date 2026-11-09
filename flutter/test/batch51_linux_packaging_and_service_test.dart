import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/common.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BUILD-011: URI Scheme Parser & Command Argument Mapping Contract', () {
    test('parses legacy connection URI to --connect command args', () {
      final uri = Uri.parse('camellia-remote://connection/new/123456789');
      final args = urlLinkToCmdArgs(uri);
      expect(args, isNotNull);
      expect(args, contains('--connect'));
      expect(args, contains('123456789'));
    });

    test('parses direct peer ID in authority to --connect command args', () {
      final uri = Uri.parse('camellia-remote://123456789');
      final args = urlLinkToCmdArgs(uri);
      expect(args, isNotNull);
      expect(args, contains('--connect'));
      expect(args, contains('123456789'));
    });

    test('parses peer ID with relay path specifier', () {
      final uri = Uri.parse('camellia-remote://123456789/r@relay.example.com');
      final args = urlLinkToCmdArgs(uri);
      expect(args, isNotNull);
      expect(args, contains('--connect'));
      expect(args, contains('123456789/r@relay.example.com'));
    });

    test('strips cleartext password query parameter per CRED-001 security perimeter', () {
      final uri = Uri.parse('camellia-remote://connect/987654321?password=secretPass');
      final args = urlLinkToCmdArgs(uri);
      expect(args, isNotNull);
      expect(args, contains('--connect'));
      expect(args, contains('987654321'));
      // Insecure cleartext password in query string must NOT be passed to command line args
      expect(args, isNot(contains('--password')));
      expect(args, isNot(contains('secretPass')));
    });

    test('rejects insecure password authority per CRED-001', () {
      final uri = Uri.parse('camellia-remote://password/insecurePass');
      final args = urlLinkToCmdArgs(uri);
      expect(args, isNull);
    });

    test('parses file-transfer URI correctly', () {
      final uri = Uri.parse('camellia-remote://file-transfer/112233445');
      final args = urlLinkToCmdArgs(uri);
      expect(args, isNotNull);
      expect(args, contains('--file-transfer'));
      expect(args, contains('112233445'));
    });

    test('parses view-camera URI correctly', () {
      final uri = Uri.parse('camellia-remote://view-camera/556677889');
      final args = urlLinkToCmdArgs(uri);
      expect(args, isNotNull);
      expect(args, contains('--view-camera'));
      expect(args, contains('556677889'));
    });

    test('parses port-forward URI correctly', () {
      final uri = Uri.parse('camellia-remote://port-forward/998877665');
      final args = urlLinkToCmdArgs(uri);
      expect(args, isNotNull);
      expect(args, contains('--port-forward'));
      expect(args, contains('998877665'));
    });

    test('parses terminal and terminal-admin URIs correctly', () {
      final termUri = Uri.parse('camellia-remote://terminal/334455667');
      final termArgs = urlLinkToCmdArgs(termUri);
      expect(termArgs, isNotNull);
      expect(termArgs, contains('--terminal'));
      expect(termArgs, contains('334455667'));

      final adminUri = Uri.parse('camellia-remote://terminal-admin/334455667');
      final adminArgs = urlLinkToCmdArgs(adminUri);
      expect(adminArgs, isNotNull);
      expect(adminArgs, contains('--terminal-admin'));
      expect(adminArgs, contains('334455667'));
    });

    test('handles empty or blank authority URIs gracefully without throw', () {
      final emptyUri = Uri.parse('camellia-remote:///');
      final args = urlLinkToCmdArgs(emptyUri);
      expect(args, isNotNull);
      expect(args, isEmpty);
    });
  });
}
