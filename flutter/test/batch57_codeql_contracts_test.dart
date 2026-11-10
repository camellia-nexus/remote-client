import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BUILD-015: Advanced Multi-Language CodeQL Matrix & SARIF Contracts', () {
    late File codeqlFile;
    late String codeqlContent;
    late File configFile;
    late String configContent;

    setUpAll(() {
      final repoRoot = Directory.current.parent;
      codeqlFile = File('${repoRoot.path}/.github/workflows/codeql.yml');
      configFile = File('${repoRoot.path}/.github/codeql/codeql-config.yml');

      expect(codeqlFile.existsSync(), isTrue, reason: 'codeql.yml must exist');
      expect(configFile.existsSync(), isTrue, reason: 'codeql-config.yml must exist');

      codeqlContent = codeqlFile.readAsStringSync();
      configContent = configFile.readAsStringSync();
    });

    test('BUILD-015: CodeQL matrix includes all 7 mandatory language targets', () {
      final mandatoryLanguages = [
        'actions',
        'c-cpp',
        'java-kotlin',
        'javascript-typescript',
        'python',
        'rust',
        'swift',
      ];

      for (final lang in mandatoryLanguages) {
        expect(
          codeqlContent.contains('language: $lang'),
          isTrue,
          reason: 'CodeQL matrix missing mandatory language: $lang',
        );
      }
    });

    test('BUILD-015: CodeQL covers Android Java/Kotlin native glue', () {
      expect(
        codeqlContent.contains('language: java-kotlin'),
        isTrue,
        reason: 'java-kotlin must be present in CodeQL matrix',
      );

      final androidDir = Directory('${Directory.current.path}/android/app/src/main/kotlin');
      expect(androidDir.existsSync(), isTrue);
      final kotlinFiles = androidDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.kt'))
          .toList();

      expect(kotlinFiles.length, greaterThanOrEqualTo(5), reason: 'Expected multiple Kotlin files');
    });

    test('BUILD-015: CodeQL covers Apple Swift native glue on macOS runner', () {
      expect(
        codeqlContent.contains('language: swift'),
        isTrue,
        reason: 'swift must be present in CodeQL matrix',
      );
      expect(
        codeqlContent.contains('os: macos-15'),
        isTrue,
        reason: 'swift must run on macos-15 runner',
      );

      expect(
        codeqlContent.contains('camellia_remote_core_main'),
        isTrue,
        reason: 'codeql.yml must mock camellia_remote_core_main',
      );
      expect(
        codeqlContent.contains('handle_applicationShouldOpenUntitledFile'),
        isTrue,
        reason: 'codeql.yml must mock handle_applicationShouldOpenUntitledFile',
      );

      final macosDir = Directory('${Directory.current.path}/macos/Runner');
      expect(macosDir.existsSync(), isTrue);
      final swiftFiles = macosDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.swift'))
          .toList();

      expect(swiftFiles.length, greaterThanOrEqualTo(2), reason: 'Expected macOS Swift runner files');
    });

    test('BUILD-015: CodeQL covers C/C++ native desktop glue', () {
      expect(
        codeqlContent.contains('language: c-cpp'),
        isTrue,
        reason: 'c-cpp must be present in CodeQL matrix',
      );

      final linuxDir = Directory('${Directory.current.path}/linux');
      expect(linuxDir.existsSync(), isTrue);
      final cppFiles = linuxDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.cc') || f.path.endsWith('.h'))
          .toList();

      expect(cppFiles.length, greaterThanOrEqualTo(5), reason: 'Expected Linux C++ files');
    });

    test('BUILD-015: CodeQL publishes SARIF with language category and minimal permissions', () {
      expect(
        codeqlContent.contains('category: "/language:\${{ matrix.language }}"'),
        isTrue,
        reason: 'SARIF category must be specified',
      );
      expect(
        codeqlContent.contains('security-events: write'),
        isTrue,
        reason: 'Must declare security-events: write',
      );
      expect(
        codeqlContent.contains('contents: read'),
        isTrue,
        reason: 'Must declare contents: read',
      );
    });

    test('BUILD-015: codeql-config.yml ignores generated bridge files to prevent false alarms', () {
      expect(configContent.contains('bridge_generated'), isTrue);
      expect(configContent.contains('generated_bridge'), isTrue);
      expect(configContent.contains('paths-ignore'), isTrue);
      expect(configContent.contains('paths'), isTrue);
    });
  });
}
