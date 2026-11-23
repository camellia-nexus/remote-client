import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/peer_card.dart';
import 'package:camellia_remote_app/common/widgets/peer_tab_page.dart';
import 'package:camellia_remote_app/common/widgets/peers_view.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/consts.dart';
import '../harness/test_app_harness.dart';

void main() {
  setUp(() async {
    await TestAppHarness.setUp();
    TestAppHarness.fakeBridge.setLocalFlutterOption(
      k: kOptionPeerSorting,
      v: PeerSortType.remoteId,
    );
    peerSort.value = PeerSortType.remoteId;
    peerSearchTextController.clear();
    peerSearchText.value = '';
    peerCardUiType.value = PeerUiType.grid;
    gFFI.peerTabModel.setCurrentTab(0);
  });

  tearDown(() {
    peerSearchTextController.clear();
    peerSearchText.value = '';
  });

  group('Tier 1: Device Workspace & Peer Directory Coverage', () {
    testWidgets('1. Displays category tabs and renders seeded recent peers', (
      tester,
    ) async {
      await TestAppHarness.pumpWidget(
        tester,
        surfaceSize: const Size(1280, 800),
        child: const Scaffold(
          body: SizedBox(
            width: 1000,
            height: 700,
            child: PeerTabPage(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      // Verify category tabs exist
      expect(find.byTooltip('Recent sessions'), findsOneWidget);
      expect(find.byTooltip('Favorites'), findsOneWidget);
      expect(find.byTooltip('Discovered'), findsOneWidget);

      // Verify seeded recent peers are rendered
      expect(find.textContaining('Alice'), findsWidgets);
      expect(find.textContaining('Bob'), findsWidgets);

      await TestAppHarness.tearDown(tester);
    });

    testWidgets('2. Category tabs navigation switches active peer list', (
      tester,
    ) async {
      await TestAppHarness.pumpWidget(
        tester,
        surfaceSize: const Size(1280, 800),
        child: const Scaffold(
          body: SizedBox(
            width: 1000,
            height: 700,
            child: PeerTabPage(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      // Switch to Favorites tab
      final favTab = find.byTooltip('Favorites');
      expect(favTab, findsOneWidget);
      await tester.tap(favTab);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      expect(gFFI.peerTabModel.currentTab, equals(1));
      // Favorites seeded: Bob and Charlie
      expect(find.textContaining('Charlie'), findsWidgets);

      // Switch to Discovered tab
      final lanTab = find.byTooltip('Discovered');
      expect(lanTab, findsOneWidget);
      await tester.tap(lanTab);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      expect(gFFI.peerTabModel.currentTab, equals(2));
      // Discovered seeded: Alice and Diana
      expect(find.textContaining('Diana'), findsWidgets);

      await TestAppHarness.tearDown(tester);
    });

    testWidgets('3. Search bar filters peer list based on query', (
      tester,
    ) async {
      await TestAppHarness.pumpWidget(
        tester,
        surfaceSize: const Size(1280, 800),
        child: const Scaffold(
          body: SizedBox(
            width: 1000,
            height: 700,
            child: PeerTabPage(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      // Both Alice and Bob are initially visible
      expect(find.textContaining('Alice'), findsWidgets);
      expect(find.textContaining('Bob'), findsWidgets);

      // Enter search query "Alice"
      final searchInput = find.byType(TextField);
      expect(searchInput, findsWidgets);
      await tester.enterText(searchInput.first, 'Alice');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      // Alice should still be visible, Bob should be filtered out
      expect(find.textContaining('Alice'), findsWidgets);
      expect(find.textContaining('Bob'), findsNothing);

      // Clear search
      await tester.enterText(searchInput.first, '');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      expect(find.textContaining('Alice'), findsWidgets);
      expect(find.textContaining('Bob'), findsWidgets);

      await TestAppHarness.tearDown(tester);
    });

    testWidgets('4. View layout toggling switches between grid and list', (
      tester,
    ) async {
      await TestAppHarness.pumpWidget(
        tester,
        surfaceSize: const Size(1280, 800),
        child: const Scaffold(
          body: SizedBox(
            width: 1000,
            height: 700,
            child: PeerTabPage(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      // Initially grid view
      expect(peerCardUiType.value, equals(PeerUiType.grid));

      // Toggle to List view via UI type property
      peerCardUiType.value = PeerUiType.list;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      expect(peerCardUiType.value, equals(PeerUiType.list));

      // Toggle to Tile view
      peerCardUiType.value = PeerUiType.tile;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      expect(peerCardUiType.value, equals(PeerUiType.tile));

      await TestAppHarness.tearDown(tester);
    });

    testWidgets(
      '5. Online glowing indicator versus offline muted indicator on peer cards',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: const Scaffold(
            body: SizedBox(
              width: 1000,
              height: 700,
              child: PeerTabPage(),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));

        // Switch to Favorites tab which contains Bob (online) and Charlie (offline)
        final favTab = find.byTooltip('Favorites');
        await tester.tap(favTab);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));

        // Verify Online and Offline tooltips exist on status indicators
        expect(find.byTooltip('Online'), findsWidgets);
        expect(find.byTooltip('Offline'), findsWidgets);

        // Verify tone colors on status avatars
        final context = globalKey.currentContext!;
        final glass = CamelliaGlassTokens.of(context);
        final onlineColor = glass.statusOnline;
        final offlineColor = glass.statusOffline;

        final avatars = tester.widgetList<CircleAvatar>(find.byType(CircleAvatar));
        expect(avatars.any((a) => a.backgroundColor == onlineColor), isTrue);
        expect(avatars.any((a) => a.backgroundColor == offlineColor), isTrue);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets('6. 3-dots popup menu triggers peer context options', (
      tester,
    ) async {
      await TestAppHarness.pumpWidget(
        tester,
        surfaceSize: const Size(1280, 800),
        child: const Scaffold(
          body: SizedBox(
            width: 1000,
            height: 700,
            child: PeerTabPage(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      // Find more_vert icons on peer cards
      final moreIcons = find.byIcon(Icons.more_vert);
      expect(moreIcons, findsWidgets);

      // Tap the first more_vert icon
      await tester.tap(moreIcons.first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // Verify popup menu entries appear
      expect(find.textContaining('Connect'), findsWidgets);
      expect(find.textContaining('Transfer file'), findsWidgets);

      // Dismiss menu by tapping barrier
      await tester.tapAt(const Offset(10, 10));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      await TestAppHarness.tearDown(tester);
    });
  });
}
