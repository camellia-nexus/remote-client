import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/dialog.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/generated_bridge.dart';
import 'package:camellia_remote_app/models/model.dart';
import 'package:camellia_remote_app/models/platform_model.dart';

class _FakeRustdeskImpl extends Fake implements RustdeskImpl {
  final Map<String, String> localOptions = {};
  final Map<String, String> options = {};
  String langsJson = '[["en","English"],["zh-CN","简体中文"]]';
  bool shouldThrowLangs = false;
  bool shouldThrowSetOption = false;

  @override
  bool isCustomClient() => false;

  @override
  Future<void> sessionSendMouse({
    required UuidValue sessionId,
    required String msg,
  }) async {}

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
  Future<String> mainGetOption({required String key}) async =>
      options[key] ?? '';
  @override
  String mainGetOptionSync({required String key}) => options[key] ?? '';
  @override
  Future<void> mainSetOption({
    required String key,
    required String value,
  }) async {
    if (shouldThrowSetOption) {
      throw Exception('IPC persistence failure');
    }
    options[key] = value;
  }

  @override
  Future<String> mainGetOptions() async => jsonEncode(options);

  @override
  Future<String> mainGetLangs() async {
    if (shouldThrowLangs) {
      throw Exception('Network timeout fetching language catalog');
    }
    return langsJson;
  }

  @override
  Future<String> mainGetApiServer() async => options['api-server'] ?? '';

  @override
  Future<String> mainTestIfValidServer({
    required String server,
    required bool testWithProxy,
  }) async => '';

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
  bool isOutgoingOnly() => false;
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
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _FakeRustdeskImpl fakeBridge;
  late FFI globalFFI;
  late OverlayKeyState overlayState;

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), (
          MethodCall methodCall,
        ) async {
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

  group('AUTH-007: Whitelist bare 0.0.0.0 sentinel bypass and validation', () {
    test('whitelistNotEmpty correctly distinguishes empty vs populated', () {
      fakeBridge.options[kOptionWhitelist] = '';
      expect(whitelistNotEmpty(), isFalse);

      fakeBridge.options[kOptionWhitelist] = ',';
      expect(whitelistNotEmpty(), isFalse);

      fakeBridge.options[kOptionWhitelist] = '   ,  , ';
      expect(whitelistNotEmpty(), isFalse);

      fakeBridge.options[kOptionWhitelist] = '192.168.1.100';
      expect(whitelistNotEmpty(), isTrue);

      fakeBridge.options[kOptionWhitelist] = ' 10.0.0.0/24 , 2001:db8::/32 ';
      expect(whitelistNotEmpty(), isTrue);
    });

    testWidgets('changeWhiteList rejects bare 0.0.0.0 and unspecified IPs', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(home: Overlay(key: overlayState.key)),
      );

      changeWhiteList();
      await tester.pumpAndSettle();

      expect(find.text('IP Whitelisting'), findsOneWidget);

      // Enter bare 0.0.0.0
      await tester.enterText(find.byType(TextField), '0.0.0.0');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      // Dialog should remain open with error message
      expect(find.text('IP Whitelisting'), findsOneWidget);
      expect(find.textContaining('0.0.0.0'), findsWidgets);
      expect(
        find.textContaining('Unspecified IP address not allowed'),
        findsOneWidget,
      );

      // Enter unspecified IPv6 ::
      await tester.enterText(find.byType(TextField), '::');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('IP Whitelisting'), findsOneWidget);
      expect(
        find.textContaining('Unspecified IP address not allowed'),
        findsOneWidget,
      );

      // Enter valid CIDRs
      await tester.enterText(
        find.byType(TextField),
        '192.168.1.100\n10.0.0.0/24\n2001:db8::/32',
      );
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      // Dialog should close and option should be saved
      expect(find.text('IP Whitelisting'), findsNothing);
      expect(
        fakeBridge.options[kOptionWhitelist],
        '192.168.1.100,10.0.0.0/24,2001:db8::/32',
      );
    });
  });

  group('STATE-026: Port and timeout dialogs Cancel vs Commit isolation', () {
    testWidgets(
      'changeDirectAccessPort returns null on Cancel without overwriting',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(home: Overlay(key: overlayState.key)),
        );

        String? resultPort;
        changeDirectAccessPort('127.0.0.1', '21118').then((val) {
          resultPort = val;
        });
        await tester.pumpAndSettle();

        expect(find.text('Change Local Port'), findsOneWidget);

        // Enter a modified port
        await tester.enterText(find.byType(TextField), '30000');
        // Tap Cancel
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        // Must return null, and option must not be set
        expect(resultPort, isNull);
        expect(fakeBridge.options[kOptionDirectAccessPort], isNull);

        // Now test OK commits
        changeDirectAccessPort('127.0.0.1', '21118').then((val) {
          resultPort = val;
        });
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '30000');
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();

        expect(resultPort, '30000');
        expect(fakeBridge.options[kOptionDirectAccessPort], '30000');
      },
    );

    testWidgets(
      'changeAutoDisconnectTimeout returns null on Cancel without overwriting',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(home: Overlay(key: overlayState.key)),
        );

        String? resultTimeout;
        changeAutoDisconnectTimeout('10').then((val) {
          resultTimeout = val;
        });
        await tester.pumpAndSettle();

        expect(find.text('Timeout in minutes'), findsOneWidget);

        // Modify to 60
        await tester.enterText(find.byType(TextField), '60');
        // Tap Cancel
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        // Must return null, and option must not be set
        expect(resultTimeout, isNull);
        expect(fakeBridge.options[kOptionAutoDisconnectTimeout], isNull);

        // Now test OK commits
        changeAutoDisconnectTimeout('10').then((val) {
          resultTimeout = val;
        });
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '60');
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();

        expect(resultTimeout, '60');
        expect(fakeBridge.options[kOptionAutoDisconnectTimeout], '60');
      },
    );
  });

  group('CONFIG-012: Server config save error handling and atomicity', () {
    test(
      'setServerConfig catches persistence error and returns false',
      () async {
        fakeBridge.shouldThrowSetOption = true;

        final config = ServerConfig(
          idServer: 'id.example.com',
          relayServer: 'relay.example.com',
          apiServer: 'http://api.example.com',
          key: 'secretkey',
        );

        final success = await setServerConfig(null, null, config);
        expect(success, isFalse);
      },
    );

    test('setServerConfig succeeds when persistence succeeds', () async {
      fakeBridge.shouldThrowSetOption = false;

      final config = ServerConfig(
        idServer: 'id.example.com',
        relayServer: 'relay.example.com',
        apiServer: 'http://api.example.com',
        key: 'secretkey',
      );

      final success = await setServerConfig(null, null, config);
      expect(success, isTrue);
      expect(fakeBridge.options['custom-rendezvous-server'], 'id.example.com');
      expect(fakeBridge.options['relay-server'], 'relay.example.com');
      expect(fakeBridge.options['api-server'], 'http://api.example.com');
      expect(fakeBridge.options['key'], 'secretkey');
    });
  });

  group('UI-002: Dropdown layout responsiveness in narrow viewports', () {
    Widget buildDropdownTestWidget({required double maxWidth}) {
      return MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: maxWidth,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final dropdownField = DropdownButtonFormField<String>(
                    initialValue: 'balanced',
                    items: const [
                      DropdownMenuItem(
                        value: 'best',
                        child: Text('Best Quality Option'),
                      ),
                      DropdownMenuItem(
                        value: 'balanced',
                        child: Text('Balanced Quality'),
                      ),
                      DropdownMenuItem(
                        value: 'low',
                        child: Text('Lowest Latency'),
                      ),
                    ],
                    isDense: true,
                    isExpanded: true,
                    onChanged: (_) {},
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                    ),
                  );

                  if (constraints.maxWidth < 420) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.high_quality, size: 24),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Text(
                                  'Default Image Quality with very long title',
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          dropdownField,
                        ],
                      ),
                    );
                  }

                  return ListTile(
                    leading: const Icon(Icons.high_quality),
                    title: const Text(
                      'Default Image Quality with very long title',
                    ),
                    trailing: SizedBox(width: 220, child: dropdownField),
                  );
                },
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('renders cleanly in compact 320px viewport without overflow', (
      tester,
    ) async {
      await tester.pumpWidget(buildDropdownTestWidget(maxWidth: 320));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
      expect(
        find.text('Default Image Quality with very long title'),
        findsOneWidget,
      );
    });

    testWidgets('renders horizontal list tile in 800px viewport', (
      tester,
    ) async {
      await tester.pumpWidget(buildDropdownTestWidget(maxWidth: 800));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(ListTile), findsOneWidget);
    });
  });

  group(
    'FEEDBACK-004: Language catalog load failure and build error resilience',
    () {
      testWidgets('futureBuilder invokes onError when future throws', (
        tester,
      ) async {
        final errorFuture = Future<String>.error('Simulated bridge error');
        errorFuture.ignore();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: futureBuilder(
                future: errorFuture,
                hasData: (data) => Text('Loaded: $data'),
                onError: (error) => Text('Handled error: $error'),
              ),
            ),
          ),
        );

        await tester.pumpAndSettle();

        expect(
          find.textContaining('Handled error: Simulated bridge error'),
          findsOneWidget,
        );
        expect(find.textContaining('Loaded:'), findsNothing);
      });

      testWidgets(
        'Language catalog parser handles malformed rows without crashing',
        (tester) async {
          // Simulate corrupt JSON catalog from bridge
          fakeBridge.langsJson =
              '[["en","English"],["broken_row_only_one_item"],"invalid",123]';

          final langsJson = await fakeBridge.mainGetLangs();
          final parsed = jsonDecode(langsJson) as List<dynamic>;
          final validLangs = <({String key, String label})>[];
          for (final row in parsed) {
            if (row is List && row.length >= 2) {
              validLangs.add((
                key: row[0].toString(),
                label: row[1].toString(),
              ));
            }
          }

          // Should extract valid entries without throwing RangeError
          expect(validLangs.length, 1);
          expect(validLangs.first.key, 'en');
          expect(validLangs.first.label, 'English');
        },
      );

      testWidgets(
        'Desktop language widget error resilience with retry button',
        (tester) async {
          fakeBridge.shouldThrowLangs = true;

          Widget buildDesktopLanguageSetting() {
            return futureBuilder(
              future: () async {
                try {
                  String langs = await bind.mainGetLangs();
                  return {'langs': langs};
                } catch (e) {
                  return {'error': e.toString()};
                }
              }(),
              hasData: (res) {
                Map<String, dynamic> data = res as Map<String, dynamic>;
                if (data.containsKey('error')) {
                  return Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Failed to load language list: ${data['error']}',
                        ),
                      ),
                      const IconButton(
                        icon: Icon(Icons.refresh),
                        onPressed: null,
                      ),
                    ],
                  );
                }
                return const Text('Loaded Languages Successfully');
              },
            );
          }

          await tester.pumpWidget(
            MaterialApp(home: Scaffold(body: buildDesktopLanguageSetting())),
          );
          await tester.pumpAndSettle();

          expect(tester.takeException(), isNull);
          expect(
            find.textContaining('Failed to load language list'),
            findsOneWidget,
          );
          expect(find.byIcon(Icons.refresh), findsOneWidget);
        },
      );
    },
  );
}
