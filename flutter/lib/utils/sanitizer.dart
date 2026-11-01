import 'dart:async';
import 'package:flutter/foundation.dart';

class LogSanitizer {
  static final RegExp _credentialJsonPattern = RegExp(
    r'("?(?:password|connToken|token|access_token|refresh_token|secret|address_book_password|pin)"?\s*[:=]\s*"?)([^",\s\}&]+)("?)',
    caseSensitive: false,
  );

  static final RegExp _uriCredentialPattern = RegExp(
    r'((?:password|token|secret|key)=)([^&\s]+)',
    caseSensitive: false,
  );

  static final RegExp _deepLinkPasswordPattern = RegExp(
    r'(camellia-remote://password/)([^/?\s]+)',
    caseSensitive: false,
  );

  static final RegExp _userPathPattern = RegExp(
    r'(/home/[^/\s]+|C:\\Users\\[^\\/\s]+)',
    caseSensitive: false,
  );

  static String sanitize(String message) {
    var s = message;
    s = s.replaceAllMapped(_credentialJsonPattern, (m) => '${m[1]}[REDACTED]${m[3]}');
    s = s.replaceAllMapped(_uriCredentialPattern, (m) => '${m[1]}[REDACTED]');
    s = s.replaceAllMapped(_deepLinkPasswordPattern, (m) => '${m[1]}[REDACTED]');
    s = s.replaceAllMapped(_userPathPattern, (m) => '[USER_HOME]');
    return s;
  }

  static ZoneSpecification zoneSpecification() {
    return ZoneSpecification(
      print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
        parent.print(zone, sanitize(line));
      },
    );
  }

  static void install() {
    final originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message == null) return;
      originalDebugPrint(sanitize(message), wrapWidth: wrapWidth);
    };
  }
}

