import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/utils/platform_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Batch 81: PLATFORM-008 Windows Runner bumpMouse Contract Tests', () {
    const MethodChannel hostChannel = MethodChannel('com.camellia.remote/host');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hostChannel, null);
    });

    test('bumpMouse successfully returns true when host method succeeds', () async {
      int? capturedDx;
      int? capturedDy;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hostChannel, (MethodCall call) async {
        if (call.method == 'bumpMouse') {
          final args = call.arguments as Map<dynamic, dynamic>;
          capturedDx = args['dx'] as int?;
          capturedDy = args['dy'] as int?;
          return true;
        }
        return null;
      });

      final result = await RdPlatformChannel.instance.bumpMouse(dx: 15, dy: -25);
      expect(result, isTrue);
      expect(capturedDx, equals(15));
      expect(capturedDy, equals(-25));
    });

    test('bumpMouse returns false when host method returns false', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hostChannel, (MethodCall call) async {
        if (call.method == 'bumpMouse') {
          return false;
        }
        return null;
      });

      final result = await RdPlatformChannel.instance.bumpMouse(dx: 10, dy: 10);
      expect(result, isFalse);
    });

    test('bumpMouse returns false when host method returns null', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hostChannel, (MethodCall call) async {
        if (call.method == 'bumpMouse') {
          return null;
        }
        return null;
      });

      final result = await RdPlatformChannel.instance.bumpMouse(dx: 5, dy: 5);
      expect(result, isFalse);
    });

    test('bumpMouse safely catches PlatformException and returns false', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hostChannel, (MethodCall call) async {
        if (call.method == 'bumpMouse') {
          throw PlatformException(
            code: 'invalid_arguments',
            message: 'bumpMouse requires dx and dy integer parameters',
          );
        }
        return null;
      });

      final result = await RdPlatformChannel.instance.bumpMouse(dx: 0, dy: 0);
      expect(result, isFalse);
    });

    test('bumpMouse safely catches out_of_bounds PlatformException and returns false', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hostChannel, (MethodCall call) async {
        if (call.method == 'bumpMouse') {
          throw PlatformException(
            code: 'out_of_bounds',
            message: 'bumpMouse coordinates delta out of bounds',
          );
        }
        return null;
      });

      final result = await RdPlatformChannel.instance.bumpMouse(dx: 999999, dy: 999999);
      expect(result, isFalse);
    });

    test('bumpMouse handles channel timeout and safely returns false without unhandled exception', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hostChannel, (MethodCall call) async {
        if (call.method == 'bumpMouse') {
          // Simulate hung host handler exceeding the 1000ms timeout
          final Completer<bool> neverEnding = Completer<bool>();
          return neverEnding.future;
        }
        return null;
      });

      final stopwatch = Stopwatch()..start();
      final result = await RdPlatformChannel.instance.bumpMouse(dx: 1, dy: 1);
      stopwatch.stop();

      expect(result, isFalse);
      expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(950));
    });
  });
}
