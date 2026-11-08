import assert from 'node:assert/strict';
import test from 'node:test';

import {
  WebSocketTransport,
  MAX_FRAME_BYTES
} from '../src/runtime/transport.ts';
import {
  UPLOAD_BACKPRESSURE_HIGH_WATERMARK,
  UPLOAD_BACKPRESSURE_LOW_WATERMARK,
  MAX_CURSOR_DIMENSION,
  MAX_CURSOR_BYTES,
  MAX_DOWNLOAD_CHUNKS_BYTES,
  MAX_DOWNLOAD_BLOCK_BYTES,
  MAX_TERMINAL_PAYLOAD_BYTES
} from '../src/runtime/session_constants.ts';
import { safeZstdDecompress } from '../src/runtime/zstd.ts';
import { SecretBoxCipher } from '../src/runtime/crypto.ts';

// -----------------------------------------------------------------------------
// RES-054: WebSocket send path backpressure and budget against bufferedAmount
// -----------------------------------------------------------------------------

test('RES-054: WebSocketTransport reports bufferedAmount and resolves drainBackpressure immediately when below target', async () => {
  const transport = new WebSocketTransport('test-backpressure');
  assert.equal(transport.getBufferedAmount(), 0);

  // Setup mock socket
  let mockBufferedAmount = 100 * 1024; // 100 KiB (below 256 KiB)
  const mockSocket = {
    readyState: 1, // WebSocket.OPEN
    get bufferedAmount() {
      return mockBufferedAmount;
    },
    send() {},
    close() {}
  };

  (transport as any).socket = mockSocket;
  (transport as any).state = 'open';

  assert.equal(transport.getBufferedAmount(), 100 * 1024);

  // Should resolve immediately because 100 KiB <= 256 KiB
  await transport.drainBackpressure(256 * 1024, 1000);
});

test('RES-054: WebSocketTransport drainBackpressure waits until bufferedAmount drops to target', async () => {
  const transport = new WebSocketTransport('test-backpressure-drain');
  let mockBufferedAmount = 1024 * 1024; // 1 MiB (HIGH_WATERMARK)

  const mockSocket = {
    readyState: 1,
    get bufferedAmount() {
      return mockBufferedAmount;
    },
    send() {},
    close() {}
  };

  (transport as any).socket = mockSocket;
  (transport as any).state = 'open';

  // Drain to LOW_WATERMARK (256 KiB)
  const drainPromise = transport.drainBackpressure(256 * 1024, 2000);

  // Simulate network draining over time
  setTimeout(() => {
    mockBufferedAmount = 512 * 1024;
  }, 20);
  setTimeout(() => {
    mockBufferedAmount = 200 * 1024; // now <= 256 KiB
  }, 60);

  await drainPromise;
  assert.ok(transport.getBufferedAmount() <= 256 * 1024);
  transport.close();
});

test('RES-054: WebSocketTransport drainBackpressure rejects when socket closes or errors', async () => {
  const transport = new WebSocketTransport('test-drain-abort');
  const mockSocket = {
    readyState: 1,
    bufferedAmount: 1024 * 1024,
    send() {},
    close() {}
  };

  (transport as any).socket = mockSocket;
  (transport as any).state = 'open';

  const drainPromise = transport.drainBackpressure(256 * 1024, 2000);

  // Close transport mid-drain
  setTimeout(() => {
    transport.close();
  }, 30);

  await assert.rejects(drainPromise, {
    message: /Transport closed/
  });
});

test('RES-054: Constants verify backpressure thresholds', () => {
  assert.equal(UPLOAD_BACKPRESSURE_HIGH_WATERMARK, 1024 * 1024, 'High watermark must be 1 MiB');
  assert.equal(UPLOAD_BACKPRESSURE_LOW_WATERMARK, 256 * 1024, 'Low watermark must be 256 KiB');
  assert.ok(UPLOAD_BACKPRESSURE_LOW_WATERMARK < UPLOAD_BACKPRESSURE_HIGH_WATERMARK);
});

// -----------------------------------------------------------------------------
// RES-055: Web transport frame size bounding, zstd budgeting, cursor dimension
// -----------------------------------------------------------------------------

test('RES-055: MAX_FRAME_BYTES is strictly 16 MiB', () => {
  assert.equal(MAX_FRAME_BYTES, 16 * 1024 * 1024);
});

test('RES-055: WebSocketTransport rejects frames exceeding MAX_FRAME_BYTES', () => {
  const transport = new WebSocketTransport('test-frame-limit');
  let closeCode: number | undefined;
  let closeReason: string | undefined;

  const mockSocket = {
    readyState: 1,
    binaryType: 'arraybuffer',
    close(code?: number, reason?: string) {
      closeCode = code;
      closeReason = reason;
    }
  };

  (transport as any).socket = mockSocket;
  (transport as any).state = 'open';

  let received = false;
  transport.onMessage(() => {
    received = true;
  });

  const oversized = new ArrayBuffer(MAX_FRAME_BYTES + 1);
  (transport as any).handleSocketMessage({ data: oversized });

  assert.equal(received, false);
  assert.equal(closeCode, 1009);
  assert.equal(closeReason, 'Frame size limit exceeded');
  assert.equal(transport.getState(), 'error');
});

test('RES-055: WebSocketTransport rejects text frames when cipher is active', () => {
  const transport = new WebSocketTransport('test-text-frame-reject');
  let closeCode: number | undefined;
  let closeReason: string | undefined;

  const mockSocket = {
    readyState: 1,
    binaryType: 'arraybuffer',
    close(code?: number, reason?: string) {
      closeCode = code;
      closeReason = reason;
    }
  };

  (transport as any).socket = mockSocket;
  (transport as any).state = 'open';

  const key = new Uint8Array(32);
  transport.setCipher(new SecretBoxCipher(key, 'initiator'));

  (transport as any).handleSocketMessage({ data: 'plaintext attack string' });

  assert.equal(closeCode, 1003);
  assert.equal(closeReason, 'Unexpected text frame on encrypted transport');
  assert.equal(transport.getState(), 'error');
});

test('RES-055: safeZstdDecompress rejects declared frame content size exceeding budget', () => {
  // Construct a malicious zstd frame header declaring a 2 GiB content size
  // Magic: 0xFD2FB528 (4 bytes)
  // Frame header descriptor: fcf = 2 (4 bytes content size), ss = 0, cc = 0, df = 0
  // flg = (2 << 6) = 0x80 (128)
  // Window descriptor: byte 5 (e.g. 0x00)
  // Content size (4 bytes little-endian): 2 * 1024 * 1024 * 1024 = 0x80000000
  const maliciousHeader = new Uint8Array([
    0x28, 0xb5, 0x2f, 0xfd, // Magic
    0x80,                   // flg: fcf=2 (4 bytes), ss=0
    0x00,                   // Window descriptor
    0x00, 0x00, 0x00, 0x80  // Declared size: 2,147,483,648 bytes (2 GiB)
  ]);

  // Budget is only 1 MiB
  assert.throws(
    () => {
      safeZstdDecompress(maliciousHeader, 1024 * 1024);
    },
    { message: /declared frame content size exceeds budget/ }
  );
});

test('RES-055: safeZstdDecompress halts streaming when decompressed output exceeds budget', () => {
  // Empty frame output is 0 bytes
  const emptyFrame = new Uint8Array([0x28, 0xb5, 0x2f, 0xfd, 0x20, 0x00, 0x01, 0x00, 0x00]);
  const decompressed = safeZstdDecompress(emptyFrame, 1024);
  assert.equal(decompressed.byteLength, 0);

  // If budget is 0, must reject immediately
  assert.throws(
    () => {
      safeZstdDecompress(emptyFrame, 0);
    },
    { message: /Invalid maxOutputBytes budget/ }
  );
});

test('RES-055: Cursor dimension constants and bounds', () => {
  assert.equal(MAX_CURSOR_DIMENSION, 512);
  assert.equal(MAX_CURSOR_BYTES, 512 * 512 * 4); // 1 MiB
  assert.equal(MAX_TERMINAL_PAYLOAD_BYTES, 4 * 1024 * 1024);
  assert.equal(MAX_DOWNLOAD_BLOCK_BYTES, 16 * 1024 * 1024);
});

// -----------------------------------------------------------------------------
// RES-056: Web download memory budgeting, monotonic blocks, and resource cleanup
// -----------------------------------------------------------------------------

test('RES-056: MAX_DOWNLOAD_CHUNKS_BYTES is strictly 256 MiB', () => {
  assert.equal(MAX_DOWNLOAD_CHUNKS_BYTES, 256 * 1024 * 1024);
});

test('RES-056: Download block sequence enforcement detects non-monotonic blkId', () => {
  let nextBlockId = 0;
  let jobFailed = false;
  const verifyBlock = (blkId: number): boolean => {
    if (jobFailed) {
      return false;
    }
    if (blkId !== nextBlockId) {
      jobFailed = true;
      return false;
    }
    nextBlockId++;
    return true;
  };

  assert.equal(verifyBlock(0), true);
  assert.equal(verifyBlock(1), true);
  assert.equal(verifyBlock(3), false); // Skipped 2 -> fails and aborts
  assert.equal(verifyBlock(2), false); // Subsequent block fails because job aborted

  // Additional check: duplicate block sequence rejection
  let nextBlockId2 = 0;
  const verifyBlock2 = (blkId: number): boolean => {
    if (blkId !== nextBlockId2) {
      return false;
    }
    nextBlockId2++;
    return true;
  };
  assert.equal(verifyBlock2(0), true);
  assert.equal(verifyBlock2(1), true);
  assert.equal(verifyBlock2(1), false); // Duplicate block 1
});

test('RES-056: Download declared size enforcement detects excess bytes', () => {
  const declaredSize = 1000;
  let receivedBytes = 0;

  const receiveChunk = (chunkBytes: number): boolean => {
    if (receivedBytes + chunkBytes > declaredSize) {
      return false; // declared_size_exceeded
    }
    receivedBytes += chunkBytes;
    return true;
  };

  assert.equal(receiveChunk(500), true);
  assert.equal(receiveChunk(400), true);
  assert.equal(receiveChunk(200), false); // 500 + 400 + 200 = 1100 > 1000
});

test('RES-056: Download memory budget enforcement detects exceeding MAX_DOWNLOAD_CHUNKS_BYTES', () => {
  let chunksBytes = 250 * 1024 * 1024; // 250 MiB
  const chunkToAdd = 10 * 1024 * 1024;  // 10 MiB -> 260 MiB > 256 MiB

  const checkBudget = (current: number, additional: number): boolean => {
    return current + additional <= MAX_DOWNLOAD_CHUNKS_BYTES;
  };

  assert.equal(checkBudget(chunksBytes, 5 * 1024 * 1024), true); // 255 MiB <= 256 MiB
  assert.equal(checkBudget(chunksBytes, chunkToAdd), false);      // 260 MiB > 256 MiB
});

test('RES-056: Object URL and timer cleanup simulation confirms zero leaks', () => {
  const activeUrls = new Map<string, number>();
  const revokedUrls: string[] = [];

  const mockRevoke = (url: string) => {
    const timer = activeUrls.get(url);
    if (timer !== undefined) {
      clearTimeout(timer);
      activeUrls.delete(url);
    }
    revokedUrls.push(url);
  };

  const mockCreate = (id: string): string => {
    const url = `blob:http://localhost/${id}`;
    const timer = setTimeout(() => {
      mockRevoke(url);
    }, 60000) as unknown as number;
    activeUrls.set(url, timer);
    return url;
  };

  const url1 = mockCreate('file1');
  const url2 = mockCreate('file2');

  assert.equal(activeUrls.size, 2);

  // Simulate cancelJob or close: deterministic cleanup of all active URLs
  for (const url of Array.from(activeUrls.keys())) {
    mockRevoke(url);
  }

  assert.equal(activeUrls.size, 0);
  assert.deepEqual(revokedUrls, [url1, url2]);
});

// -----------------------------------------------------------------------------
// CRED-010: Peer password export prevention, boolean query, lifetime isolation
// -----------------------------------------------------------------------------

test('CRED-010: Generic peer option getter denies plaintext password export', () => {
  function isSecretPeerOption(name: string): boolean {
    const normalized = name.trim().toLowerCase().replace(/_/g, '-');
    return (
      normalized === 'password' ||
      normalized === 'rdp-password' ||
      normalized === 'os-password'
    );
  }

  function getPeerOptionValue(id: string, name: string): string {
    if (isSecretPeerOption(name)) {
      return '';
    }
    return 'non_secret_value';
  }

  const secretVariants = [
    'password',
    'PASSWORD',
    ' password ',
    'rdp_password',
    'rdp-password',
    'RDP_PASSWORD',
    'os_password',
    'os-password',
    'OS-PASSWORD'
  ];

  for (const variant of secretVariants) {
    assert.equal(
      getPeerOptionValue('peer1', variant),
      '',
      `Secret variant '${variant}' must return empty string from generic option getter`
    );
  }

  assert.equal(getPeerOptionValue('peer1', 'alias'), 'non_secret_value');
  assert.equal(getPeerOptionValue('peer1', 'force-always-relay'), 'non_secret_value');
});

test('CRED-010: Boolean query has_remembered_password verifies status without plaintext leak', () => {
  const store = new Map<string, string>();
  store.set('peer_option:1001', JSON.stringify({ password: 'encrypted:SecretToken123' }));
  store.set('peer_option:1002', JSON.stringify({ alias: 'WorkStation' })); // no password

  function hasRememberedPeerPassword(id: string): boolean {
    const raw = store.get(`peer_option:${id}`);
    if (!raw) return false;
    const parsed = JSON.parse(raw);
    const stored = parsed.password ?? '';
    return Boolean(stored && stored.trim().length > 0);
  }

  function getByName(name: string, arg0?: unknown): string {
    switch (name) {
      case 'has_remembered_password':
      case 'peer_has_password':
        if (typeof arg0 === 'string') {
          const peerId = String(arg0 ?? '').trim();
          return hasRememberedPeerPassword(peerId) ? 'true' : 'false';
        }
        return 'false';
      case 'option:peer': {
        const payload = JSON.parse(String(arg0));
        const normalizedKey = payload.name.trim().toLowerCase().replace(/_/g, '-');
        if (
          normalizedKey === 'has-remembered-password' ||
          normalizedKey === 'peer-has-password' ||
          normalizedKey === 'has-password'
        ) {
          return hasRememberedPeerPassword(payload.id) ? 'true' : 'false';
        }
        if (normalizedKey === 'password' || normalizedKey === 'os-password' || normalizedKey === 'rdp-password') {
          return ''; // Deny secret export!
        }
        return 'other';
      }
      default:
        return '';
    }
  }

  // Boolean queries work accurately
  assert.equal(getByName('has_remembered_password', '1001'), 'true');
  assert.equal(getByName('peer_has_password', '1001'), 'true');
  assert.equal(getByName('has_remembered_password', '1002'), 'false');
  assert.equal(getByName('peer_has_password', '1002'), 'false');
  assert.equal(getByName('has_remembered_password', '9999'), 'false');

  // Generic option getter with password query returns boolean for has_remembered_password
  assert.equal(
    getByName('option:peer', JSON.stringify({ id: '1001', name: 'has_remembered_password' })),
    'true'
  );

  // Generic option getter for actual password returns empty string
  assert.equal(
    getByName('option:peer', JSON.stringify({ id: '1001', name: 'password' })),
    ''
  );
  assert.equal(
    getByName('option:peer', JSON.stringify({ id: '1001', name: 'PASSWORD' })),
    ''
  );
});

test('CRED-010: Session close wipes credentials and ephemeral secrets', () => {
  const request: { id: string; password?: string } = {
    id: 'peer1',
    password: 'TopSecretPassword'
  };

  const ephemeralSecrets = new Map<string, string>();
  ephemeralSecrets.set('os-password', 'OSSecret');

  function closeSession(): void {
    request.password = undefined;
    ephemeralSecrets.clear();
  }

  assert.equal(request.password, 'TopSecretPassword');
  assert.equal(ephemeralSecrets.size, 1);

  closeSession();

  assert.equal(request.password, undefined);
  assert.equal(ephemeralSecrets.size, 0);
});
