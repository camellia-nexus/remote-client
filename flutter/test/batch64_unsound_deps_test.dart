import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DEP-001: Unsound Dependencies Remediation Contracts (Batch 64)', () {
    late Directory clientRoot;
    late File cargoLock;
    late File cargoToml;
    late File auditPolicy;
    late File riskRegister;

    setUpAll(() {
      if (Directory.current.path.endsWith('flutter')) {
        clientRoot = Directory.current.parent;
      } else {
        clientRoot = Directory.current;
      }

      cargoLock = File('${clientRoot.path}/Cargo.lock');
      cargoToml = File('${clientRoot.path}/Cargo.toml');
      auditPolicy = File('${clientRoot.path}/.github/config/cargo-audit-policy.json');
      riskRegister = File('${clientRoot.path}/docs/dependency-risk-register.md');

      expect(cargoLock.existsSync(), isTrue, reason: 'Cargo.lock must exist');
      expect(cargoToml.existsSync(), isTrue, reason: 'Cargo.toml must exist');
      expect(auditPolicy.existsSync(), isTrue, reason: 'cargo-audit-policy.json must exist');
      expect(riskRegister.existsSync(), isTrue, reason: 'dependency-risk-register.md must exist');
    });

    test('Cargo.lock purges atty, ansi_term, and obsolete bindgen 0.59', () {
      final content = cargoLock.readAsStringSync();

      expect(
        content.contains('name = "atty"'),
        isFalse,
        reason: 'atty package must be completely removed from Cargo.lock',
      );

      expect(
        content.contains('name = "ansi_term"'),
        isFalse,
        reason: 'ansi_term package must be removed from Cargo.lock',
      );

      final blocks = content.split('[[package]]');
      for (final block in blocks) {
        if (block.contains('name = "bindgen"') && block.contains('0.59.')) {
          fail('Cargo.lock must not contain obsolete bindgen 0.59.x: $block');
        }
      }
    });

    test('Cargo.lock patches glib 0.18.5 in-tree without crates.io registry source', () {
      final content = cargoLock.readAsStringSync();
      final blocks = content.split('[[package]]');

      var foundGlib018 = false;
      for (final block in blocks) {
        if (block.contains('name = "glib"') && block.contains('version = "0.18.5"')) {
          foundGlib018 = true;
          expect(
            block.contains('source = "registry+https://github.com/rust-lang/crates.io-index"'),
            isFalse,
            reason: 'glib 0.18.5 must not be sourced from crates.io registry',
          );
        }
      }

      expect(foundGlib018, isTrue, reason: 'glib 0.18.5 must be present in Cargo.lock');
    });

    test('Cargo.toml configures patch tables and workspace exclusions', () {
      final content = cargoToml.readAsStringSync();

      expect(content.contains('"libs/glib"'), isTrue);
      expect(content.contains('"libs/magnum-opus"'), isTrue);
      expect(content.contains('"libs/hwcodec"'), isTrue);

      expect(content.contains('[patch.crates-io]'), isTrue);
      expect(content.contains('glib = { path = "libs/glib" }'), isTrue);
      expect(content.contains('[patch."https://github.com/rustdesk-org/magnum-opus"]'), isTrue);
      expect(content.contains('[patch."https://github.com/rustdesk-org/hwcodec"]'), isTrue);
    });

    test('cargo-audit-policy.json has zero unsound exceptions and valid deadlines', () {
      final raw = auditPolicy.readAsStringSync();
      final policy = jsonDecode(raw) as Map<String, dynamic>;

      expect(policy['schema_version'], equals(1));
      final reviewedOn = policy['reviewed_on'] as String;
      expect(reviewedOn.compareTo('2026-11-11') >= 0, isTrue);

      final exceptionGroups = policy['exception_groups'] as List<dynamic>;
      for (final group in exceptionGroups) {
        final g = group as Map<String, dynamic>;
        final groupId = g['id'] as String;
        final expiresOn = g['expires_on'] as String;
        expect(
          expiresOn.compareTo(reviewedOn) > 0,
          isTrue,
          reason: 'expires_on must be after reviewed_on in group $groupId',
        );

        final warnings = g['warnings'] as List<dynamic>;
        for (final warn in warnings) {
          final w = warn as Map<String, dynamic>;
          final category = w['category'] as String?;
          expect(
            category,
            isNot(equals('unsound')),
            reason: 'Zero unsound categories permitted in group $groupId',
          );

          final pkg = w['package'] as String?;
          expect(pkg, isNot(equals('atty')), reason: 'atty must not be in policy');
          expect(pkg, isNot(equals('ansi_term')), reason: 'ansi_term must not be in policy');

          final advisoryId = w['advisory_id'] as String?;
          expect(advisoryId, isNot(equals('RUSTSEC-2024-0429')));
          expect(advisoryId, isNot(equals('RUSTSEC-2021-0145')));
          expect(advisoryId, isNot(equals('RUSTSEC-2024-0375')));
        }
      }
    });

    test('docs/dependency-risk-register.md documents DEP-001 remediation', () {
      final content = riskRegister.readAsStringSync();
      expect(content.contains('Review date: 2026-11-11'), isTrue);
      expect(content.contains('DEP-001'), isTrue);
      expect(content.contains('RUSTSEC-2024-0429'), isTrue);
      expect(content.contains('RUSTSEC-2021-0145'), isTrue);
    });

    test('In-tree vendored patches satisfy security invariants', () {
      final glibVariantIter = File('${clientRoot.path}/libs/glib/src/variant_iter.rs');
      expect(glibVariantIter.existsSync(), isTrue);
      final glibContent = glibVariantIter.readAsStringSync();
      expect(
        glibContent.contains('let mut p: *mut libc::c_char = std::ptr::null_mut();'),
        isTrue,
      );
      expect(glibContent.contains('&mut p'), isTrue);

      for (final codec in ['magnum-opus', 'hwcodec']) {
        final codecToml = File('${clientRoot.path}/libs/$codec/Cargo.toml');
        expect(codecToml.existsSync(), isTrue);
        final tomlContent = codecToml.readAsStringSync();
        expect(tomlContent.contains('bindgen = "0.71"'), isTrue);
        expect(tomlContent.contains('0.59'), isFalse);
      }
    });
  });
}
