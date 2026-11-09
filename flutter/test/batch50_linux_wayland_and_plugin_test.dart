import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/utils/platform_channel.dart';
import 'package:window_manager/src/utils/calc_window_position.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PLATFORM-014: Linux Wayland Shortcuts Inhibitor Channel Contract', () {
    const MethodChannel hostChannel = MethodChannel('com.camellia.remote/host');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hostChannel, null);
    });

    test('setWaylandShortcutsInhibit with enabled=true receives success and active state', () async {
      bool mockCalled = false;
      bool? capturedEnabled;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hostChannel, (MethodCall call) async {
        if (call.method == 'setWaylandShortcutsInhibit') {
          mockCalled = true;
          final args = call.arguments as Map<dynamic, dynamic>;
          capturedEnabled = args['enabled'] as bool?;
          return {
            'success': true,
            'state': 'active',
          };
        }
        return null;
      });

      final result = await RdPlatformChannel.instance.setWaylandShortcutsInhibit(enabled: true);
      expect(result, isTrue);
      expect(mockCalled, isTrue);
      expect(capturedEnabled, isTrue);
    });

    test('setWaylandShortcutsInhibit with enabled=false receives success and disabled state', () async {
      bool mockCalled = false;
      bool? capturedEnabled;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hostChannel, (MethodCall call) async {
        if (call.method == 'setWaylandShortcutsInhibit') {
          mockCalled = true;
          final args = call.arguments as Map<dynamic, dynamic>;
          capturedEnabled = args['enabled'] as bool?;
          return {
            'success': true,
            'state': 'disabled',
          };
        }
        return null;
      });

      final result = await RdPlatformChannel.instance.setWaylandShortcutsInhibit(enabled: false);
      expect(result, isTrue);
      expect(mockCalled, isTrue);
      expect(capturedEnabled, isFalse);
    });

    test('getWaylandShortcutsInhibitState returns current state string', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hostChannel, (MethodCall call) async {
        if (call.method == 'getWaylandShortcutsInhibitState') {
          return {
            'supported': true,
            'state': 'active',
          };
        }
        return null;
      });

      final state = await RdPlatformChannel.instance.getWaylandShortcutsInhibitState();
      expect(state, equals('active'));
    });

    test('setWaylandShortcutsInhibit fail-closed handles platform channel exceptions safely', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hostChannel, (MethodCall call) async {
        if (call.method == 'setWaylandShortcutsInhibit') {
          throw PlatformException(code: 'unsupported', message: 'Wayland protocol not supported');
        }
        return null;
      });

      final result = await RdPlatformChannel.instance.setWaylandShortcutsInhibit(enabled: true);
      expect(result, isFalse);
    });
  });

  group('PLATFORM-015: Linux Screen Retriever & Calc Window Position Fallbacks', () {
    const MethodChannel screenRetrieverChannel = MethodChannel('screen_retriever');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(screenRetrieverChannel, null);
    });

    test('calcWindowPosition falls back to 1920x1080 default when screenRetriever fails', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(screenRetrieverChannel, (MethodCall call) async {
        throw PlatformException(code: 'unavailable', message: 'No displays found');
      });

      // Window size 800x600 centered on fallback 1920x1080 display:
      // X: (1920/2) - (800/2) = 960 - 400 = 560
      // Y: (1080/2) - (600/2) = 540 - 300 = 240
      final pos = await calcWindowPosition(const Size(800, 600), Alignment.center);
      expect(pos.dx, equals(560.0));
      expect(pos.dy, equals(240.0));
    });

    test('calcWindowPosition handles Alignment.topLeft with fallback display', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(screenRetrieverChannel, (MethodCall call) async {
        throw PlatformException(code: 'unavailable', message: 'No displays found');
      });

      final pos = await calcWindowPosition(const Size(800, 600), Alignment.topLeft);
      expect(pos.dx, equals(0.0));
      expect(pos.dy, equals(0.0));
    });

    test('calcWindowPosition handles Alignment.topRight with fallback display', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(screenRetrieverChannel, (MethodCall call) async {
        throw PlatformException(code: 'unavailable', message: 'No displays found');
      });

      // visibleWidth (1920) - windowWidth (800) = 1120
      final pos = await calcWindowPosition(const Size(800, 600), Alignment.topRight);
      expect(pos.dx, equals(1120.0));
      expect(pos.dy, equals(0.0));
    });
  });
}
