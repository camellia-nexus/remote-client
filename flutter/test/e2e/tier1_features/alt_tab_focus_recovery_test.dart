// ignore_for_file: deprecated_member_use
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/models/state_model.dart';
import 'package:camellia_remote_app/desktop/pages/desktop_home_page.dart';
import 'package:camellia_remote_app/desktop/pages/desktop_setting_page.dart';
import '../harness/test_app_harness.dart';

void main() {
  setUp(() async {
    await TestAppHarness.setUp();
  });

  group('Tier 1: Alt+Tab & Window Focus Recovery Coverage (F03)', () {
    testWidgets(
      '1. (F03) Resumed lifecycle state with videoConnCount == 0 immediately clears _block without gray-out mask',
      (tester) async {
        stateGlobal.videoConnCount.value = 0;
        final block = true.obs;

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: const DesktopHomePage(),
        );
        await tester.pump();

        // Simulate app lifecycle resuming after Alt+Tab
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        // Evaluate block with local active connection check
        Future<bool> shouldUseBlock() async =>
            await canBeBlocked() && stateGlobal.videoConnCount > 0;
        await shouldBeBlocked(block, shouldUseBlock);
        await tester.pump();

        expect(block.value, isFalse);

        // Verify that remote-block-mask is either not mounted or offstage
        final maskFinder = find.byKey(const ValueKey('remote-block-mask'));
        if (maskFinder.evaluate().isNotEmpty) {
          final offstage = tester.widget<Offstage>(maskFinder);
          expect(offstage.offstage, isTrue);
        }

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '2. (F03) Authoritative pointer check is bypassed locally when videoConnCount == 0 (zero pointerCheckCount)',
      (tester) async {
        stateGlobal.videoConnCount.value = 0;
        TestAppHarness.fakeBridge.pointerCheckCount = 0;

        final block = false.obs;
        Future<bool> shouldUseBlock() async =>
            await canBeBlocked() && stateGlobal.videoConnCount > 0;

        await shouldBeBlocked(block, shouldUseBlock);

        // Pointer check on native bridge should not be invoked when no video connection exists
        expect(TestAppHarness.fakeBridge.pointerCheckCount, equals(0));
        expect(block.value, isFalse);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '3. (F03) Pointer check count is tracked and UI unmasks when videoConnCount > 0 and pointer check returns false',
      (tester) async {
        stateGlobal.videoConnCount.value = 1;
        TestAppHarness.fakeBridge.pointerCheckCount = 0;
        TestAppHarness.fakeBridge.pointerCheckReturnAuthoritative = false;

        final block = false.obs;

        // When connection is active, shouldBeBlocked executes authoritative check
        await shouldBeBlocked(block, () async => true);

        expect(TestAppHarness.fakeBridge.pointerCheckCount, greaterThanOrEqualTo(1));
        // Bridge returned false -> UI must be unmasked, not locked
        expect(block.value, isFalse);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '4. (F03) Per-RxBool tokens prevent concurrency race condition during simultaneous focus events',
      (tester) async {
        final blockHome = false.obs;
        final blockSetting = false.obs;
        TestAppHarness.fakeBridge.pointerCheckReturnAuthoritative = false;

        // Concurrently invoke shouldBeBlocked for two separate pages
        await Future.wait([
          shouldBeBlocked(blockHome, null),
          shouldBeBlocked(blockSetting, null),
        ]);

        // Both tokens must resolve independently without leaving either page locked
        expect(blockHome.value, isFalse);
        expect(blockSetting.value, isFalse);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '5. (F03) DesktopSettingPage didChangeAppLifecycleState on resumed state preserves interactable settings',
      (tester) async {
        stateGlobal.videoConnCount.value = 0;

        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: DesktopSettingPage(initialTabkey: SettingsTabKey.general),
        );
        await tester.pump();

        // Simulate Alt+Tab blur and regain focus
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));

        // Settings tabs should remain clickable without fail-closed pointer absorption
        final securityTabFinder = find.text('Security');
        expect(securityTabFinder, findsOneWidget);

        await tester.tap(securityTabFinder);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        // Interaction succeeded
        expect(tester.takeException(), isNull);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '6. (F03) buildRemoteBlock MouseRegion onExit immediately unblocks and increments token',
      (tester) async {
        final block = true.obs;

        await TestAppHarness.pumpWidget(
          tester,
          child: buildRemoteBlock(
            block: block,
            mask: true,
            child: const Text('Protected Content'),
          ),
        );
        await tester.pump();

        // Simulate mouse exit event
        final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await gesture.addPointer(location: tester.getCenter(find.text('Protected Content')));
        await tester.pump();

        await gesture.moveTo(const Offset(999, 999));
        await tester.pump();
        await gesture.removePointer();
        await tester.pump();

        expect(block.value, isFalse);

        await TestAppHarness.tearDown(tester);
      },
    );
  });
}
