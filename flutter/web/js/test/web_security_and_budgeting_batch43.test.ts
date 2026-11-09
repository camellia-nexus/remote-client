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
// Test environment shims for real WebRuntime & WebSession bridge testing
// -----------------------------------------------------------------------------

let envInstance: {
  storageMap: Map<string, string>;
  createdUrls: string[];
  revokedUrls: string[];
} | null = null;

async function getTestBrowserEnvironment() {
  if (!envInstance) {
    const storageMap = new Map<string, string>();
    const createdUrls: string[] = [];
    const revokedUrls: string[] = [];

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
      addEventListener() {},
      removeEventListener() {},
      clearTimeout(t: unknown) {},
      setTimeout(fn: () => void, ms?: number) {
        return 12345;
      },
      setInterval(fn: () => void, ms?: number) {
        return 67890;
      },
      clearInterval() {},
      requestAnimationFrame(fn: () => void) {
        fn();
      }
    };
    try {
      Object.defineProperty(globalThis, 'navigator', {
        value: { userAgent: 'NodeTest', maxTouchPoints: 0 },
        configurable: true,
        writable: true
      });
    } catch {
      // noop
    }
    (globalThis as any).document = {
      body: { appendChild() {} },
      addEventListener() {},
      createElement() {
        return { style: {}, dispatchEvent() {}, click() {} };
      }
    };
    (globalThis as any).URL = {
      createObjectURL(blob: unknown) {
        const u = `blob:http://localhost/test-blob-${createdUrls.length + 1}`;
        createdUrls.push(u);
        return u;
      },
      revokeObjectURL(u: string) {
        revokedUrls.push(u);
      }
    };

    await import('../src/main.ts');
    envInstance = { storageMap, createdUrls, revokedUrls };
  } else {
    envInstance.storageMap.clear();
    envInstance.createdUrls.length = 0;
    envInstance.revokedUrls.length = 0;
  }
  return envInstance;
}

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

test('RES-055: WebSession handleCursorData validates width <= 512, height <= 512, and byteLength bounds', async () => {
  await getTestBrowserEnvironment();

  const win = (globalThis as any).window;
  win.setByName('session_add_sync', JSON.stringify({ id: 'peer-cursor-test' }));
  const runtime = win.__CAMELLIA_REMOTE_WEB_BRIDGE__.runtime;
  const session = runtime.currentSession;

  const cursorEvents: any[] = [];
  session.events.onEmit((evt: any) => {
    if (evt.name === 'cursor_data') cursorEvents.push(evt);
  });

  // Valid 16x16 cursor -> 16*16*4 = 1024 bytes -> accepted
  session.handleCursorData({
    id: 'c1',
    width: 16,
    height: 16,
    colors: new Uint8Array(1024)
  });
  assert.equal(cursorEvents.length, 1);
  assert.equal(cursorEvents[0].width, '16');
  assert.equal(cursorEvents[0].height, '16');

  // Oversized width 513 -> rejected
  session.handleCursorData({
    id: 'c2',
    width: 513,
    height: 16,
    colors: new Uint8Array(513 * 16 * 4)
  });
  assert.equal(cursorEvents.length, 1);

  // Oversized height 513 -> rejected
  session.handleCursorData({
    id: 'c3',
    width: 16,
    height: 513,
    colors: new Uint8Array(16 * 513 * 4)
  });
  assert.equal(cursorEvents.length, 1);

  // Mismatched buffer length (16x16 expects 1024, received 1025) -> rejected
  session.handleCursorData({
    id: 'c4',
    width: 16,
    height: 16,
    colors: new Uint8Array(1025)
  });
  assert.equal(cursorEvents.length, 1);

  session.close();
});

// -----------------------------------------------------------------------------
// RES-056: Web download memory budgeting, monotonic blocks, and resource cleanup
// -----------------------------------------------------------------------------

test('RES-056: MAX_DOWNLOAD_CHUNKS_BYTES is strictly 256 MiB', () => {
  assert.equal(MAX_DOWNLOAD_CHUNKS_BYTES, 256 * 1024 * 1024);
});

test('RES-056: Download block sequence enforcement detects non-monotonic blkId in real session', async () => {
  await getTestBrowserEnvironment();

  const win = (globalThis as any).window;
  win.setByName('session_add_sync', JSON.stringify({ id: 'peer-download-seq' }));
  const runtime = win.__CAMELLIA_REMOTE_WEB_BRIDGE__.runtime;
  const session = runtime.currentSession;

  session.proto = {
    messageType: {
      encode() { return { finish() { return new Uint8Array(); } }; },
      decode() { return {}; }
    }
  };
  session.peerInfoSnapshot.fileTransferProtocolVersion = 2;

  const events: any[] = [];
  session.events.onEmit((evt: any) => events.push(evt));

  session.requestDownload(10, '/remote/test.bin', false);
  session.handleFileResponse({
    dir: {
      id: 10,
      path: '/remote/test.bin',
      entries: [{ name: 'test.bin', size: 1000, entry_type: 1 }]
    }
  });

  // Block 0: blkId 0 -> accepted
  session.handleFileResponse({
    block: { id: 10, fileNum: 0, blkId: 0, data: new Uint8Array(100) }
  });
  assert.equal(session.downloadJobs.get(10).nextBlockId, 1);

  // Block skipped to blkId 2 -> non-monotonic sequence detected -> job terminated
  session.handleFileResponse({
    block: { id: 10, fileNum: 0, blkId: 2, data: new Uint8Array(100) }
  });

  const err = events.find((e) => e.name === 'job_error');
  assert.ok(err, 'Must emit job_error on non-monotonic block sequence');
  assert.equal(err.err, 'invalid_block_sequence');
  assert.equal(session.downloadJobs.has(10), false, 'Job must be cleaned up');

  session.close();
});

test('RES-056: Download declared size enforcement detects excess bytes in real session', async () => {
  await getTestBrowserEnvironment();

  const win = (globalThis as any).window;
  win.setByName('session_add_sync', JSON.stringify({ id: 'peer-download-size' }));
  const runtime = win.__CAMELLIA_REMOTE_WEB_BRIDGE__.runtime;
  const session = runtime.currentSession;

  session.proto = {
    messageType: {
      encode() { return { finish() { return new Uint8Array(); } }; },
      decode() { return {}; }
    }
  };
  session.peerInfoSnapshot.fileTransferProtocolVersion = 2;

  const events: any[] = [];
  session.events.onEmit((evt: any) => events.push(evt));

  session.requestDownload(20, '/remote/small.bin', false);
  session.handleFileResponse({
    dir: {
      id: 20,
      path: '/remote/small.bin',
      entries: [{ name: 'small.bin', size: 100, entry_type: 1 }]
    }
  });

  // Block 0: 60 bytes <= 100 -> ok
  session.handleFileResponse({
    block: { id: 20, fileNum: 0, blkId: 0, data: new Uint8Array(60) }
  });

  // Block 1: 50 bytes -> total 110 > 100 declared -> error
  session.handleFileResponse({
    block: { id: 20, fileNum: 0, blkId: 1, data: new Uint8Array(50) }
  });

  const err = events.find((e) => e.name === 'job_error');
  assert.ok(err);
  assert.equal(err.err, 'declared_size_exceeded');
  assert.equal(session.downloadJobs.has(20), false);

  session.close();
});

test('RES-056: Download memory budget enforcement detects exceeding MAX_DOWNLOAD_CHUNKS_BYTES', async () => {
  await getTestBrowserEnvironment();

  const win = (globalThis as any).window;
  win.setByName('session_add_sync', JSON.stringify({ id: 'peer-download-budget' }));
  const runtime = win.__CAMELLIA_REMOTE_WEB_BRIDGE__.runtime;
  const session = runtime.currentSession;

  session.proto = {
    messageType: {
      encode() { return { finish() { return new Uint8Array(); } }; },
      decode() { return {}; }
    }
  };
  session.peerInfoSnapshot.fileTransferProtocolVersion = 2;

  const events: any[] = [];
  session.events.onEmit((evt: any) => events.push(evt));

  session.requestDownload(30, '/remote/huge.bin', false);
  const job = session.downloadJobs.get(30);
  assert.ok(job);

  // Set existing chunksBytes near limit: 255 MiB for file 0
  job.currentFileNum = 0;
  job.chunksBytes = 255 * 1024 * 1024;
  job.nextBlockId = 1;

  // Add a 2 MiB chunk -> 257 MiB > 256 MiB budget cap -> rejected
  session.handleFileResponse({
    block: { id: 30, fileNum: 0, blkId: 1, data: new Uint8Array(2 * 1024 * 1024) }
  });

  const err = events.find((e) => e.name === 'job_error');
  assert.ok(err);
  assert.equal(err.err, 'budget_exceeded');
  assert.equal(session.downloadJobs.has(30), false);

  session.close();
});

test('RES-056: Object URL remains valid after completeDownloadJob and is cleanly revoked on cancelJob & session close', async () => {
  const env = await getTestBrowserEnvironment();

  const win = (globalThis as any).window;
  win.setByName('session_add_sync', JSON.stringify({ id: 'peer-download-lifecycle' }));
  const runtime = win.__CAMELLIA_REMOTE_WEB_BRIDGE__.runtime;
  const session = runtime.currentSession;

  session.proto = {
    messageType: {
      encode() { return { finish() { return new Uint8Array(); } }; },
      decode() { return {}; }
    }
  };
  session.peerInfoSnapshot.fileTransferProtocolVersion = 2;

  // 1. Download job 40 finishes normally
  session.requestDownload(40, '/remote/completed.txt', false);
  session.handleFileResponse({
    dir: {
      id: 40,
      path: '/remote/completed.txt',
      entries: [{ name: 'completed.txt', size: 100, entry_type: 1 }]
    }
  });
  session.handleFileResponse({
    block: { id: 40, fileNum: 0, blkId: 0, data: new Uint8Array(100) }
  });
  session.handleFileResponse({
    done: { id: 40, fileNum: 1 }
  });

  await new Promise((r) => setTimeout(r, 10));

  // The Object URL was created for download
  assert.equal(env.createdUrls.length, 1);
  const createdUrl = env.createdUrls[0];
  // Crucial fix: The URL must NOT be revoked immediately upon job completion!
  assert.equal(env.revokedUrls.length, 0, 'Object URL must stay alive for browser download');
  assert.equal(session.activeDownloadUrls.has(createdUrl), true);

  // 2. Download job 41 is in progress and gets cancelled via cancelJob(41)
  session.requestDownload(41, '/remote/cancelled.txt', false);
  session.handleFileResponse({
    dir: {
      id: 41,
      path: '/remote/cancelled.txt',
      entries: [{ name: 'cancelled.txt', size: 200, entry_type: 1 }]
    }
  });
  session.handleFileResponse({
    block: { id: 41, fileNum: 0, blkId: 0, data: new Uint8Array(200) }
  });

  // Manually attach a test URL to job 41 to test cancelJob cleanup
  const job41 = session.downloadJobs.get(41);
  const url41 = 'blob:http://localhost/job-41-partial';
  job41.createdUrls.push(url41);
  session.activeDownloadUrls.set(url41, 9999);

  session.cancelJob(41);
  assert.equal(session.downloadJobs.has(41), false);
  assert.ok(env.revokedUrls.includes(url41), 'cancelJob must immediately revoke job Object URLs');
  assert.equal(session.activeDownloadUrls.has(url41), false);

  // 3. cancelJob when proto is uninitialized still cleans up local job and URLs
  session.proto = undefined;
  session.downloadJobs.set(42, {
    token: Symbol(),
    id: 42,
    remotePath: '/remote/uninit.txt',
    files: [],
    currentFileNum: 0,
    chunks: [new Uint8Array(50)],
    chunksBytes: 50,
    currentFileReceivedBytes: 50,
    nextBlockId: 1,
    receivedBytes: 50,
    totalSize: 100,
    startTime: Date.now(),
    lastProgressTime: Date.now(),
    lastProgressBytes: 0,
    cancelled: false,
    createdUrls: ['blob:http://localhost/job-42-uninit']
  });
  session.activeDownloadUrls.set('blob:http://localhost/job-42-uninit', 8888);

  session.cancelJob(42);
  assert.equal(session.downloadJobs.has(42), false);
  assert.ok(env.revokedUrls.includes('blob:http://localhost/job-42-uninit'));

  // 4. Session close cleans up all remaining active download URLs
  session.close();
  assert.ok(env.revokedUrls.includes(createdUrl), 'session close must revoke all remaining active URLs');
  assert.equal(session.activeDownloadUrls.size, 0);
});

// -----------------------------------------------------------------------------
// CRED-010: Peer password export prevention, boolean query, lifetime isolation
// -----------------------------------------------------------------------------

test('CRED-010: Generic peer option getter denies plaintext password export in real runtime', async () => {
  await getTestBrowserEnvironment();

  const win = (globalThis as any).window;

  // Save peer credentials
  win.setByName(
    'option:peer',
    JSON.stringify({ id: 'peer-cred-1', name: 'password', value: 'SuperSecretToken99' })
  );
  win.setByName(
    'option:peer',
    JSON.stringify({ id: 'peer-cred-1', name: 'alias', value: 'ProductionServer' })
  );

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
    const exported = win.getByName(
      'option:peer',
      JSON.stringify({ id: 'peer-cred-1', name: variant })
    );
    assert.equal(
      exported,
      '',
      `Secret variant '${variant}' must return empty string from generic option getter`
    );
  }

  // Non-secret options remain readable
  assert.equal(
    win.getByName('option:peer', JSON.stringify({ id: 'peer-cred-1', name: 'alias' })),
    'ProductionServer'
  );

  // Scoped option getter also denies secret keys
  assert.equal(win.getByName('option:flutter:peer', 'password'), '');
  assert.equal(win.getByName('option:session', 'os-password'), '');
});

test('CRED-010: Boolean query has_remembered_password verifies status without plaintext leak for string and numeric IDs', async () => {
  await getTestBrowserEnvironment();

  const win = (globalThis as any).window;

  // Peer 1001: has password
  win.setByName(
    'option:peer',
    JSON.stringify({ id: '1001', name: 'password', value: 'TopSecret1001' })
  );
  // Peer 1002: has only alias (no password)
  win.setByName(
    'option:peer',
    JSON.stringify({ id: '1002', name: 'alias', value: 'WorkStation' })
  );

  // Boolean queries work accurately with string ID
  assert.equal(win.getByName('has_remembered_password', '1001'), 'true');
  assert.equal(win.getByName('peer_has_password', '1001'), 'true');
  assert.equal(win.getByName('has_remembered_password', '1002'), 'false');
  assert.equal(win.getByName('peer_has_password', '1002'), 'false');
  assert.equal(win.getByName('has_remembered_password', '9999'), 'false');

  // Boolean queries work accurately with numeric ID (crucial fix for non-string arg0)
  assert.equal(win.getByName('has_remembered_password', 1001), 'true');
  assert.equal(win.getByName('peer_has_password', 1001), 'true');
  assert.equal(win.getByName('has_remembered_password', 1002), 'false');

  // option:peer getter with has_remembered_password query returns boolean
  assert.equal(
    win.getByName('option:peer', JSON.stringify({ id: '1001', name: 'has_remembered_password' })),
    'true'
  );
  assert.equal(
    win.getByName('option:peer', JSON.stringify({ id: '1002', name: 'has_remembered_password' })),
    'false'
  );

  // option:peer getter for actual password returns empty string
  assert.equal(
    win.getByName('option:peer', JSON.stringify({ id: '1001', name: 'password' })),
    ''
  );
  assert.equal(
    win.getByName('option:peer', JSON.stringify({ id: '1001', name: 'PASSWORD' })),
    ''
  );
});

test('CRED-010: Session close wipes credentials and ephemeral secrets in real session', async () => {
  await getTestBrowserEnvironment();

  const win = (globalThis as any).window;

  // Add session with initial credentials
  win.setByName(
    'session_add_sync',
    JSON.stringify({ id: 'peer-wipe-test', password: 'EphemeralSessionPassword' })
  );
  const runtime = win.__CAMELLIA_REMOTE_WEB_BRIDGE__.runtime;
  const session = runtime.currentSession;

  assert.equal(session.request.password, 'EphemeralSessionPassword');

  // Close session
  session.close();

  // Password must be wiped to undefined
  assert.equal(session.request.password, undefined);
  assert.equal(session.pendingLogin, undefined);
});
