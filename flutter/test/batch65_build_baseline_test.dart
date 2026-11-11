import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group(
    'BUILD-001: Quality Baselines & Generation Prerequisite Contracts (Batch 65)',
    () {
      late Directory clientRoot;
      late File clippyBaseline;
      late File flutterBaseline;
      late File verifyScript;
      late File buildRs;
      late File buildPy;
      late File ciYml;
      late File bridgeRs;
      late File bridgeIos;
      late File bridgeMac;
      late File bridgeDart;

      setUpAll(() {
        if (Directory.current.path.endsWith('flutter')) {
          clientRoot = Directory.current.parent;
        } else {
          clientRoot = Directory.current;
        }

        clippyBaseline = File(
          '${clientRoot.path}/.github/config/clippy-baseline.json',
        );
        flutterBaseline = File(
          '${clientRoot.path}/.github/config/flutter-analyze-baseline.json',
        );
        verifyScript = File(
          '${clientRoot.path}/.github/scripts/verify_quality_baselines.py',
        );
        buildRs = File('${clientRoot.path}/build.rs');
        buildPy = File('${clientRoot.path}/build.py');
        ciYml = File('${clientRoot.path}/.github/workflows/ci.yml');
        bridgeRs = File('${clientRoot.path}/src/bridge_generated.rs');
        bridgeIos = File(
          '${clientRoot.path}/flutter/ios/Runner/bridge_generated.h',
        );
        bridgeMac = File(
          '${clientRoot.path}/flutter/macos/Runner/bridge_generated.h',
        );
        bridgeDart = File(
          '${clientRoot.path}/flutter/lib/generated_bridge/frb_generated.dart',
        );

        expect(
          clippyBaseline.existsSync(),
          isTrue,
          reason: 'clippy-baseline.json must exist',
        );
        expect(
          flutterBaseline.existsSync(),
          isTrue,
          reason: 'flutter-analyze-baseline.json must exist',
        );
        expect(
          verifyScript.existsSync(),
          isTrue,
          reason: 'verify_quality_baselines.py must exist',
        );
        expect(buildRs.existsSync(), isTrue, reason: 'build.rs must exist');
        expect(buildPy.existsSync(), isTrue, reason: 'build.py must exist');
        expect(ciYml.existsSync(), isTrue, reason: 'ci.yml must exist');
      });

      test('Bridge generation files exist and are populated', () {
        expect(
          bridgeRs.existsSync(),
          isTrue,
          reason: 'src/bridge_generated.rs must exist',
        );
        expect(
          bridgeRs.lengthSync() > 1000,
          isTrue,
          reason: 'src/bridge_generated.rs must not be empty',
        );

        expect(
          bridgeIos.existsSync(),
          isTrue,
          reason: 'iOS bridge header must exist',
        );
        expect(
          bridgeMac.existsSync(),
          isTrue,
          reason: 'macOS bridge header must exist',
        );
        expect(
          bridgeDart.existsSync(),
          isTrue,
          reason: 'Flutter Dart bridge must exist',
        );
      });

      test(
        'clippy-baseline.json enforces strict 1579 budget across workspace packages',
        () {
          final raw = clippyBaseline.readAsStringSync();
          final data = jsonDecode(raw) as Map<String, dynamic>;

          expect(data['schema_version'], equals(1));
          expect(data['total_allowed_warnings'], equals(1579));

          final byPkg = data['by_package'] as Map<String, dynamic>;
          expect(byPkg['camellia-remote'], equals(1103));
          expect(byPkg['scrap'], equals(355));
          expect(byPkg['enigo'], equals(118));
          expect(byPkg['virtual_display'], equals(3));

          var sumPkgs = 0;
          byPkg.forEach((_, val) => sumPkgs += (val as num).toInt());
          expect(sumPkgs, equals(1579));

          final byCode = data['by_lint_code'] as Map<String, dynamic>;
          expect(byCode.length > 20, isTrue);

          var sumCodes = 0;
          byCode.forEach((_, val) => sumCodes += (val as num).toInt());
          expect(sumCodes, equals(1579));
        },
      );

      test(
        'flutter-analyze-baseline.json enforces 896 issues with zero errors or warnings',
        () {
          final raw = flutterBaseline.readAsStringSync();
          final data = jsonDecode(raw) as Map<String, dynamic>;

          expect(data['schema_version'], equals(1));
          expect(data['total_allowed_issues'], equals(896));

          final bySev = data['by_severity'] as Map<String, dynamic>;
          expect(bySev['INFO'], equals(896));
          expect(
            bySev.containsKey('WARNING'),
            isFalse,
            reason: 'Zero warning tolerance',
          );
          expect(
            bySev.containsKey('ERROR'),
            isFalse,
            reason: 'Zero error tolerance',
          );

          final byCode = data['by_lint_code'] as Map<String, dynamic>;
          expect(byCode.length, equals(31));

          var sumCodes = 0;
          byCode.forEach((_, val) => sumCodes += (val as num).toInt());
          expect(sumCodes, equals(896));
        },
      );

      test('build.rs and build.py contain bridge generation guards', () {
        final rsText = buildRs.readAsStringSync();
        expect(rsText.contains('fn ensure_bridge_prerequisites()'), isTrue);
        expect(rsText.contains('src/bridge_generated.rs'), isTrue);
        expect(rsText.contains('BUILD-001 ERROR'), isTrue);

        final pyText = buildPy.readAsStringSync();
        expect(pyText.contains('def ensure_bridge(force=False):'), isTrue);
        expect(pyText.contains('--regenerate-bridge'), isTrue);
      });

      test(
        'ci.yml quality job enforces baseline scripts and eliminates loose threshold',
        () {
          final ciText = ciYml.readAsStringSync();
          expect(
            ciText.contains('verify_quality_baselines.py --clippy'),
            isTrue,
          );
          expect(
            ciText.contains('verify_quality_baselines.py --flutter'),
            isTrue,
          );
          expect(ciText.contains('flutter analyze --no-fatal-infos'), isFalse);
        },
      );

      test(
        'verify_quality_baselines.py is present and contains entrypoints',
        () {
          final scriptText = verifyScript.readAsStringSync();
          expect(scriptText.contains('def verify_clippy'), isTrue);
          expect(scriptText.contains('def verify_flutter'), isTrue);
          expect(scriptText.contains('--clippy'), isTrue);
          expect(scriptText.contains('--flutter'), isTrue);
        },
      );
    },
  );
}
