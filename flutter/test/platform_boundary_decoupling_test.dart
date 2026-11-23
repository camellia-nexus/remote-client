import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop codebase has zero imports from mobile package', () {
    final desktopDir = Directory('lib/desktop');
    expect(desktopDir.existsSync(), isTrue);

    final dartFiles = desktopDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();

    expect(dartFiles, isNotEmpty);

    final violations = <String>[];
    for (final file in dartFiles) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.contains('package:camellia_remote_app/mobile')) {
          violations.add('${file.path}:${i + 1}: $line');
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'Desktop code must not import mobile components. Violations:\n${violations.join('\n')}',
    );
  });

  test('server settings dialog component is hosted in common/widgets', () {
    final sharedDialog = File('lib/common/widgets/server_settings_dialog.dart');
    expect(
      sharedDialog.existsSync(),
      isTrue,
      reason: 'Shared server settings dialog must exist in common/widgets',
    );
  });
}
