import assert from 'node:assert/strict';
import test from 'node:test';

import { WebRuntime } from '../src/runtime/runtime.ts';
import { checkWsEndpoint, parseServerEndpoint } from '../src/runtime/rendezvous.ts';
import type { SessionContext } from '../src/runtime/types.ts';

// -----------------------------------------------------------------------------
// Test environment setup for WebRuntime
// -----------------------------------------------------------------------------

function createTestRuntime(envOverrides: Record<string, string> = {}): WebRuntime {
  const storageMap = new Map<string, string>();
  (globalThis as any).self = globalThis;
  (globalThis as any).window = {
    __CAMELLIA_REMOTE_WEB__: {},
    localStorage: {
      getItem(k: string) {
        return storageMap.has(k) ? storageMap.get(k)! : null;
      },
      setItem(k: string, v: string) {
        storageMap.set(k, String(v));
      },
      removeItem(k: string) {
        storageMap.delete(k);
      },
      clear() {
        storageMap.clear();
      }
    },
    location: {
      protocol: 'https:',
      hostname: 'remote.example.com',
      port: '8443'
    },
    addEventListener: () => {},
    removeEventListener: () => {}
  };
  (globalThis as any).document = {
    visibilityState: 'visible',
    addEventListener: () => {},
    removeEventListener: () => {}
  };
  try {
    Object.defineProperty(globalThis, 'navigator', {
      value: { userAgent: 'Node-Test-Agent', platform: 'Linux' },
      configurable: true,
      writable: true
    });
  } catch {
    // noop
  }

  const runtime = new WebRuntime({
    appName: 'Camellia',
    version: '1.0.0',
    buildDate: '2026-11-11',
    apiServer: 'https://api.example.com',
    isPublicServer: false,
    rendezvousServers: [],
    relayServers: [],
    env: {
      DEFAULT_ID_PORT: '21116',
      ...envOverrides
    },
    profile: { id: '999888777', name: 'Test User' },
    langs: []
  });

  return runtime;
}

// -----------------------------------------------------------------------------
// COMPAT-008: parseServerInput & parseServerEndpoint Invariants
// -----------------------------------------------------------------------------

test('COMPAT-008: parseServerInput parses and preserves custom path and query on WSS and WS', () => {
  const runtime = createTestRuntime();

  // Standard WSS with custom path and tenant query
  const res1 = runtime.parseServerInput('wss://remote.example.com:8443/custom-id?tenant=one');
  assert.ok(res1);
  assert.strictEqual(res1.scheme, 'wss');
  assert.strictEqual(res1.host, 'remote.example.com');
  assert.strictEqual(res1.port, 8443);
  assert.strictEqual(res1.path, '/custom-id');
  assert.strictEqual(res1.query, 'tenant=one');
  assert.strictEqual(res1.isIpv6, false);

  // IPv6 bracketed address with custom path and query
  const res2 = runtime.parseServerInput('wss://[2001:db8::1]:8443/custom-id?tenant=one&region=us');
  assert.ok(res2);
  assert.strictEqual(res2.scheme, 'wss');
  assert.strictEqual(res2.host, '2001:db8::1');
  assert.strictEqual(res2.port, 8443);
  assert.strictEqual(res2.path, '/custom-id');
  assert.strictEqual(res2.query, 'tenant=one&region=us');
  assert.strictEqual(res2.isIpv6, true);

  // Explicit port 443 with query
  const res3 = runtime.parseServerInput('wss://remote.example.com:443/custom-id?tenant=alpha');
  assert.ok(res3);
  assert.strictEqual(res3.port, 443);
  assert.strictEqual(res3.path, '/custom-id');
  assert.strictEqual(res3.query, 'tenant=alpha');

  // URL without path or query
  const res4 = runtime.parseServerInput('wss://remote.example.com:8443');
  assert.ok(res4);
  assert.strictEqual(res4.path, '');
  assert.strictEqual(res4.query, '');

  // URL with root path '/' only
  const res5 = runtime.parseServerInput('wss://remote.example.com:8443/');
  assert.ok(res5);
  assert.strictEqual(res5.path, '');
  assert.strictEqual(res5.query, '');

  // URL with query only (no custom path)
  const res6 = runtime.parseServerInput('wss://remote.example.com:8443/?tenant=one');
  assert.ok(res6);
  assert.strictEqual(res6.path, '');
  assert.strictEqual(res6.query, 'tenant=one');

  // WS endpoint with custom path and query
  const res7 = runtime.parseServerInput('ws://remote.example.com:21118/ws/id?tenant=beta');
  assert.ok(res7);
  assert.strictEqual(res7.scheme, 'ws');
  assert.strictEqual(res7.path, '/ws/id');
  assert.strictEqual(res7.query, 'tenant=beta');

  // Bare native endpoints (no scheme) have no path or query
  const res8 = runtime.parseServerInput('remote.example.com:21116');
  assert.ok(res8);
  assert.strictEqual(res8.scheme, null);
  assert.strictEqual(res8.host, 'remote.example.com');
  assert.strictEqual(res8.port, 21116);
  assert.strictEqual(res8.path, '');
  assert.strictEqual(res8.query, '');
});

test('COMPAT-008: parseServerInput rejects illegal userinfo, fragments, control characters, and bare paths', () => {
  const runtime = createTestRuntime();

  // Userinfo in URL
  assert.strictEqual(runtime.parseServerInput('wss://user:pass@remote.example.com:8443/id'), null);
  assert.strictEqual(runtime.parseServerInput('wss://user@remote.example.com:8443/id'), null);
  assert.strictEqual(runtime.parseServerInput('wss://@remote.example.com:8443/id'), null);
  assert.strictEqual(runtime.parseServerInput('user@remote.example.com:21116'), null);

  // Fragments in URL
  assert.strictEqual(runtime.parseServerInput('wss://remote.example.com:8443/id#section'), null);
  assert.strictEqual(runtime.parseServerInput('wss://remote.example.com:8443/id#'), null);
  assert.strictEqual(runtime.parseServerInput('remote.example.com:21116#frag'), null);

  // Control characters (ASCII 0-31 and 127)
  assert.strictEqual(runtime.parseServerInput('wss://remote.example.com:8443/id\x00'), null);
  assert.strictEqual(runtime.parseServerInput('wss://remote.example.com:8443/id\x1f'), null);
  assert.strictEqual(runtime.parseServerInput('wss://remote.example.com:8443/id\x7f'), null);
  assert.strictEqual(runtime.parseServerInput('wss://remote.example.com:8443/i\x01d'), null);
  assert.strictEqual(runtime.parseServerInput('remote.example.com:21116\x00'), null);

  // Internal whitespace
  assert.strictEqual(runtime.parseServerInput('wss://remote.example.com:8443/custom id'), null);
  assert.strictEqual(runtime.parseServerInput('wss://remote.example.com:8443/custom\tid'), null);

  // Bare endpoints with path, query, or illegal characters
  assert.strictEqual(runtime.parseServerInput('remote.example.com:21116/path'), null);
  assert.strictEqual(runtime.parseServerInput('remote.example.com/path'), null);
  assert.strictEqual(runtime.parseServerInput('remote.example.com?query'), null);

  // Invalid schemes
  assert.strictEqual(runtime.parseServerInput('http://remote.example.com:8443'), null);
  assert.strictEqual(runtime.parseServerInput('https://remote.example.com:8443'), null);
  assert.strictEqual(runtime.parseServerInput('ftp://remote.example.com:8443'), null);

  // Invalid ports
  assert.strictEqual(runtime.parseServerInput('wss://remote.example.com:0/id'), null);
  assert.strictEqual(runtime.parseServerInput('wss://remote.example.com:65536/id'), null);
  assert.strictEqual(runtime.parseServerInput('wss://remote.example.com:-1/id'), null);
  assert.strictEqual(runtime.parseServerInput('wss://remote.example.com:abc/id'), null);
  assert.strictEqual(runtime.parseServerInput('remote.example.com:0'), null);
  assert.strictEqual(runtime.parseServerInput('remote.example.com:70000'), null);
});

test('COMPAT-008: parseServerEndpoint matches parsing contract', () => {
  // rendezvous.ts parseServerEndpoint matches the shared schema
  const parsed = parseServerEndpoint('wss://remote.example.com:8443/custom-id?tenant=one');
  assert.ok(parsed);
  assert.strictEqual(parsed.scheme, 'wss');
  assert.strictEqual(parsed.host, 'remote.example.com');
  assert.strictEqual(parsed.port, 8443);
  assert.strictEqual(parsed.path, '/custom-id');
  assert.strictEqual(parsed.query, 'tenant=one');

  // Rejection of userinfo and control characters
  assert.strictEqual(parseServerEndpoint('wss://user:pass@host:8443/id'), null);
  assert.strictEqual(parseServerEndpoint('wss://host:8443/id#frag'), null);
  assert.strictEqual(parseServerEndpoint('wss://host:8443/id\x00'), null);
  assert.strictEqual(parseServerEndpoint('host:21116/path'), null);
});

// -----------------------------------------------------------------------------
// COMPAT-008: normalizeRendezvousServer & normalizeRelayServer
// -----------------------------------------------------------------------------

test('COMPAT-008: normalizeRendezvousServer preserves custom path and query; defaults when absent', () => {
  const runtime = createTestRuntime();

  // Custom path and query preserved
  const norm1 = runtime.normalizeRendezvousServer(
    'wss://remote.example.com:8443/custom-id?tenant=one'
  );
  assert.strictEqual(norm1, 'wss://remote.example.com:8443/custom-id?tenant=one');

  // IPv6 bracketed host preserved with path and query
  const norm2 = runtime.normalizeRendezvousServer(
    'wss://[2001:db8::1]:8443/custom-id?tenant=one'
  );
  assert.strictEqual(norm2, 'wss://[2001:db8::1]:8443/custom-id?tenant=one');

  // Absent path defaults to /ws/id on WSS
  const norm3 = runtime.normalizeRendezvousServer('wss://remote.example.com:8443');
  assert.strictEqual(norm3, 'wss://remote.example.com:8443/ws/id');

  // Root path '/' defaults to /ws/id on WSS
  const norm4 = runtime.normalizeRendezvousServer('wss://remote.example.com:8443/');
  assert.strictEqual(norm4, 'wss://remote.example.com:8443/ws/id');

  // Absent path with query defaults path to /ws/id and keeps query
  const norm5 = runtime.normalizeRendezvousServer(
    'wss://remote.example.com:8443?tenant=one'
  );
  assert.strictEqual(norm5, 'wss://remote.example.com:8443/ws/id?tenant=one');

  // Native endpoint defaults to DEFAULT_ID_PORT (21116)
  const norm6 = runtime.normalizeRendezvousServer('id.example.com');
  assert.strictEqual(norm6, 'id.example.com:21116');

  // Native endpoint with explicit port
  const norm7 = runtime.normalizeRendezvousServer('id.example.com:25000');
  assert.strictEqual(norm7, 'id.example.com:25000');

  // Illegal endpoints return empty string
  assert.strictEqual(runtime.normalizeRendezvousServer('https://id.example.com'), '');
  assert.strictEqual(runtime.normalizeRendezvousServer('wss://user:pass@id.example.com'), '');
  assert.strictEqual(runtime.normalizeRendezvousServer('id.example.com/path'), '');
});

test('COMPAT-008: normalizeRelayServer preserves custom path and query; defaults when absent', () => {
  const runtime = createTestRuntime();

  // Custom path and query preserved on explicit relay
  const norm1 = runtime.normalizeRelayServer(
    'wss://relay.example.com:9443/custom-relay?tenant=one',
    '',
    'wss://remote.example.com:8443/custom-id?tenant=one'
  );
  assert.strictEqual(norm1, 'wss://relay.example.com:9443/custom-relay?tenant=one');

  // Absent path defaults to /ws/relay on WSS
  const norm2 = runtime.normalizeRelayServer(
    'wss://relay.example.com:9443',
    '',
    'wss://remote.example.com:8443/custom-id?tenant=one'
  );
  assert.strictEqual(norm2, 'wss://relay.example.com:9443/ws/relay');

  // Absent path with query defaults path to /ws/relay and keeps query
  const norm3 = runtime.normalizeRelayServer(
    'wss://relay.example.com:9443?tenant=one',
    '',
    'wss://remote.example.com:8443/custom-id?tenant=one'
  );
  assert.strictEqual(norm3, 'wss://relay.example.com:9443/ws/relay?tenant=one');

  // Fallback to rendezvous port when relay has no explicit port and fallback is WSS
  const norm4 = runtime.normalizeRelayServer(
    'wss://relay.example.com',
    '',
    'wss://remote.example.com:8443/custom-id?tenant=one'
  );
  assert.strictEqual(norm4, 'wss://relay.example.com:8443/ws/relay');

  // Native relay uses default service relay port (21117)
  const norm5 = runtime.normalizeRelayServer('relay.example.com', '', 'id.example.com:21116');
  assert.strictEqual(norm5, 'relay.example.com:21117');
});

test('COMPAT-008: deriveRelayServer maps WSS to /ws/relay sharing TLS port and query routing', () => {
  const runtime = createTestRuntime();

  // Derived relay from custom rendezvous retains HTTPS port and query routing, with path /ws/relay
  const derived1 = runtime.deriveRelayServer(
    'wss://remote.example.com:8443/custom-id?tenant=one'
  );
  assert.strictEqual(derived1, 'wss://remote.example.com:8443/ws/relay?tenant=one');

  // Derived relay from native rendezvous increments port by 1
  const derived2 = runtime.deriveRelayServer('id.example.com:21116');
  assert.strictEqual(derived2, 'id.example.com:21117');
});

// -----------------------------------------------------------------------------
// COMPAT-008: Candidate Building & Round-Robin Preservation
// -----------------------------------------------------------------------------

test('COMPAT-008: getRendezvousCandidatesForConnect and buildConnectionCandidates preserve full path and query', () => {
  const customRendezvous = 'wss://remote.example.com:8443/custom-id?tenant=one';
  const customRelay = 'wss://relay.example.com:9443/custom-relay?tenant=one';

  const runtime = createTestRuntime({
    RENDEZVOUS_SERVERS: customRendezvous,
    RELAY_SERVER: customRelay
  });

  const baseContext: SessionContext = {
    rendezvousServer: customRendezvous,
    relayServer: customRelay,
    defaultIdPort: 21116,
    apiServer: 'https://api.example.com',
    key: 'test-key',
    token: '',
    myId: '123456789',
    myName: 'Test Node',
    version: '1.0.0',
    buildDate: '2026-11-11',
    platform: 'Web',
    imageQuality: 'balanced',
    customImageQuality: 70,
    customFps: 30,
    codecPreference: 'auto',
    preferI444: false,
    policy: {
      viewOnly: false,
      disableAudio: true,
      disableClipboard: false,
      disableFileTransfer: false,
      disableKeyboard: false,
      disableMouse: false
    }
  };

  const candidates = runtime.buildConnectionCandidates(baseContext);
  assert.ok(candidates.length > 0);

  // Primary candidate must strictly preserve full custom path and query
  const primary = candidates[0];
  assert.strictEqual(primary.rendezvousServer, 'wss://remote.example.com:8443/custom-id?tenant=one');
  assert.strictEqual(primary.relayServer, 'wss://relay.example.com:9443/custom-relay?tenant=one');

  // checkWsEndpoint called on primary candidate produces byte-for-byte identical URL
  const wsEndpoint = checkWsEndpoint(
    primary.rendezvousServer,
    primary.relayServer,
    baseContext.apiServer,
    'rendezvous',
    primary.rendezvousServer,
    baseContext.defaultIdPort
  );
  assert.strictEqual(wsEndpoint, 'wss://remote.example.com:8443/custom-id?tenant=one');

  const wsRelayEndpoint = checkWsEndpoint(
    primary.relayServer,
    primary.relayServer,
    baseContext.apiServer,
    'relay',
    primary.rendezvousServer,
    baseContext.defaultIdPort
  );
  assert.strictEqual(wsRelayEndpoint, 'wss://relay.example.com:9443/custom-relay?tenant=one');
});

// -----------------------------------------------------------------------------
// COMPAT-008: checkWsEndpoint Validation and Fail-Closed Boundaries
// -----------------------------------------------------------------------------

test('COMPAT-008: checkWsEndpoint preserves valid custom paths and queries; rejects invalid characters', () => {
  const defaultPort = 21116;

  // Valid custom path and query
  assert.strictEqual(
    checkWsEndpoint(
      'wss://remote.example.com:8443/custom-id?tenant=one',
      '',
      '',
      'rendezvous',
      '',
      defaultPort
    ),
    'wss://remote.example.com:8443/custom-id?tenant=one'
  );

  // Absent path defaulted to /ws/id for rendezvous
  assert.strictEqual(
    checkWsEndpoint(
      'wss://remote.example.com:8443',
      '',
      '',
      'rendezvous',
      '',
      defaultPort
    ),
    'wss://remote.example.com:8443/ws/id'
  );

  // Absent path defaulted to /ws/relay for relay
  assert.strictEqual(
    checkWsEndpoint(
      'wss://remote.example.com:8443',
      '',
      '',
      'relay',
      '',
      defaultPort
    ),
    'wss://remote.example.com:8443/ws/relay'
  );

  // Disallow userinfo
  assert.strictEqual(
    checkWsEndpoint('wss://user:pass@host:8443/id', '', '', 'rendezvous', '', defaultPort),
    ''
  );
  assert.strictEqual(
    checkWsEndpoint('wss://user@host:8443/id', '', '', 'rendezvous', '', defaultPort),
    ''
  );

  // Disallow fragments
  assert.strictEqual(
    checkWsEndpoint('wss://host:8443/id#frag', '', '', 'rendezvous', '', defaultPort),
    ''
  );

  // Disallow control characters
  assert.strictEqual(
    checkWsEndpoint('wss://host:8443/id\x00', '', '', 'rendezvous', '', defaultPort),
    ''
  );
  assert.strictEqual(
    checkWsEndpoint('wss://host:8443/id\x1f', '', '', 'rendezvous', '', defaultPort),
    ''
  );
  assert.strictEqual(
    checkWsEndpoint('wss://host:8443/id\x7f', '', '', 'rendezvous', '', defaultPort),
    ''
  );
  assert.strictEqual(
    checkWsEndpoint('wss://host:8443/id\x80', '', '', 'rendezvous', '', defaultPort),
    ''
  );
  assert.strictEqual(
    checkWsEndpoint('wss://host:8443/id\x9f', '', '', 'rendezvous', '', defaultPort),
    ''
  );

  // Disallow bare path or query
  assert.strictEqual(
    checkWsEndpoint('host:21116/path', '', '', 'rendezvous', '', defaultPort),
    ''
  );
  assert.strictEqual(
    checkWsEndpoint('host:21116?query', '', '', 'rendezvous', '', defaultPort),
    ''
  );

  // Disallow port 0 and out-of-range ports
  assert.strictEqual(
    checkWsEndpoint('wss://host:0/id', '', '', 'rendezvous', '', defaultPort),
    ''
  );
  assert.strictEqual(
    checkWsEndpoint('ws://host:0/id', '', '', 'rendezvous', '', defaultPort),
    ''
  );
  assert.strictEqual(
    checkWsEndpoint('host:0', '', '', 'rendezvous', '', defaultPort),
    ''
  );
  assert.strictEqual(
    checkWsEndpoint('host:99999', '', '', 'rendezvous', '', defaultPort),
    ''
  );
  assert.strictEqual(
    checkWsEndpoint('[::1', '', '', 'rendezvous', '', defaultPort),
    ''
  );
});
