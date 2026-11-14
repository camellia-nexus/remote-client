import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group(
    'CSP-001: Web Client CSP Compliance & Inline Script Elimination Contracts (Batch 68)',
    () {
      late Directory flutterDir;
      late File indexHtml;
      late File bootstrapJs;

      setUpAll(() {
        if (Directory.current.path.endsWith('flutter')) {
          flutterDir = Directory.current;
        } else if (Directory.current.path.endsWith('client')) {
          flutterDir = Directory('${Directory.current.path}/flutter');
        } else {
          flutterDir = Directory('${Directory.current.path}/client/flutter');
        }

        indexHtml = File('${flutterDir.path}/web/index.html');
        bootstrapJs = File('${flutterDir.path}/web/bootstrap.js');

        expect(
          indexHtml.existsSync(),
          isTrue,
          reason: 'web/index.html must exist at ${indexHtml.path}',
        );
        expect(
          bootstrapJs.existsSync(),
          isTrue,
          reason: 'web/bootstrap.js must exist at ${bootstrapJs.path}',
        );
      });

      test('flutter/web/index.html contains zero inline scripts without nonces', () {
        final html = indexHtml.readAsStringSync();

        // Match all opening <script ...> tags
        final scriptTagRegex = RegExp(r'<script\b([^>]*)>', caseSensitive: false);
        final matches = scriptTagRegex.allMatches(html);

        expect(
          matches.isNotEmpty,
          isTrue,
          reason: 'web/index.html should load scripts',
        );

        final unnoncedInlineScripts = <String>[];

        for (final match in matches) {
          final attrs = match.group(1) ?? '';
          // Check for src="something" or src='something'
          final hasSrc = RegExp(r'''\bsrc\s*=\s*["'][^"']+["']''', caseSensitive: false).hasMatch(attrs);
          // Check for nonce="something" or nonce='something'
          final hasNonce = RegExp(r'''\bnonce\s*=\s*["'][^"']+["']''', caseSensitive: false).hasMatch(attrs);

          if (!hasSrc && !hasNonce) {
            unnoncedInlineScripts.add(match.group(0)!);
          }
        }

        expect(
          unnoncedInlineScripts,
          isEmpty,
          reason:
              'Found inline script tags without nonce, violating CSP script-src "self": $unnoncedInlineScripts',
        );
      });

      test('flutter/web/index.html imports external bootstrap.js with defer', () {
        final html = indexHtml.readAsStringSync();
        final hasBootstrapTag = RegExp(
          r'''<script\s+[^>]*src=["']bootstrap\.js["'][^>]*defer[^>]*></script>|<script\s+[^>]*defer[^>]*src=["']bootstrap\.js["'][^>]*></script>''',
          caseSensitive: false,
        ).hasMatch(html);

        expect(
          hasBootstrapTag,
          isTrue,
          reason: 'web/index.html must load bootstrap.js via <script src="bootstrap.js" defer></script>',
        );
      });

      test('flutter/web/bootstrap.js externalizes bootstrap initialization logic', () {
        final content = bootstrapJs.readAsStringSync();

        expect(
          content.contains('window.__CAMELLIA_REMOTE_WEB__'),
          isTrue,
          reason: 'bootstrap.js must initialize window.__CAMELLIA_REMOTE_WEB__',
        );
        expect(
          content.contains('removeLoading'),
          isTrue,
          reason: 'bootstrap.js must define removeLoading()',
        );
        expect(
          content.contains('flutter-first-frame'),
          isTrue,
          reason: 'bootstrap.js must register flutter-first-frame listener',
        );
        expect(
          content.contains('load'),
          isTrue,
          reason: 'bootstrap.js must register window load timeout fallback',
        );
      });
    },
  );
}
