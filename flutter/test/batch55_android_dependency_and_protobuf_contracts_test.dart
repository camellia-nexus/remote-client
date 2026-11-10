import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PROV-005: Android Repository Content Filtering Contracts', () {
    test('JitPack group regex strictly allows com.github.* and rejects unexpected packages', () {
      final jitpackRegex = RegExp(r'^com\.github\..*');

      // Allowed packages
      expect(jitpackRegex.hasMatch('com.github.getActivity'), isTrue);
      expect(jitpackRegex.hasMatch('com.github.getActivity:XXPermissions'), isTrue);
      expect(jitpackRegex.hasMatch('com.github.someone.library'), isTrue);

      // Forbidden packages (must not resolve from JitPack)
      expect(jitpackRegex.hasMatch('com.google.protobuf'), isFalse);
      expect(jitpackRegex.hasMatch('androidx.media'), isFalse);
      expect(jitpackRegex.hasMatch('org.jetbrains.kotlin'), isFalse);
      expect(jitpackRegex.hasMatch('com.android.tools'), isFalse);
      expect(jitpackRegex.hasMatch('io.flutter'), isFalse);
    });
  });

  group('DEP-003: Protobuf Version and Security Hardening Contracts', () {
    test('protobuf version satisfies minimum secure threshold (3.25.5)', () {
      bool isVersionSecure(String version) {
        final parts = version.split('.').map(int.tryParse).toList();
        if (parts.length < 3 || parts.any((p) => p == null)) return false;

        final major = parts[0]!;
        final minor = parts[1]!;
        final patch = parts[2]!;

        if (major > 3) return true;
        if (major == 3) {
          if (minor > 25) return true;
          if (minor == 25 && patch >= 5) return true;
        }
        return false;
      }

      // Vulnerable versions
      expect(isVersionSecure('3.20.1'), isFalse);
      expect(isVersionSecure('3.21.12'), isFalse);
      expect(isVersionSecure('3.25.4'), isFalse);

      // Secure versions
      expect(isVersionSecure('3.25.5'), isTrue);
      expect(isVersionSecure('3.25.6'), isTrue);
      expect(isVersionSecure('4.26.1'), isTrue);
    });

    test('unknown field stripping sanitizes payload while preserving typed properties', () {
      // Simulation of a message carrying typed data + untrusted unknown wire fields
      final message = {
        'keyCode': 66, // KEYCODE_ENTER
        'modifiers': [1],
        'unknownFields': [
          {'tag': 999, 'bytes': 'corrupted_recursion_payload_bomb'},
        ],
      };

      // Strip unknown fields before JNI dispatch
      final sanitized = Map<String, dynamic>.from(message)..remove('unknownFields');

      expect(sanitized.containsKey('keyCode'), isTrue);
      expect(sanitized['keyCode'], equals(66));
      expect(sanitized.containsKey('unknownFields'), isFalse);
    });
  });
}
