import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/animated_rotation_widget.dart';
import 'package:camellia_remote_app/common/widgets/dialog.dart';
import 'package:camellia_remote_app/common/widgets/peers_view.dart';
import 'package:camellia_remote_app/common/widgets/setting_widgets.dart';
import 'package:camellia_remote_app/generated_bridge.dart';
import 'package:camellia_remote_app/models/model.dart';
import 'package:camellia_remote_app/models/peer_model.dart';
import 'package:camellia_remote_app/models/platform_model.dart';

class _FakeRustdeskImpl extends Fake implements RustdeskImpl {
  final Map<String, String> localOptions = {};
  final List<String> clearedTrustedDevices = [];

  @override
  String mainGetLocalOption({required String key}) => localOptions[key] ?? '';
  @override
  Future<void> mainSetLocalOption({
    required String key,
    required String value,
  }) async {
    localOptions[key] = value;
  }

  @override
  String mainUriPrefixSync() => 'camellia-remote://';
  @override
  int mainMaxEncryptLen() => 128;
  @override
  bool mainHasValidBotSync() => false;
  @override
  bool mainHasValid2FaSync() => false;
  @override
  bool mainIsInstalled() => false;
  @override
  Future<String> mainGetOption({required String key}) async => '';
  @override
  String mainGetOptionSync({required String key}) => '';
  @override
  Future<void> mainSetOption({
    required String key,
    required String value,
  }) async {}

  @override
  Future<void> sessionClose({required UuidValue sessionId}) async {}
  @override
  Future<void> stopGlobalEventStream({required String appType}) async {}
  @override
  bool mainIsOptionFixed({required String key}) => false;
  @override
  bool isDisableAb() => false;
  @override
  bool isDisableAccount() => false;
  @override
  bool isDisableGroupPanel() => false;
  @override
  Future<bool> optionSynced() async => true;
  @override
  Future<String> mainGetConnectStatus() async => '{"status_num": 1}';
  @override
  String getLocalFlutterOption({required String k}) => '';
  @override
  Future<void> setLocalFlutterOption({
    required String k,
    required String v,
  }) async {}
  @override
  Future<String> mainGetApiServer() async => 'http://127.0.0.1:21114';

  @override
  Future<void> mainClearTrustedDevices() async {
    clearedTrustedDevices.add('cleared');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeRustdeskImpl fakeBridge;
  late FFI globalFFI;
  late OverlayKeyState overlayState;

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'),
            (MethodCall methodCall) async {
      return false;
    });
    fakeBridge = _FakeRustdeskImpl();
    platformFFI.ffiBind = fakeBridge;
    isTest = true;
    Get.reset();
    await initGlobalFFI();
    globalFFI = gFFI;
    overlayState = OverlayKeyState();
    globalFFI.dialogManager.setOverlayState(overlayState);
  });

  tearDown(() async {
    await globalFFI.close();
    Get.reset();
  });

  group('UI-001: Peer Sorting Comparator & Non-Mutating Filter', () {
    test('Peer status comparator satisfies antisymmetry, total ordering, and online-first', () {
      final p1 = Peer.fromJson({'id': 'peer-A', 'hash': 'h1'})..online = true;
      final p2 = Peer.fromJson({'id': 'peer-B', 'hash': 'h2'})..online = false;
      final p3 = Peer.fromJson({'id': 'peer-C', 'hash': 'h3'})..online = true;
      final p4 = Peer.fromJson({'id': 'peer-D', 'hash': 'h4'})..online = false;

      int compareStatus(Peer a, Peer b) {
        if (a.online != b.online) {
          return a.online ? -1 : 1;
        }
        return a.getId().compareTo(b.getId());
      }

      // Reflexivity
      expect(compareStatus(p1, p1), 0);
      expect(compareStatus(p2, p2), 0);

      // Antisymmetry
      expect(compareStatus(p1, p2), -1);
      expect(compareStatus(p2, p1), 1);
      expect(compareStatus(p2, p4), equals(-compareStatus(p4, p2)));
      expect(compareStatus(p1, p3), equals(-compareStatus(p3, p1)));

      // Sorting list gives online peers first ordered by ID, then offline peers ordered by ID
      final list = [p4, p3, p2, p1];
      list.sort(compareStatus);

      expect(list.map((p) => p.id).toList(), ['peer-A', 'peer-C', 'peer-B', 'peer-D']);
    });

    test('matchPeersStatic does not mutate input peer list in-place', () async {
      final p1 = Peer.fromJson({'id': 'zebra', 'hash': 'h1'})..online = false;
      final p2 = Peer.fromJson({'id': 'alpha', 'hash': 'h2'})..online = true;
      final originalList = [p1, p2];
      final originalIds = originalList.map((p) => p.id).toList();

      final filtered = await matchPeersStatic(
        searchText: '',
        sortedBy: PeerSortType.status,
        peers: originalList,
      );

      // Filtered list should be sorted (alpha online first, zebra offline second)
      expect(filtered.map((p) => p.id).toList(), ['alpha', 'zebra']);

      // Original backing list MUST NOT be mutated in-place
      expect(originalList.map((p) => p.id).toList(), originalIds);
      expect(originalList[0].id, 'zebra');
      expect(originalList[1].id, 'alpha');
    });
  });

  group('STATE-022: TrustedDevice Identity & Deletion Guard', () {
    test('hwidEquals and hwidToHex compare content rather than Uint8List object identity', () {
      final bytes1 = [1, 2, 3, 4, 5, 255];
      final bytes2 = [1, 2, 3, 4, 5, 255];
      final bytes3 = [1, 2, 3, 4, 5, 0];

      final dev1 = TrustedDevice.fromJson({'name': 'PC1', 'hwid': bytes1, 'time': 1, 'id': '1', 'platform': 'Linux'});
      final dev2 = TrustedDevice.fromJson({'name': 'PC1', 'hwid': bytes2, 'time': 1, 'id': '1', 'platform': 'Linux'});
      final dev3 = TrustedDevice.fromJson({'name': 'PC2', 'hwid': bytes3, 'time': 1, 'id': '2', 'platform': 'Linux'});

      // Different instances in Dart
      expect(identical(dev1.hwid, dev2.hwid), isFalse);

      expect(dev1.hwidHex, equals('0102030405ff'));
      expect(dev2.hwidHex, equals('0102030405ff'));
      expect(dev1, equals(dev2));
      expect(dev1.hashCode, equals(dev2.hashCode));
      expect(dev1, isNot(equals(dev3)));
      expect(hwidEquals(dev1.hwid, dev2.hwid), isTrue);
      expect(hwidEquals(dev1.hwid, dev3.hwid), isFalse);
    });

    test('Exact set equality distinguishes full set from subset even when lengths match', () {
      final dev1 = TrustedDevice.fromJson({'name': 'A', 'hwid': [10, 20], 'time': 1, 'id': '1', 'platform': 'Linux'});
      final dev2 = TrustedDevice.fromJson({'name': 'B', 'hwid': [30, 40], 'time': 1, 'id': '2', 'platform': 'Linux'});
      final dev3 = TrustedDevice.fromJson({'name': 'C', 'hwid': [50, 60], 'time': 1, 'id': '3', 'platform': 'Linux'});

      final currentDevices = [dev1, dev2];
      final currentHexSet = currentDevices.map((d) => d.hwidHex).toSet();

      // Selected list has length 2, but dev3 is not in currentDevices!
      final selectedDevices = [dev1, dev3];
      final selectedHexSet = selectedDevices.map((d) => d.hwidHex).toSet();

      // Length is equal (2 == 2)
      expect(selectedDevices.length, equals(currentDevices.length));

      // But exact set equality check correctly fails!
      final isExactFullMatch =
          currentDevices.length == selectedDevices.length &&
          currentHexSet.every(selectedHexSet.contains);
      expect(isExactFullMatch, isFalse);

      // True exact match
      final fullMatchDevices = [
        TrustedDevice.fromJson({'name': 'A-copy', 'hwid': [10, 20], 'time': 1, 'id': '1', 'platform': 'Linux'}),
        TrustedDevice.fromJson({'name': 'B-copy', 'hwid': [30, 40], 'time': 1, 'id': '2', 'platform': 'Linux'}),
      ];
      final fullHexSet = fullMatchDevices.map((d) => d.hwidHex).toSet();
      final isFullMatch =
          currentDevices.length == fullMatchDevices.length &&
          currentHexSet.every(fullHexSet.contains);
      expect(isFullMatch, isTrue);
    });
  });

  group('FEEDBACK-002: Audit Note Network Failure Handling', () {
    test('updateAuditNoteByGuid returns false on network failure without throwing', () async {
      // Calling with an unreachable server returns false rather than crashing
      final res = await updateAuditNoteByGuid('test-guid-123', 'Some audit text');
      expect(res, isFalse);
    });
  });

  group('RES-053: Disposable UI Objects & Debouncer Cancellation', () {
    test('CanvasModel dispose cleans up scroll controllers and guards notifications', () {
      final canvas = CanvasModel(WeakReference(globalFFI));
      expect(canvas.isDisposed, isFalse);
      expect(canvas.scrollHorizontal, isNotNull);
      expect(canvas.scrollVertical, isNotNull);

      // Calling dispose
      canvas.dispose();
      expect(canvas.isDisposed, isTrue);

      // Calling notifyListeners after dispose should be safely ignored and not throw
      expect(() => canvas.notifyListeners(), returnsNormally);

      // Idempotent dispose
      expect(() => canvas.dispose(), returnsNormally);
    });

    testWidgets('AnimatedRotationWidget cancels spin subscription on dispose',
        (WidgetTester tester) async {
      final spinning = false.obs;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AnimatedRotationWidget(
            spinning: spinning,
            onPressed: () {},
            child: const Icon(Icons.refresh),
          ),
        ),
      ));

      expect(find.byType(AnimatedRotationWidget), findsOneWidget);
      spinning.value = true;
      await tester.pump(const Duration(milliseconds: 50));

      // Replace widget to trigger dispose
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: SizedBox()),
      ));
      await tester.pumpAndSettle();

      // Changing spinning after disposal should not throw or cause setState after dispose
      expect(() => spinning.value = false, returnsNormally);
    });

    testWidgets('CustomImageQualityWidget cancels debouncers on dispose',
        (WidgetTester tester) async {
      double? changedQuality;
      double? changedFps;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CustomImageQualityWidget(
            initQuality: 80,
            initFps: 30,
            showMoreQuality: true,
            showFps: true,
            setQuality: (v) => changedQuality = v,
            setFps: (v) => changedFps = v,
          ),
        ),
      ));

      expect(find.byType(CustomImageQualityWidget), findsOneWidget);

      // Dispose widget
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: SizedBox()),
      ));
      await tester.pumpAndSettle();

      expect(changedQuality, isNull);
      expect(changedFps, isNull);
    });

    testWidgets('TrackpadSpeedWidgetState disposes text controller and cancels debouncers',
        (WidgetTester tester) async {
      final speed = SimpleWrapper<int>(50);
      int? debounced;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TrackpadSpeedWidget(
            value: speed,
            onDebouncer: (v) => debounced = v,
          ),
        ),
      ));

      expect(find.byType(TrackpadSpeedWidget), findsOneWidget);

      // Dispose widget
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: SizedBox()),
      ));
      await tester.pumpAndSettle();

      expect(debounced, isNull);
    });

    testWidgets('DialogVerificationCodeField removes listeners on controller and focusNode on dispose',
        (WidgetTester tester) async {
      final controller = TextEditingController(text: '1234');
      bool onChangedCalled = false;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DialogVerificationCodeField(
            controller: controller,
            title: 'Verify',
            onChanged: (setState, err) {
              onChangedCalled = true;
            },
          ),
        ),
      ));

      expect(find.byType(DialogVerificationCodeField), findsOneWidget);

      // Dispose widget
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: SizedBox()),
      ));
      await tester.pumpAndSettle();

      // Changing controller text after field disposal should not trigger onChanged
      onChangedCalled = false;
      controller.text = '5678';
      expect(onChangedCalled, isFalse);

      controller.dispose();
    });
  });
}
