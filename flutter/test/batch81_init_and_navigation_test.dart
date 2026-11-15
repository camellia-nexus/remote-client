import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/models/file_model.dart';
import 'package:camellia_remote_app/models/native_model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Batch 81: PlatformFFI Staged Startup and Rollback (INIT-001)', () {
    test('StartupResult handles success and failure invariants', () {
      const success = StartupResult.success();
      expect(success.isSuccess, isTrue);
      expect(success.stage, equals(StartupStage.fullyInitialized));
      expect(success.error, isNull);
      expect(success.stackTrace, isNull);

      final failure = StartupResult.failure(
        StartupStage.bridgeInitialized,
        'Simulated dynamic library bridge failure',
      );
      expect(failure.isSuccess, isFalse);
      expect(failure.stage, equals(StartupStage.bridgeInitialized));
      expect(failure.error, contains('Simulated dynamic library bridge failure'));
    });

    test('PlatformFFI rollback transitions to failed stage and cleans subscriptions', () {
      final ffi = PlatformFFI.instance;
      ffi.resetForRetry();
      expect(ffi.startupStage, equals(StartupStage.uninitialized));
      expect(ffi.isFullyInitialized, isFalse);

      ffi.rollback(StartupStage.deviceConfigured);
      expect(ffi.startupStage, equals(StartupStage.failed));
      expect(ffi.isFullyInitialized, isFalse);

      ffi.resetForRetry();
      expect(ffi.startupStage, equals(StartupStage.uninitialized));
      expect(ffi.isFullyInitialized, isFalse);
    });

    test('StartupStage covers all staged initialization milestones', () {
      const stages = StartupStage.values;
      expect(stages, contains(StartupStage.uninitialized));
      expect(stages, contains(StartupStage.libraryLoaded));
      expect(stages, contains(StartupStage.bridgeInitialized));
      expect(stages, contains(StartupStage.eventListenerStarted));
      expect(stages, contains(StartupStage.deviceConfigured));
      expect(stages, contains(StartupStage.fullyInitialized));
      expect(stages, contains(StartupStage.failed));
    });
  });

  group('Batch 81: FileController Back Navigation Invariants (NAV-001)', () {
    late FileController controller;

    setUp(() {
      controller = FileController(isLocal: true);
    });

    test('canGoBack is false when history is empty, and goBack returns false', () {
      expect(controller.history.isEmpty, isTrue);
      expect(controller.canGoBack, isFalse);

      final didGoBack = controller.goBack();
      expect(didGoBack, isFalse);
      expect(controller.history.isEmpty, isTrue);
    });

    test('canGoBack is true when history has entries, and goBack pops and returns true', () {
      controller.history.add('/root');
      controller.history.add('/root/subfolder');

      expect(controller.canGoBack, isTrue);
      expect(controller.history.length, equals(2));

      final didGoBack = controller.goBack();
      expect(didGoBack, isTrue);
      expect(controller.history.length, equals(1));
      expect(controller.history.first, equals('/root'));

      final didGoBack2 = controller.goBack();
      expect(didGoBack2, isTrue);
      expect(controller.history.isEmpty, isTrue);
      expect(controller.canGoBack, isFalse);

      // Subsequent call when empty fails closed
      final didGoBack3 = controller.goBack();
      expect(didGoBack3, isFalse);
    });
  });
}
