import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

/// Helper to simulate desktop mouse pointer hover, leave, and drag gestures
/// with support for debounced events and spring animations.
class PointerGestureHelper {
  PointerGestureHelper._();

  /// Simulates moving mouse pointer over [targetFinder], waiting for debounce.
  static Future<TestGesture> hoverEnter(
    WidgetTester tester,
    Finder targetFinder, {
    Duration debounceDuration = const Duration(milliseconds: 200),
  }) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    await gesture.moveTo(tester.getCenter(targetFinder));
    await tester.pump();
    if (debounceDuration > Duration.zero) {
      await tester.pump(debounceDuration);
    }
    return gesture;
  }

  /// Simulates moving mouse pointer to an absolute offset, waiting for debounce.
  static Future<TestGesture> hoverEnterOffset(
    WidgetTester tester,
    Offset offset, {
    Duration debounceDuration = const Duration(milliseconds: 200),
  }) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    await gesture.moveTo(offset);
    await tester.pump();
    if (debounceDuration > Duration.zero) {
      await tester.pump(debounceDuration);
    }
    return gesture;
  }

  /// Simulates moving mouse pointer away from target and removing pointer.
  static Future<void> hoverExit(
    WidgetTester tester,
    TestGesture gesture, {
    Offset exitOffset = const Offset(900, 900),
    Duration reboundDuration = const Duration(milliseconds: 300),
  }) async {
    await gesture.moveTo(exitOffset);
    await tester.pump();
    await gesture.removePointer();
    if (reboundDuration > Duration.zero) {
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(reboundDuration);
    }
  }

  /// Simulates moving pointer to an offset without removing it.
  static Future<void> hoverMove(
    WidgetTester tester,
    TestGesture gesture,
    Offset location, {
    Duration pumpDuration = Duration.zero,
  }) async {
    await gesture.moveTo(location);
    await tester.pump();
    if (pumpDuration > Duration.zero) {
      await tester.pump(pumpDuration);
    }
  }

  /// Simulates a precision mouse click at [location].
  static Future<void> tapAt(WidgetTester tester, Offset location) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: location);
    await gesture.down(location);
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pump();
    await gesture.removePointer();
  }
}
