import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('COMPAT-008: WebSocket Proxy Path & Query Preservation Contracts', () {
    late Directory clientRoot;
    late File runtimeTs;
    late File rendezvousTs;
    late File webBridgePackageJson;

    setUpAll(() {
      if (Directory.current.path.endsWith('flutter')) {
        clientRoot = Directory.current.parent;
      } else {
        clientRoot = Directory.current;
      }

      runtimeTs = File(
        '${clientRoot.path}/flutter/web/js/src/runtime/runtime.ts',
      );
      rendezvousTs = File(
        '${clientRoot.path}/flutter/web/js/src/runtime/rendezvous.ts',
      );
      webBridgePackageJson = File(
        '${clientRoot.path}/flutter/web/js/package.json',
      );

      expect(runtimeTs.existsSync(), isTrue, reason: 'runtime.ts must exist');
      expect(
        rendezvousTs.existsSync(),
        isTrue,
        reason: 'rendezvous.ts must exist',
      );
      expect(
        webBridgePackageJson.existsSync(),
        isTrue,
        reason: 'package.json must exist',
      );
    });

    test('runtime.ts defines ParsedServerEndpoint with path and query', () {
      final content = runtimeTs.readAsStringSync();
      expect(
        content.contains('export interface ParsedServerEndpoint'),
        isTrue,
        reason: 'ParsedServerEndpoint interface must be exported',
      );
      expect(
        content.contains('path: string;'),
        isTrue,
        reason: 'ParsedServerEndpoint must include path field',
      );
      expect(
        content.contains('query: string;'),
        isTrue,
        reason: 'ParsedServerEndpoint must include query field',
      );
    });

    test('runtime.ts parseServerInput rejects illegal userinfo and fragments', () {
      final content = runtimeTs.readAsStringSync();
      expect(
        content.contains("raw.includes('#')"),
        isTrue,
        reason: 'parseServerInput must reject fragments',
      );
      expect(
        content.contains("authority.includes('@')"),
        isTrue,
        reason: 'parseServerInput must reject userinfo',
      );
      expect(
        content.contains("url.username || url.password"),
        isTrue,
        reason: 'parseServerInput must reject username and password',
      );
    });

    test('runtime.ts normalization functions preserve custom path and query', () {
      final content = runtimeTs.readAsStringSync();
      expect(
        content.contains('public normalizeRendezvousServer('),
        isTrue,
        reason: 'normalizeRendezvousServer must be public',
      );
      expect(
        content.contains('public normalizeRelayServer('),
        isTrue,
        reason: 'normalizeRelayServer must be public',
      );
      expect(
        content.contains('public deriveRelayServer('),
        isTrue,
        reason: 'deriveRelayServer must be public',
      );
      expect(
        content.contains("'/ws/relay'"),
        isTrue,
        reason: 'deriveRelayServer must route WSS to /ws/relay',
      );
    });

    test('runtime.ts candidate builders are public and retain candidate URLs', () {
      final content = runtimeTs.readAsStringSync();
      expect(
        content.contains('public buildConnectionCandidates('),
        isTrue,
        reason: 'buildConnectionCandidates must be public',
      );
      expect(
        content.contains('public getRendezvousCandidatesForConnect('),
        isTrue,
        reason: 'getRendezvousCandidatesForConnect must be public',
      );
    });

    test('rendezvous.ts checkWsEndpoint validates and preserves path and query', () {
      final content = rendezvousTs.readAsStringSync();
      expect(
        content.contains('export function checkWsEndpoint('),
        isTrue,
        reason: 'checkWsEndpoint must be exported',
      );
      expect(
        content.contains("authority.includes('@')"),
        isTrue,
        reason: 'checkWsEndpoint must reject authority userinfo',
      );
      expect(
        content.contains("hasExplicitPath ? url.pathname : ''"),
        isTrue,
        reason: 'checkWsEndpoint must preserve explicit pathname for ws',
      );
      expect(
        content.contains(
          "hasExplicitPath ? url.pathname : (routeKind === 'relay' ? '/ws/relay' : '/ws/id')",
        ),
        isTrue,
        reason: 'checkWsEndpoint must preserve explicit pathname for wss or default',
      );
    });

    test('package.json includes web_ws_proxy_path_batch63.test.ts in test suite', () {
      final content = webBridgePackageJson.readAsStringSync();
      expect(
        content.contains('test/web_ws_proxy_path_batch63.test.ts'),
        isTrue,
        reason: 'web_ws_proxy_path_batch63.test.ts must be part of test:security',
      );
    });

    test('Dart Uri parser parity on custom WebSocket proxy paths and queries', () {
      final uri = Uri.parse(
        'wss://remote.example.com:8443/custom-id?tenant=one&region=us-west',
      );
      expect(uri.scheme, equals('wss'));
      expect(uri.host, equals('remote.example.com'));
      expect(uri.port, equals(8443));
      expect(uri.path, equals('/custom-id'));
      expect(uri.query, equals('tenant=one&region=us-west'));
      expect(uri.queryParameters['tenant'], equals('one'));
      expect(uri.queryParameters['region'], equals('us-west'));

      final ipv6Uri = Uri.parse(
        'wss://[2001:db8::1]:8443/custom-id?tenant=one',
      );
      expect(ipv6Uri.scheme, equals('wss'));
      expect(ipv6Uri.host, equals('2001:db8::1'));
      expect(ipv6Uri.port, equals(8443));
      expect(ipv6Uri.path, equals('/custom-id'));
      expect(ipv6Uri.query, equals('tenant=one'));
    });

    test('Simulated endpoint normalization parity with Management and Client Web', () {
      String normalizeEndpoint(String input, {required String defaultPath}) {
        if (!input.contains('://')) return input;
        final uri = Uri.parse(input);
        if (uri.scheme != 'ws' && uri.scheme != 'wss') return '';
        if (uri.userInfo.isNotEmpty) return '';
        if (uri.hasFragment) return '';
        final path = uri.path.isNotEmpty && uri.path != '/'
            ? uri.path
            : defaultPath;
        final query = uri.hasQuery ? '?${uri.query}' : '';
        return '${uri.scheme}://${uri.host}:${uri.port}$path$query';
      }

      final normalizedRendezvous = normalizeEndpoint(
        'wss://remote.example.com:8443/custom-id?tenant=one',
        defaultPath: '/ws/id',
      );
      expect(
        normalizedRendezvous,
        equals('wss://remote.example.com:8443/custom-id?tenant=one'),
      );

      final normalizedRelay = normalizeEndpoint(
        'wss://relay.example.com:9443/custom-relay?tenant=one',
        defaultPath: '/ws/relay',
      );
      expect(
        normalizedRelay,
        equals('wss://relay.example.com:9443/custom-relay?tenant=one'),
      );

      final defaultRendezvous = normalizeEndpoint(
        'wss://remote.example.com:8443',
        defaultPath: '/ws/id',
      );
      expect(
        defaultRendezvous,
        equals('wss://remote.example.com:8443/ws/id'),
      );

      final defaultRelay = normalizeEndpoint(
        'wss://relay.example.com:9443',
        defaultPath: '/ws/relay',
      );
      expect(
        defaultRelay,
        equals('wss://relay.example.com:9443/ws/relay'),
      );

      final rejectedUserinfo = normalizeEndpoint(
        'wss://user:pass@remote.example.com:8443/custom-id',
        defaultPath: '/ws/id',
      );
      expect(rejectedUserinfo, equals(''));

      final rejectedFragment = normalizeEndpoint(
        'wss://remote.example.com:8443/custom-id#section',
        defaultPath: '/ws/id',
      );
      expect(rejectedFragment, equals(''));
    });
  });
}
