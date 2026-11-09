import 'dart:async';
import 'dart:convert';

import 'package:camellia_remote_app/models/input_model.dart';
import 'package:camellia_remote_app/utils/multi_window_manager.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('STATE-029: Cross-Window RPC Timeout & Error Handling', () {
    const MethodChannel eventChannel =
        MethodChannel('mixin.one/flutter_multi_window_channel');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(eventChannel, null);
    });

    test('DesktopMultiWindow.invokeMethod enforces timeout and returns null on hang', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(eventChannel, (MethodCall call) async {
        // Simulate remote window hanging indefinitely
        final completer = Completer<dynamic>();
        return completer.future;
      });

      final result = await DesktopMultiWindow.invokeMethod(
        2,
        'test_hanging_call',
        'ping',
        const Duration(milliseconds: 50),
      );

      expect(result, isNull);
    });

    test('DesktopMultiWindow.invokeMethod returns response when completed before timeout', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(eventChannel, (MethodCall call) async {
        return 'pong';
      });

      final result = await DesktopMultiWindow.invokeMethod(
        2,
        'test_fast_call',
        'ping',
        const Duration(seconds: 1),
      );

      expect(result, equals('pong'));
    });

    test('RustDeskMultiWindowManager.getOtherRemoteWindowCoordsFromMain recovers gracefully on timeout or error', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(eventChannel, (MethodCall call) async {
        throw PlatformException(code: 'rpc_error', message: 'Target window closed');
      });

      final coords = await rustDeskWinManager.getOtherRemoteWindowCoordsFromMain();
      expect(coords, isEmpty);
    });

    test('RustDeskMultiWindowManager.getOtherRemoteWindowCoordsFromMain successfully parses coords payload', () async {
      final canvas = CanvasCoords();
      canvas.x = 10.0;
      canvas.y = 20.0;
      canvas.scale = 1.0;
      canvas.size = const Size(800, 600);

      final cursor = CursorCoords();
      cursor.offset = const Offset(50, 50);

      final sampleCoords = RemoteWindowCoords(
        const Rect.fromLTWH(100, 100, 800, 600),
        canvas,
        cursor,
        const Rect.fromLTWH(0, 0, 1920, 1080),
      );

      final payload = jsonEncode([sampleCoords.toJson()]);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(eventChannel, (MethodCall call) async {
        return payload;
      });

      final coords = await rustDeskWinManager.getOtherRemoteWindowCoordsFromMain();
      expect(coords.length, equals(1));
      expect(coords.first.windowRect.left, equals(100.0));
      expect(coords.first.windowRect.top, equals(100.0));
      expect(coords.first.windowRect.width, equals(800.0));
      expect(coords.first.windowRect.height, equals(600.0));
      expect(coords.first.remoteRect.width, equals(1920.0));
      expect(coords.first.canvas.scale, equals(1.0));
      expect(coords.first.cursor.offset.dx, equals(50.0));
    });
  });

  group('UNSAFE-012 & UNSAFE-013: Contract Sanity & Multi-Window Lifecycle', () {
    test('RemoteWindowCoords serialization and deserialization integrity', () {
      final canvas = CanvasCoords();
      canvas.x = 15.0;
      canvas.y = 25.0;
      canvas.scale = 1.25;
      canvas.size = const Size(1024, 768);

      final cursor = CursorCoords();
      cursor.offset = const Offset(20, 30);

      final original = RemoteWindowCoords(
        const Rect.fromLTWH(50, 60, 1024, 768),
        canvas,
        cursor,
        const Rect.fromLTWH(0, 0, 2560, 1440),
      );

      final json = original.toJson();
      final reconstructed = RemoteWindowCoords.fromJson(json);

      expect(reconstructed.windowRect.left, equals(50.0));
      expect(reconstructed.windowRect.top, equals(60.0));
      expect(reconstructed.windowRect.width, equals(1024.0));
      expect(reconstructed.windowRect.height, equals(768.0));
      expect(reconstructed.remoteRect.width, equals(2560.0));
      expect(reconstructed.remoteRect.height, equals(1440.0));
      expect(reconstructed.canvas.scale, equals(1.25));
      expect(reconstructed.cursor.offset.dx, equals(20.0));
      expect(reconstructed.cursor.offset.dy, equals(30.0));
    });
  });
}
