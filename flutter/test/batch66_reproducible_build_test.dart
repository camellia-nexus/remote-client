import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group(
    'BUILD-003: Reproducible Native Build & UTC Date Standardization Contracts (Batch 66)',
    () {
      late Directory clientRoot;
      late File versionRs;
      late File buildRs;
      late File buildPy;
      late File syncVersionSh;
      late File buildWebSh;
      late File platformFfiWeb;

      setUpAll(() {
        if (Directory.current.path.endsWith('flutter')) {
          clientRoot = Directory.current.parent;
        } else {
          clientRoot = Directory.current;
        }

        versionRs = File('${clientRoot.path}/src/version.rs');
        buildRs = File('${clientRoot.path}/build.rs');
        buildPy = File('${clientRoot.path}/build.py');
        syncVersionSh = File('${clientRoot.path}/.github/scripts/sync-version.sh');
        buildWebSh = File('${clientRoot.path}/flutter/web/tools/build_web.sh');
        platformFfiWeb = File('${clientRoot.path}/flutter/lib/web/platform_ffi_web.dart');

        expect(
          versionRs.existsSync(),
          isTrue,
          reason: 'src/version.rs must exist and be tracked in Git',
        );
        expect(
          buildRs.existsSync(),
          isTrue,
          reason: 'build.rs must exist',
        );
        expect(
          buildPy.existsSync(),
          isTrue,
          reason: 'build.py must exist',
        );
        expect(
          syncVersionSh.existsSync(),
          isTrue,
          reason: '.github/scripts/sync-version.sh must exist',
        );
        expect(
          buildWebSh.existsSync(),
          isTrue,
          reason: 'build_web.sh must exist',
        );
        expect(
          platformFfiWeb.existsSync(),
          isTrue,
          reason: 'platform_ffi_web.dart must exist',
        );
      });

      test('src/version.rs declares compile-time version and reproducible build date', () {
        final content = versionRs.readAsStringSync();
        expect(
          content.contains('pub const VERSION: &str = env!("CARGO_PKG_VERSION");'),
          isTrue,
          reason: 'VERSION must be injected from CARGO_PKG_VERSION at compile time',
        );
        expect(
          content.contains('option_env!("CAMELLIA_BUILD_DATE")'),
          isTrue,
          reason: 'BUILD_DATE must check CAMELLIA_BUILD_DATE via option_env!',
        );
        expect(
          content.contains('"1970-01-01 00:00 UTC"'),
          isTrue,
          reason: 'Fallback date must be standardized UTC string',
        );
      });

      test('build.rs invokes protocol::gen_version()', () {
        final content = buildRs.readAsStringSync();
        expect(
          content.contains('camellia_remote_protocol::gen_version();'),
          isTrue,
          reason: 'build.rs must call camellia_remote_protocol::gen_version()',
        );
      });

      test('sync-version.sh implements reproducible UTC build date contracts', () {
        final content = syncVersionSh.readAsStringSync();
        expect(
          content.contains('source date epoch must be a non-negative decimal integer'),
          isTrue,
          reason: 'sync-version.sh must validate non-negative epoch',
        );
        expect(
          content.contains('%Y-%m-%d %H:%M UTC'),
          isTrue,
          reason: 'sync-version.sh must standardize date formatting to UTC',
        );
        expect(
          content.contains('option_env!("CAMELLIA_BUILD_DATE")'),
          isTrue,
          reason: 'sync-version.sh must preserve option_env! in src/version.rs',
        );
      });

      test('build.py supports deterministic --source-date-epoch CLI flag', () {
        final content = buildPy.readAsStringSync();
        expect(
          content.contains('--source-date-epoch'),
          isTrue,
          reason: 'build.py must accept --source-date-epoch CLI argument',
        );
        expect(
          content.contains('resolve_source_date_epoch'),
          isTrue,
          reason: 'build.py must define resolve_source_date_epoch()',
        );
      });

      test('build_web.sh standardizes build date to UTC', () {
        final content = buildWebSh.readAsStringSync();
        expect(
          content.contains("'+%Y-%m-%d %H:%M UTC'"),
          isTrue,
          reason: 'build_web.sh must format build date as YYYY-MM-DD HH:MM UTC',
        );
      });

      test('platform_ffi_web declares BUILD_DATE environment variable', () {
        final content = platformFfiWeb.readAsStringSync();
        expect(
          content.contains("const String _buildBuildDate = String.fromEnvironment("),
          isTrue,
          reason: 'platform_ffi_web.dart must bind BUILD_DATE environment define',
        );
        expect(
          content.contains("'BUILD_DATE'"),
          isTrue,
          reason: 'Environment key must be BUILD_DATE',
        );
      });

      test('UTC build date regex and lexicographical ordering contract', () {
        final utcRegex = RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC$');

        expect(utcRegex.hasMatch('2026-11-12 00:55 UTC'), isTrue);
        expect(utcRegex.hasMatch('1970-01-01 00:00 UTC'), isTrue);
        expect(utcRegex.hasMatch('2026-11-12 00:55'), isFalse);
        expect(utcRegex.hasMatch('2026-11-12 00:55 UTC\n'), isFalse);

        // Lexicographical ordering mirrors chronological ordering
        final date1 = '2026-11-11 23:59 UTC';
        final date2 = '2026-11-12 00:00 UTC';
        expect(date2.compareTo(date1) > 0, isTrue);
      });
    },
  );
}
