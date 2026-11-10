import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/consts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AndroidPermissionManager.debugForceMobilePlatform = true;
  });

  tearDown(() {
    AndroidPermissionManager.debugForceMobilePlatform = false;
  });

  group('PLATFORM-016: AndroidPermissionManager Lifecycle & Reply Contracts', () {
    test('check returns true on desktop/web and delegates on mobile', () async {
      AndroidPermissionManager.debugForceMobilePlatform = false;
      final res = await AndroidPermissionManager.check('android.permission.RECORD_AUDIO');
      expect(res, isTrue);
    });

    test('immediate resolution when permission is granted with request ID', () async {
      final future = AndroidPermissionManager.request('android.permission.RECORD_AUDIO');
      AndroidPermissionManager.complete(
        'android.permission.RECORD_AUDIO',
        true,
        requestId: '1',
      );
      final result = await future;
      expect(result, isTrue);
    });

    test('immediate resolution when permission is denied without waiting for timer', () async {
      final stopwatch = Stopwatch()..start();
      final future = AndroidPermissionManager.request('android.permission.RECORD_AUDIO');
      AndroidPermissionManager.complete(
        'android.permission.RECORD_AUDIO',
        false,
        requestId: '2',
      );
      final result = await future;
      stopwatch.stop();

      expect(result, isFalse);
      // Must resolve immediately (well under 1 second), never waiting 120s or 15s
      expect(stopwatch.elapsedMilliseconds, lessThan(1000));
    });

    test('stale request ID from previous generation is safely ignored', () async {
      final future1 = AndroidPermissionManager.request('android.permission.RECORD_AUDIO');
      // A new request arrives before the first completes
      final future2 = AndroidPermissionManager.request(kManageExternalStorage);

      // Previous request 1 was cancelled by request 2
      expect(await future1, isFalse);

      // Delayed callback from stale request arrives with old request_id
      AndroidPermissionManager.complete(
        'android.permission.RECORD_AUDIO',
        true,
        requestId: '3', // Corresponds to future1
      );

      // future2 is still pending, not affected by stale callback
      bool completed = false;
      future2.then((_) => completed = true);
      await Future.delayed(const Duration(milliseconds: 50));
      expect(completed, isFalse);

      // Now complete future2 with its matching type
      AndroidPermissionManager.complete(
        kManageExternalStorage,
        true,
        requestId: '4',
      );
      expect(await future2, isTrue);
    });

    test('mismatched type does not complete active request', () async {
      final future = AndroidPermissionManager.request(kManageExternalStorage);
      AndroidPermissionManager.complete(
        'android.permission.CAMERA',
        true,
      );

      bool completed = false;
      future.then((_) => completed = true);
      await Future.delayed(const Duration(milliseconds: 50));
      expect(completed, isFalse);

      AndroidPermissionManager.complete(
        kManageExternalStorage,
        true,
      );
      expect(await future, isTrue);
    });

    test('timeout resolves with false when system never responds', () async {
      final future = AndroidPermissionManager.request(
        'android.permission.RECORD_AUDIO',
        timeout: const Duration(milliseconds: 50),
      );
      final result = await future;
      expect(result, isFalse);
    });

    test('isWaitingFile reflects active manage external storage request', () async {
      expect(AndroidPermissionManager.isWaitingFile(), isFalse);
      final future = AndroidPermissionManager.request(kManageExternalStorage);
      expect(AndroidPermissionManager.isWaitingFile(), isTrue);

      AndroidPermissionManager.complete(kManageExternalStorage, true);
      await future;
      expect(AndroidPermissionManager.isWaitingFile(), isFalse);
    });
  });
}
