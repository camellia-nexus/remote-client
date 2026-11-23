import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/peers_view.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/models/platform_model.dart';
import 'package:camellia_remote_app/models/server_model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import '../harness/test_app_harness.dart';

void main() {
  setUp(() async {
    await TestAppHarness.setUp();
  });

  group('Tier 3: Settings Mutation Synchronization & Option Persistence', () {
    testWidgets(
      '1. Server configuration mutation updates bridge options and persists across reads',
      (tester) async {
        await bind.mainSetOption(
          key: 'custom-rendezvous-server',
          value: 'custom-id.camellia.org:21116',
        );
        await bind.mainSetOption(
          key: 'relay-server',
          value: 'custom-relay.camellia.org:21117',
        );
        await bind.mainSetOption(
          key: 'api-server',
          value: 'https://api.camellia.org:443',
        );
        await bind.mainSetOption(
          key: 'key',
          value: 'sha256-verified-key-token',
        );

        // Verify options stored in bridge
        final id = await bind.mainGetOption(key: 'custom-rendezvous-server');
        final relay = await bind.mainGetOption(key: 'relay-server');
        final api = await bind.mainGetOption(key: 'api-server');
        final key = await bind.mainGetOption(key: 'key');

        expect(id, equals('custom-id.camellia.org:21116'));
        expect(relay, equals('custom-relay.camellia.org:21117'));
        expect(api, equals('https://api.camellia.org:443'));
        expect(key, equals('sha256-verified-key-token'));
      },
    );

    testWidgets(
      '2. Password verification method mutation reacts dynamically in identity boards',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          surfaceSize: const Size(1280, 800),
          child: ChangeNotifierProvider.value(
            value: gFFI.serverModel,
            child: Consumer<ServerModel>(
              builder: (context, model, child) {
                final showOneTime =
                    model.approveMode != 'click' &&
                    model.verificationMethod != kUsePermanentPassword;
                return Center(
                  child: Text(
                    showOneTime
                        ? 'Mode: One-Time Password Active'
                        : 'Mode: Permanent Password Only',
                  ),
                );
              },
            ),
          ),
        );
        await tester.pump();

        // Initially both / one-time is active
        expect(find.text('Mode: One-Time Password Active'), findsOneWidget);

        // Mutate verification method to permanent password only
        await gFFI.serverModel.setVerificationMethod(kUsePermanentPassword);
        await gFFI.serverModel.updatePasswordModel();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.text('Mode: Permanent Password Only'), findsOneWidget);
        expect(find.text('Mode: One-Time Password Active'), findsNothing);

        // Mutate back to temporary password
        await gFFI.serverModel.setVerificationMethod(kUseTemporaryPassword);
        await gFFI.serverModel.updatePasswordModel();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.text('Mode: One-Time Password Active'), findsOneWidget);

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '3. Theme preference mutation persists to bridge and synchronizes theme tokens',
      (tester) async {
        // Save dark theme option
        await bind.mainSetOption(key: 'theme', value: 'Dark');
        final savedTheme = await bind.mainGetOption(key: 'theme');
        expect(savedTheme, equals('Dark'));

        // Switch TestAppHarness to dark mode
        await TestAppHarness.pumpWidget(
          tester,
          themeMode: ThemeMode.dark,
          child: Builder(
            builder: (context) {
              final tokens = AppVisual.tokens(context);
              return Container(
                color: tokens.page,
                child: Text('Canvas: ${tokens.page}'),
              );
            },
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        // Tokens resolve to canonical DarkCanvas
        expect(
          AppVisual.tokens(globalKey.currentContext!).page,
          equals(CamelliaColors.darkCanvas),
        );

        // Switch to light theme
        await bind.mainSetOption(key: 'theme', value: 'Light');
        expect(await bind.mainGetOption(key: 'theme'), equals('Light'));

        TestAppHarness.themeModeNotifier.value = ThemeMode.light;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        expect(
          AppVisual.tokens(globalKey.currentContext!).page,
          equals(CamelliaColors.lightCanvas),
        );

        await TestAppHarness.tearDown(tester);
      },
    );

    testWidgets(
      '4. Peer sorting option mutation persists to bridge and synchronizes peerSort state',
      (tester) async {
        // Set sorting to remoteHost
        await bind.mainSetOption(
          key: kOptionPeerSorting,
          value: PeerSortType.remoteHost,
        );
        peerSort.value = PeerSortType.remoteHost;

        expect(peerSort.value, equals(PeerSortType.remoteHost));
        expect(
          await bind.mainGetOption(key: kOptionPeerSorting),
          equals(PeerSortType.remoteHost),
        );

        // Set sorting to remoteId
        await bind.mainSetOption(
          key: kOptionPeerSorting,
          value: PeerSortType.remoteId,
        );
        peerSort.value = PeerSortType.remoteId;

        expect(peerSort.value, equals(PeerSortType.remoteId));
        expect(
          await bind.mainGetOption(key: kOptionPeerSorting),
          equals(PeerSortType.remoteId),
        );
      },
    );

    testWidgets(
      '5. Audio and direct connection option mutations persist in in-memory storage',
      (tester) async {
        // Mutate audio setting
        await bind.mainSetOption(key: 'audio', value: 'Y');
        expect(await bind.mainGetOption(key: 'audio'), equals('Y'));

        await bind.mainSetOption(key: 'audio', value: '');
        expect(await bind.mainGetOption(key: 'audio'), equals(''));

        // Mutate direct IP server setting
        await bind.mainSetOption(key: 'direct-server', value: 'Y');
        expect(await bind.mainGetOption(key: 'direct-server'), equals('Y'));

        await bind.mainSetOption(key: 'direct-server', value: 'N');
        expect(await bind.mainGetOption(key: 'direct-server'), equals('N'));
      },
    );
  });
}
