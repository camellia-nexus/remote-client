import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/peer_card.dart';
import 'package:camellia_remote_app/common/widgets/peer_tab_page.dart';
import 'package:camellia_remote_app/common/widgets/peers_view.dart';
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

  group('Tier 3: Device Search Query Persistence Across Category Tabs & Layouts', () {
    testWidgets(
      '1. Active search query persists across category tabs and dynamically filters tab-specific peers',
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

        // 1. Enter search query "Alice" in Recent tab (tab 0: Alice, Bob)
        final searchInput = find.byType(TextField);
        expect(searchInput, findsWidgets);
        await tester.enterText(searchInput.first, 'Alice');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));

        // Alice is present, Bob is filtered out
        expect(find.textContaining('Alice'), findsWidgets);
        expect(find.textContaining('Bob'), findsNothing);

        // 2. Switch to Favorites tab (tab 1: Bob, Charlie)
        final favTab = find.byTooltip('Favorites');
        await tester.tap(favTab);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));

        expect(gFFI.peerTabModel.currentTab, equals(1));
        // Alice is not in Favorites, so both Bob and Charlie (Prod Server) are filtered out
        expect(find.textContaining('Bob'), findsNothing);
        expect(find.textContaining('Prod Server'), findsNothing);

        // 3. Switch to Discovered tab (tab 2: Alice, Diana)
        final lanTab = find.byTooltip('Discovered');
        await tester.tap(lanTab);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));

        expect(gFFI.peerTabModel.currentTab, equals(2));
        // Alice is in Discovered, so Alice matches! Diana is filtered out
        expect(find.textContaining('Alice'), findsWidgets);
        expect(find.textContaining('Diana'), findsNothing);

        // Search text field still contains "Alice"
        expect(peerSearchTextController.text, equals('Alice'));

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '2. Filtered search results remain consistent across Grid, List, and Tile view toggles',
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

        // Filter for Bob on Recent tab
        final searchInput = find.byType(TextField);
        await tester.enterText(searchInput.first, 'Bob');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));

        // 1. Grid layout
        expect(peerCardUiType.value, equals(PeerUiType.grid));
        expect(find.textContaining('Bob'), findsWidgets);
        expect(find.textContaining('Alice'), findsNothing);

        // 2. Switch to List layout
        peerCardUiType.value = PeerUiType.list;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));

        expect(peerCardUiType.value, equals(PeerUiType.list));
        expect(find.textContaining('Bob'), findsWidgets);
        expect(find.textContaining('Alice'), findsNothing);

        // 3. Switch to Tile layout
        peerCardUiType.value = PeerUiType.tile;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));

        expect(peerCardUiType.value, equals(PeerUiType.tile));
        expect(find.textContaining('Bob'), findsWidgets);
        expect(find.textContaining('Alice'), findsNothing);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '3. Case-insensitive query and partial identifier search matches expected targets',
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

        // Switch to Favorites tab (Bob, Charlie)
        await tester.tap(find.byTooltip('Favorites'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));

        final searchInput = find.byType(TextField);

        // Search with uppercase 'PROD' matching Charlie's alias (Prod Server)
        await tester.enterText(searchInput.first, 'PROD');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));

        expect(find.textContaining('Prod Server'), findsWidgets);
        expect(find.textContaining('Bob'), findsNothing);

        // Search by numeric ID of Bob ('100002')
        await tester.enterText(searchInput.first, '100002');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));

        expect(find.textContaining('Bob'), findsWidgets);
        expect(find.textContaining('Prod Server'), findsNothing);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '4. Clearing search query restores full peer catalog for the active category',
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

        // Switch to Favorites tab (Bob, Charlie)
        await tester.tap(find.byTooltip('Favorites'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));

        final searchInput = find.byType(TextField);

        // Apply filter 'Bob'
        await tester.enterText(searchInput.first, 'Bob');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));

        expect(find.textContaining('Bob'), findsWidgets);
        expect(find.textContaining('Charlie'), findsNothing);

        // Clear query
        await tester.enterText(searchInput.first, '');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));

        // Both Bob and Charlie restored
        expect(find.textContaining('Bob'), findsWidgets);
        expect(find.textContaining('Charlie'), findsWidgets);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '5. Non-matching search query displays empty catalog cleanly without unhandled exception',
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

        final searchInput = find.byType(TextField);

        // Enter non-matching query
        await tester.enterText(searchInput.first, 'NoSuchHost99999');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));

        expect(find.textContaining('Alice'), findsNothing);
        expect(find.textContaining('Bob'), findsNothing);
        expect(tester.takeException(), isNull);

        await TestAppHarness.tearDown(tester);
      },
    );
  });
}
