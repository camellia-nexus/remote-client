import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/login.dart';
import 'package:camellia_remote_app/models/state_model.dart';
import 'package:camellia_remote_app/web/bridge.dart';
import 'package:camellia_remote_app/web/js_interop_bridge.dart' as js;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:uuid/uuid.dart';
import 'package:web/web.dart' as web;

typedef _DomListener = ({String type, web.EventListener callback});

final List<_DomListener> mouseListeners = [];
final List<_DomListener> keyListeners = [];
const String _buildApiServer = String.fromEnvironment(
  'API_SERVER',
  defaultValue: '',
);
const String _buildRendezvousServers = String.fromEnvironment(
  'RENDEZVOUS_SERVERS',
  defaultValue: '',
);
const String _buildRsPubKey = String.fromEnvironment(
  'RS_PUB_KEY',
  defaultValue: '',
);
const String _buildAppVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: '',
);
const String _buildBuildDate = String.fromEnvironment(
  'BUILD_DATE',
  defaultValue: '',
);

typedef HandleEvent = Future<void> Function(Map<String, dynamic> evt);

class PlatformFFI {
  final _eventHandlers = <String, Map<String, HandleEvent>>{};
  final RustdeskImpl _ffiBind = RustdeskImpl();
  final _terminalUtf8Carry = <int, List<int>>{};
  final _terminalUtf16Mode = <int>{};
  final _terminalUtf16Carry = <int, int>{};

  static String getByName(String name, [String arg = '']) {
    return js.context.callMethod('getByName', [name, arg]) as String;
  }

  static void setByName(String name, [String value = '']) {
    js.context.callMethod('setByName', [name, value]);
  }

  PlatformFFI._() {
    final visibilityListener = ((web.Event _) {
      stateGlobal.isWebVisible = !web.document.hidden;
    }).toJS;
    web.document.addEventListener('visibilitychange', visibilityListener);
  }

  static final PlatformFFI instance = PlatformFFI._();

  static String get localeName => web.window.navigator.language;
  RustdeskImpl get ffiBind => _ffiBind;

  static Future<String> getVersion() async {
    final info = await PackageInfo.fromPlatform();
    return info.version;
  }

  bool registerEventHandler(
    String eventName,
    String handlerName,
    HandleEvent handler, {
    bool replace = false,
  }) {
    debugPrint('registerEventHandler $eventName $handlerName');
    var handlers = _eventHandlers[eventName];
    if (handlers == null) {
      _eventHandlers[eventName] = {handlerName: handler};
      return true;
    } else {
      if (!replace && handlers.containsKey(handlerName)) {
        return false;
      } else {
        handlers[handlerName] = handler;
        return true;
      }
    }
  }

  void unregisterEventHandler(String eventName, String handlerName) {
    debugPrint('unregisterEventHandler $eventName $handlerName');
    var handlers = _eventHandlers[eventName];
    if (handlers != null) {
      handlers.remove(handlerName);
    }
  }

  void removeEventHandler(String eventName, [String? handlerName]) {
    unregisterEventHandler(eventName, handlerName ?? eventName);
  }

  Future<bool> tryHandle(Map<String, dynamic> evt) async {
    final name = evt['name'];
    if (name != null) {
      if (name == 'terminal_response') {
        _normalizeTerminalEvent(evt);
      }
      final handlers = _eventHandlers[name];
      if (handlers != null) {
        if (handlers.isNotEmpty) {
          for (var handler in handlers.values) {
            await handler(evt);
          }
          return true;
        }
      }
    }
    return false;
  }

  void _normalizeTerminalEvent(Map<String, dynamic> evt) {
    final type = (evt['type'] ?? '').toString();
    final terminalId = _parseTerminalId(evt['terminal_id']);

    if (terminalId != null && (type == 'opened' || type == 'closed')) {
      _terminalUtf8Carry.remove(terminalId);
      _terminalUtf16Mode.remove(terminalId);
      _terminalUtf16Carry.remove(terminalId);
    }

    if (type != 'data') {
      return;
    }

    if (terminalId == null) {
      return;
    }

    final payload = evt['data'];
    Uint8List? bytes;

    if (payload is String) {
      try {
        bytes = base64Decode(payload);
      } catch (_) {
        // Already plain text from another bridge path.
        return;
      }
    } else if (payload is List) {
      final values = <int>[];
      for (final item in payload) {
        if (item is num) {
          values.add(item.toInt());
        } else {
          return;
        }
      }
      bytes = Uint8List.fromList(values);
    }

    if (bytes == null || bytes.isEmpty) {
      return;
    }

    final text = _decodeTerminalChunk(terminalId, bytes);
    if (text.isEmpty) {
      return;
    }
    final normalizedText = _normalizeAnsiForWeb(text);
    if (normalizedText.isEmpty) {
      return;
    }
    // Keep web-only decoded terminal chunks away from the generic base64 branch
    // in TerminalModel by passing bytes directly.
    evt['data'] = utf8.encode(normalizedText);
  }

  int? _parseTerminalId(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is String) {
      return int.tryParse(value);
    }
    return null;
  }

  String _decodeTerminalChunk(int terminalId, Uint8List bytes) {
    if (_terminalUtf16Mode.contains(terminalId) || _hasUtf16LeBom(bytes)) {
      _terminalUtf16Mode.add(terminalId);
      _terminalUtf8Carry.remove(terminalId);
      if (_hasUtf16LeBom(bytes)) {
        if (bytes.length <= 2) {
          return '';
        }
        bytes = Uint8List.sublistView(bytes, 2);
      }
      return _decodeUtf16LeChunk(terminalId, bytes);
    }
    _terminalUtf16Carry.remove(terminalId);
    final utf8Text = _decodeUtf8Chunk(terminalId, bytes);
    if (_looksLikeUtf16LeWithoutBom(utf8Text, bytes)) {
      _terminalUtf16Mode.add(terminalId);
      _terminalUtf8Carry.remove(terminalId);
      return _decodeUtf16LeChunk(terminalId, bytes);
    }
    return utf8Text;
  }

  String _decodeUtf16LeChunk(int terminalId, Uint8List bytes) {
    final pending = _terminalUtf16Carry.remove(terminalId);
    late Uint8List merged;
    if (pending != null) {
      merged = Uint8List(bytes.length + 1);
      merged[0] = pending;
      merged.setRange(1, merged.length, bytes);
    } else {
      merged = bytes;
    }

    if (merged.isEmpty) {
      return '';
    }

    if (merged.length.isOdd) {
      _terminalUtf16Carry[terminalId] = merged.last;
      merged = Uint8List.sublistView(merged, 0, merged.length - 1);
    }

    if (merged.isEmpty) {
      return '';
    }

    final byteData = ByteData.sublistView(merged);
    final length = merged.length ~/ 2;
    final codeUnits = Uint16List(length);
    for (var i = 0; i < length; i++) {
      codeUnits[i] = byteData.getUint16(i * 2, Endian.little);
    }

    var start = 0;
    if (codeUnits.isNotEmpty && codeUnits.first == 0xFEFF) {
      start = 1;
    }
    return String.fromCharCodes(codeUnits, start);
  }

  String _decodeUtf8Chunk(int terminalId, Uint8List bytes) {
    final carry = _terminalUtf8Carry[terminalId];
    late Uint8List merged;
    if (carry != null && carry.isNotEmpty) {
      merged = Uint8List(carry.length + bytes.length);
      merged.setRange(0, carry.length, carry);
      merged.setRange(carry.length, merged.length, bytes);
    } else {
      merged = bytes;
    }

    if (merged.isEmpty) {
      return '';
    }

    final carryLength = _detectUtf8IncompleteTail(merged);
    if (carryLength > 0) {
      _terminalUtf8Carry[terminalId] = merged.sublist(
        merged.length - carryLength,
      );
      merged = Uint8List.sublistView(merged, 0, merged.length - carryLength);
    } else {
      _terminalUtf8Carry.remove(terminalId);
    }

    if (merged.isEmpty) {
      return '';
    }

    return utf8.decode(merged, allowMalformed: true);
  }

  int _detectUtf8IncompleteTail(Uint8List bytes) {
    if (bytes.isEmpty) {
      return 0;
    }

    var index = bytes.length - 1;
    var continuationCount = 0;

    while (index >= 0 && (bytes[index] & 0xC0) == 0x80) {
      continuationCount += 1;
      index -= 1;
    }

    if (index < 0) {
      return continuationCount.clamp(0, 3);
    }

    final head = bytes[index];
    int expectedLength = 0;
    if ((head & 0x80) == 0x00) {
      expectedLength = 1;
    } else if ((head & 0xE0) == 0xC0) {
      expectedLength = 2;
    } else if ((head & 0xF0) == 0xE0) {
      expectedLength = 3;
    } else if ((head & 0xF8) == 0xF0) {
      expectedLength = 4;
    }

    if (expectedLength == 0) {
      return 0;
    }

    if (expectedLength == 1) {
      return 0;
    }

    if (continuationCount == 0) {
      return 1;
    }

    final availableLength = continuationCount + 1;
    if (expectedLength > 1 && availableLength < expectedLength) {
      return availableLength;
    }
    return 0;
  }

  bool _hasUtf16LeBom(Uint8List bytes) {
    return bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE;
  }

  bool _looksLikeUtf16LeWithoutBom(String decodedUtf8, Uint8List bytes) {
    if (bytes.length < 8) {
      return false;
    }

    var nulCount = 0;
    for (final codeUnit in decodedUtf8.codeUnits) {
      if (codeUnit == 0) {
        nulCount += 1;
      }
    }
    if (nulCount * 100 < decodedUtf8.length * 20) {
      return false;
    }

    final pairCount = bytes.length ~/ 2;
    if (pairCount == 0) {
      return false;
    }

    var oddZeroCount = 0;
    var evenPrintableCount = 0;
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      final lo = bytes[i];
      final hi = bytes[i + 1];
      if (hi == 0) {
        oddZeroCount += 1;
      }
      if ((lo >= 0x20 && lo <= 0x7E) ||
          lo == 0x09 ||
          lo == 0x0A ||
          lo == 0x0D ||
          lo == 0x1B) {
        evenPrintableCount += 1;
      }
    }

    return oddZeroCount * 100 >= pairCount * 65 &&
        evenPrintableCount * 100 >= pairCount * 65;
  }

  String _normalizeAnsiForWeb(String text) {
    // Remove "faint" style that becomes nearly unreadable in some browsers.
    return text.replaceAll('\u001B[2m', '');
  }

  String translate(String name, String locale) =>
      _ffiBind.translate(name: name, locale: locale);

  Uint8List? getRgba(SessionID sessionId, int display, int bufSize) {
    throw UnimplementedError();
  }

  int getRgbaSize(SessionID sessionId, int display) =>
      _ffiBind.sessionGetRgbaSize(sessionId: sessionId, display: display);
  void nextRgba(SessionID sessionId, int display) =>
      _ffiBind.sessionNextRgba(sessionId: sessionId, display: display);
  void registerPixelbufferTexture(SessionID sessionId, int display, int ptr) =>
      _ffiBind.sessionRegisterPixelbufferTexture(
        sessionId: sessionId,
        display: display,
        ptr: ptr,
      );
  void registerGpuTexture(SessionID sessionId, int display, int ptr) =>
      _ffiBind.sessionRegisterGpuTexture(
        sessionId: sessionId,
        display: display,
        ptr: ptr,
      );

  Future<void> init(String appType) async {
    final completer = Completer<void>();
    await _applyBuildBootstrapConfig();
    js.context["onInitFinished"] = (() {
      completer.complete();
    }).toJS;
    js.context['dialog'] = ((JSAny? type, JSAny? title, JSAny? text) {
      final uuid = Uuid();
      msgBox(
        SessionID(uuid.v4()),
        (type?.dartify() ?? '').toString(),
        (title?.dartify() ?? '').toString(),
        (text?.dartify() ?? '').toString(),
        '',
        gFFI.dialogManager,
      );
    }).toJS;
    js.context['loginDialog'] = (() {
      loginDialog();
    }).toJS;
    js.context['closeConnection'] = (() {
      gFFI.dialogManager.dismissAll();
      closeConnection();
    }).toJS;
    js.context.callMethod('init');
    version = getByName('version');
    final contextMenuListener = ((web.Event event) {
      event.preventDefault();
    }).toJS;
    web.document.addEventListener('contextmenu', contextMenuListener);
    mouseListeners.add((type: 'contextmenu', callback: contextMenuListener));

    js.context['onRegisteredEvent'] = ((JSAny? message) {
      final raw = (message?.dartify() ?? '').toString();
      try {
        final event = json.decode(raw) as Map<String, dynamic>;
        tryHandle(event);
      } catch (e) {
        debugPrint('json.decode fail(): $e');
      }
    }).toJS;
    return completer.future;
  }

  Future<void> _applyBuildBootstrapConfig() async {
    final apiServer = _buildApiServer.trim();
    final rsPubKey = _buildRsPubKey.trim();
    var appVersion = _buildAppVersion.trim();
    if (appVersion.isEmpty) {
      try {
        appVersion = (await PackageInfo.fromPlatform()).version.trim();
      } catch (_) {
        // Keep default fallback below.
      }
    }
    if (appVersion.isEmpty) {
      appVersion = 'web';
    }
    final buildDate = _buildBuildDate.trim();
    final rendezvousServers = _buildRendezvousServers
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);

    if (apiServer.isEmpty &&
        rsPubKey.isEmpty &&
        rendezvousServers.isEmpty &&
        appVersion.isEmpty &&
        buildDate.isEmpty) {
      return;
    }

    final payload = <String, dynamic>{
      if (apiServer.isNotEmpty) 'apiServer': apiServer,
      if (rsPubKey.isNotEmpty) 'rsPubKey': rsPubKey,
      if (appVersion.isNotEmpty) 'version': appVersion,
      if (buildDate.isNotEmpty) 'buildDate': buildDate,
      if (rendezvousServers.isNotEmpty) 'rendezvousServers': rendezvousServers,
      'env': {
        if (apiServer.isNotEmpty) 'API_SERVER': apiServer,
        if (rsPubKey.isNotEmpty) 'RS_PUB_KEY': rsPubKey,
        if (appVersion.isNotEmpty) 'APP_VERSION': appVersion,
        if (rendezvousServers.isNotEmpty)
          'RENDEZVOUS_SERVERS': rendezvousServers.join(','),
      },
    };

    js.context.callMethod('setByName', [
      'bootstrap_config',
      jsonEncode(payload),
    ]);
  }

  void setEventCallback(void Function(Map<String, dynamic>) fun) {
    js.context["onGlobalEvent"] = ((JSAny? message) {
      final raw = (message?.dartify() ?? '').toString();
      try {
        final event = json.decode(raw) as Map<String, dynamic>;
        if (event['name'] == 'terminal_response') {
          _normalizeTerminalEvent(event);
        }
        fun(event);
      } catch (e) {
        debugPrint('json.decode fail(): $e');
      }
    }).toJS;
  }

  void setRgbaCallback(void Function(int, Uint8List, int, int) fun) {
    js.context["onRgba"] =
        ((JSAny? display, JSAny? rgba, JSAny? width, JSAny? height) {
          final displayNumber = (display?.dartify() as num?)?.toInt() ?? 0;
          final rgbaData = rgba?.dartify();
          if (rgbaData is Uint8List) {
            final frameWidth = (width?.dartify() as num?)?.toInt() ?? 0;
            final frameHeight = (height?.dartify() as num?)?.toInt() ?? 0;
            fun(displayNumber, rgbaData, frameWidth, frameHeight);
          }
        }).toJS;
  }

  void setVideoFrameCallback(void Function(int, int, int) fun) {
    js.context["onVideoFrame"] =
        ((JSAny? display, JSAny? width, JSAny? height) {
          final displayNumber = (display?.dartify() as num?)?.toInt() ?? 0;
          final frameWidth = (width?.dartify() as num?)?.toInt() ?? 0;
          final frameHeight = (height?.dartify() as num?)?.toInt() ?? 0;
          fun(displayNumber, frameWidth, frameHeight);
        }).toJS;
  }

  void clearVideoFrameCallback() {
    js.context["onVideoFrame"] = null;
  }

  void startDesktopWebListener() {
    final contextMenuListener = ((web.Event evt) {
      evt.preventDefault();
    }).toJS;
    web.document.addEventListener('contextmenu', contextMenuListener);
    mouseListeners.add((type: 'contextmenu', callback: contextMenuListener));
  }

  void stopDesktopWebListener() {
    for (final listener in mouseListeners) {
      web.document.removeEventListener(listener.type, listener.callback);
    }
    mouseListeners.clear();
    for (final listener in keyListeners) {
      web.document.removeEventListener(listener.type, listener.callback);
    }
    keyListeners.clear();
  }

  void setMethodCallHandler(FMethod callback) {}

  invokeMethod(String method, [dynamic arguments]) async {
    return true;
  }

  // just for compilation
  void syncAndroidServiceAppDirConfigPath() {}

  void setFullscreenCallback(void Function(bool) fun) {
    js.context["onFullscreenChanged"] = ((JSAny? v) {
      fun(v?.dartify() == true);
    }).toJS;
  }
}
