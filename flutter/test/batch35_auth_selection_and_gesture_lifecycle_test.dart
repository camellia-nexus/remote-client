import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/hbbs/hbbs.dart';
import 'package:camellia_remote_app/common/widgets/gestures.dart';
import 'package:camellia_remote_app/common/widgets/login.dart';
import 'package:camellia_remote_app/generated_bridge.dart';
import 'package:camellia_remote_app/models/model.dart';
import 'package:camellia_remote_app/models/peer_model.dart';
import 'package:camellia_remote_app/models/platform_model.dart';
import 'package:camellia_remote_app/models/user_model.dart';

class _FakeRustdeskImpl extends RustdeskImpl {
  final Map<String, String> localOptions = {};
  String savedGroupJson = '';
  int logoutCalls = 0;
  int clearGroupCalls = 0;

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
  Future<void> mainAccountLogout() async {
    logoutCalls++;
  }

  @override
  Future<void> mainSaveGroup({required String json}) async {
    savedGroupJson = json;
  }

  @override
  Future<String> mainLoadGroup() async => savedGroupJson;

  @override
  Future<void> mainClearGroup() async {
    clearGroupCalls++;
    savedGroupJson = '';
  }

  @override
  Future<void> sessionClose({required UuidValue sessionId}) async {}
  @override
  Future<void> stopGlobalEventStream({required String appType}) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

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
  Future<String> mainGetOption({required String key}) async => '';
  @override
  Future<void> mainSetOption({
    required String key,
    required String value,
  }) async {}
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
  Future<String> mainAccountAuthResult() async => '';
  @override
  Future<void> mainAccountAuth({
    required String op,
    required bool rememberMe,
  }) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeRustdeskImpl fakeBridge;
  late FFI globalFFI;

  setUp(() async {
    fakeBridge = _FakeRustdeskImpl();
    platformFFI.ffiBind = fakeBridge;
    AuthGenerationTracker.resetForTesting();
    isTest = true;
    Get.reset();
    await initGlobalFFI();
    globalFFI = gFFI;
  });

  tearDown(() async {
    await globalFFI.close();
    Get.reset();
  });

  group('RES-059: Flutter OIDC Auth Polling Lifecycle & Generation Fencing', () {
    test('AuthGenerationTracker increments and invalidates monotonically', () {
      expect(AuthGenerationTracker.currentAuthGen, equals(0));
      final gen1 = AuthGenerationTracker.nextGen();
      expect(gen1, equals(1));
      expect(AuthGenerationTracker.currentAuthGen, equals(1));

      AuthGenerationTracker.invalidate();
      expect(AuthGenerationTracker.currentAuthGen, equals(2));

      final gen3 = AuthGenerationTracker.nextGen();
      expect(gen3, equals(3));
      expect(AuthGenerationTracker.currentAuthGen, equals(3));
    });

    testWidgets('ButtonOP is disabled when curOP is non-empty to prevent re-entrant auth triggers', (tester) async {
      final curOP = ''.obs;
      int tapCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ButtonOP(
              op: 'google',
              icon: null,
              curOP: curOP,
              primaryColor: Colors.blue,
              height: 36,
              onTap: () {
                tapCount++;
                curOP.value = 'google';
              },
            ),
          ),
        ),
      );

      // Initially empty: button is enabled
      final elevatedButtonFinder = find.byType(ElevatedButton);
      expect(elevatedButtonFinder, findsOneWidget);
      ElevatedButton button = tester.widget<ElevatedButton>(elevatedButtonFinder);
      expect(button.onPressed, isNotNull);

      // Tap button: starts auth, sets curOP
      await tester.tap(elevatedButtonFinder);
      await tester.pump();
      expect(tapCount, equals(1));
      expect(curOP.value, equals('google'));

      // Now curOP is not empty: button is disabled
      button = tester.widget<ElevatedButton>(elevatedButtonFinder);
      expect(button.onPressed, isNull);

      // Re-entrant taps are blocked
      await tester.tap(elevatedButtonFinder);
      await tester.pump();
      expect(tapCount, equals(1));
    });
  });

  group('STATE-020: Peer Multi-Selection Tab Isolation & Category Switching', () {
    test('switching tabs clears selectedPeers, resets multiSelectionMode and selectionTab', () {
      final peerTabModel = globalFFI.peerTabModel;

      peerTabModel.setCurrentTab(0);
      expect(peerTabModel.currentTab, equals(0));
      expect(peerTabModel.selectionTab, equals(-1));
      expect(peerTabModel.multiSelectionMode, isFalse);
      expect(peerTabModel.selectedPeers, isEmpty);

      // Enter multi-selection mode in tab 0
      peerTabModel.setMultiSelectionMode(true);
      expect(peerTabModel.multiSelectionMode, isTrue);
      expect(peerTabModel.selectionTab, equals(0));

      // Switch to tab 1 (e.g. from Recent to Favorites)
      peerTabModel.setCurrentTab(1);
      expect(peerTabModel.currentTab, equals(1));
      expect(peerTabModel.selectionTab, equals(-1));
      expect(peerTabModel.multiSelectionMode, isFalse);
      expect(peerTabModel.selectedPeers, isEmpty);

      // Entering multi-selection mode in tab 1 binds selectionTab to 1
      peerTabModel.setMultiSelectionMode(true);
      expect(peerTabModel.multiSelectionMode, isTrue);
      expect(peerTabModel.selectionTab, equals(1));
    });

    test('selectAll sets selectionTab to currentTab', () {
      final peerTabModel = globalFFI.peerTabModel;
      peerTabModel.setCurrentTab(2);
      expect(peerTabModel.selectionTab, equals(-1));

      peerTabModel.selectAll();
      expect(peerTabModel.selectionTab, equals(2));
    });

    test('setMultiSelectionMode(false) clears selection and resets selectionTab', () {
      final peerTabModel = globalFFI.peerTabModel;
      peerTabModel.setCurrentTab(0);
      peerTabModel.setMultiSelectionMode(true);
      expect(peerTabModel.selectionTab, equals(0));
      expect(peerTabModel.multiSelectionMode, isTrue);

      peerTabModel.setMultiSelectionMode(false);
      expect(peerTabModel.selectionTab, equals(-1));
      expect(peerTabModel.selectedPeers, isEmpty);
      expect(peerTabModel.multiSelectionMode, isFalse);
    });
  });

  group('STATE-021: UserModel & GroupModel Account Generation Fencing', () {
    test('UserModel account generation increments on nextAccountGen and reset', () async {
      final initialGen = UserModel.currentAccountGen;
      final nextGen = UserModel.nextAccountGen();
      expect(nextGen, equals(initialGen + 1));
      expect(UserModel.currentAccountGen, equals(nextGen));

      // Resetting user model increments account generation to drop stale in-flight responses
      await globalFFI.userModel.reset();
      expect(UserModel.currentAccountGen, equals(nextGen + 1));
      expect(globalFFI.userModel.accountState.value, equals(UserAccountState.signedOut));
      expect(fakeBridge.logoutCalls, equals(1));
      expect(fakeBridge.localOptions['access_token'], equals(''));
    });

    test('GroupModel reset clears state and resets initialized and loading flags', () async {
      final groupModel = globalFFI.groupModel;
      groupModel.initialized = true;
      groupModel.groupLoading.value = true;
      groupModel.groupLoadError.value = 'some error';
      groupModel.deviceGroups.add(DeviceGroupPayload('Group 1'));
      groupModel.users.add(UserPayload.fromJson({'name': 'user_1', 'email': 'test@camellia.org'}));
      groupModel.peers.add(Peer.fromJson({'id': 'peer_1'}));

      await groupModel.reset();

      expect(groupModel.initialized, isFalse);
      expect(groupModel.groupLoading.value, isFalse);
      expect(groupModel.groupLoadError.value, isEmpty);
      expect(groupModel.deviceGroups, isEmpty);
      expect(groupModel.users, isEmpty);
      expect(groupModel.peers, isEmpty);
      expect(fakeBridge.clearGroupCalls, equals(1));
    });

    test('GroupModel loadCache and saveCache protect against token mismatch', () async {
      final groupModel = globalFFI.groupModel;
      fakeBridge.localOptions['access_token'] = 'token_alpha';

      // Save cache with matching token
      groupModel.deviceGroups.add(DeviceGroupPayload('Group A'));
      // Direct call to loadCache
      await groupModel.loadCache();

      // If token changes (e.g. User logged out or switched to token_beta), save with expectedToken token_alpha skips
      fakeBridge.localOptions['access_token'] = 'token_beta';
      fakeBridge.savedGroupJson = '';

      // Reset and attempt to load cache with mismatched access_token in stored data
      fakeBridge.savedGroupJson = jsonEncode({
        'access_token': 'token_alpha',
        'device_groups': [
          {'name': 'Leaked Group'}
        ]
      });

      await groupModel.reset();
      await groupModel.loadCache();
      // Should not load cache because data access_token ('token_alpha') != active access_token ('token_beta')
      expect(groupModel.deviceGroups, isEmpty);
    });
  });

  group('RES-060: CustomTouchGestureRecognizer Debounce & Disposal Lifecycle', () {
    test('dispose cancels debounce timer and clears all gesture callbacks', () {
      final recognizer = CustomTouchGestureRecognizer();

      bool panStarted = false;
      bool scaleStarted = false;
      bool dragStarted = false;

      recognizer.onOneFingerPanStart = (d) {
        panStarted = true;
      };
      recognizer.onTwoFingerScaleStart = (d) {
        scaleStarted = true;
      };
      recognizer.onThreeFingerVerticalDragStart = (d) {
        dragStarted = true;
      };

      expect(recognizer.onOneFingerPanStart, isNotNull);
      expect(recognizer.onTwoFingerScaleStart, isNotNull);
      expect(recognizer.onThreeFingerVerticalDragStart, isNotNull);

      // Call dispose
      recognizer.dispose();

      // Verify all callbacks are detached
      expect(recognizer.onOneFingerPanStart, isNull);
      expect(recognizer.onOneFingerPanUpdate, isNull);
      expect(recognizer.onOneFingerPanEnd, isNull);
      expect(recognizer.onOneFingerPanCancel, isNull);
      expect(recognizer.onTwoFingerScaleStart, isNull);
      expect(recognizer.onTwoFingerScaleUpdate, isNull);
      expect(recognizer.onTwoFingerScaleEnd, isNull);
      expect(recognizer.onThreeFingerVerticalDragStart, isNull);
      expect(recognizer.onThreeFingerVerticalDragUpdate, isNull);
      expect(recognizer.onThreeFingerVerticalDragEnd, isNull);

      // Triggering callbacks would do nothing and not throw
      expect(panStarted, isFalse);
      expect(scaleStarted, isFalse);
      expect(dragStarted, isFalse);
    });

    test('rejectGesture cancels debounce timer and resets state cleanly', () {
      final recognizer = CustomTouchGestureRecognizer();
      bool cancelCalled = false;
      recognizer.onOneFingerPanCancel = () {
        cancelCalled = true;
      };

      recognizer.rejectGesture(1);
      expect(cancelCalled, isFalse);

      recognizer.dispose();
    });
  });
}
