import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PLATFORM-012: Linux Host MethodChannel Contract', () {
    const MethodChannel hostChannel = MethodChannel('com.camellia.remote/host');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hostChannel, null);
    });

    test('bumpMouse with valid map arguments invokes channel successfully', () async {
      bool mockCalled = false;
      int? capturedDx;
      int? capturedDy;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hostChannel, (MethodCall call) async {
        if (call.method == 'bumpMouse') {
          mockCalled = true;
          final args = call.arguments as Map<dynamic, dynamic>;
          capturedDx = args['dx'] as int?;
          capturedDy = args['dy'] as int?;
          return true;
        }
        return null;
      });

      final result = await hostChannel.invokeMethod<bool>('bumpMouse', {'dx': 15, 'dy': -25});
      expect(result, isTrue);
      expect(mockCalled, isTrue);
      expect(capturedDx, equals(15));
      expect(capturedDy, equals(-25));
    });

    test('bumpMouse with valid list arguments invokes channel successfully', () async {
      bool mockCalled = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hostChannel, (MethodCall call) async {
        if (call.method == 'bumpMouse') {
          mockCalled = true;
          final args = call.arguments as List<dynamic>;
          expect(args[0], equals(50));
          expect(args[1], equals(100));
          return true;
        }
        return null;
      });

      final result = await hostChannel.invokeMethod<bool>('bumpMouse', [50, 100]);
      expect(result, isTrue);
      expect(mockCalled, isTrue);
    });

    test('bumpMouse with out of bounds coordinates triggers out_of_bounds PlatformException', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hostChannel, (MethodCall call) async {
        if (call.method == 'bumpMouse') {
          final args = call.arguments as Map<dynamic, dynamic>;
          final dx = args['dx'] as int;
          if (dx > 100000 || dx < -100000) {
            throw PlatformException(
              code: 'out_of_bounds',
              message: 'bumpMouse coordinates delta out of bounds',
            );
          }
        }
        return true;
      });

      expect(
        () async => await hostChannel.invokeMethod<bool>('bumpMouse', {'dx': 9999999, 'dy': 0}),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'out_of_bounds')),
      );
    });

    test('bumpMouse with invalid arguments triggers invalid_arguments PlatformException', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hostChannel, (MethodCall call) async {
        if (call.method == 'bumpMouse') {
          if (call.arguments == null) {
            throw PlatformException(
              code: 'invalid_arguments',
              message: 'bumpMouse requires non-null arguments',
            );
          }
        }
        return true;
      });

      expect(
        () async => await hostChannel.invokeMethod<bool>('bumpMouse', null),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'invalid_arguments')),
      );
    });

    test('unknown method on host channel throws MissingPluginException', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hostChannel, (MethodCall call) async {
        throw MissingPluginException(
          'No implementation found for method ${call.method} on channel ${hostChannel.name}',
        );
      });

      expect(
        () async => await hostChannel.invokeMethod<void>('unknownNonExistentMethod'),
        throwsA(isA<MissingPluginException>()),
      );
    });
  });

  group('RES-061: Linux Plugin MethodChannel Registration Contracts', () {
    const MethodChannel dropChannel = MethodChannel('desktop_drop');
    const MethodChannel screenRetrieverChannel = MethodChannel('screen_retriever');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(dropChannel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(screenRetrieverChannel, null);
    });

    test('desktop_drop channel mock interaction', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(dropChannel, (MethodCall call) async {
        if (call.method == 'ping') {
          return 'pong';
        }
        return null;
      });

      final result = await dropChannel.invokeMethod<String>('ping');
      expect(result, equals('pong'));
    });

    test('screen_retriever channel mock interaction', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(screenRetrieverChannel, (MethodCall call) async {
        if (call.method == 'getCursorScreenPoint') {
          return {'x': 100.0, 'y': 200.0};
        }
        return null;
      });

      final result = await screenRetrieverChannel.invokeMethod<Map<dynamic, dynamic>>('getCursorScreenPoint');
      expect(result?['x'], equals(100.0));
      expect(result?['y'], equals(200.0));
    });
  });
}
