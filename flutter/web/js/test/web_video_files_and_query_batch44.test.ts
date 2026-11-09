import assert from 'node:assert/strict';
import test from 'node:test';

import {
  VideoPipeline,
  SoftwareDecoder,
  MAX_WORKER_IN_FLIGHT_FRAMES,
  MAX_WORKER_IN_FLIGHT_BYTES,
  MAX_PENDING_SOFTWARE_FRAMES,
  MAX_PENDING_SOFTWARE_BYTES,
  MAX_SOFTWARE_DECODER_QUEUE_FRAMES,
  MAX_SOFTWARE_DECODER_QUEUE_BYTES,
  MAX_PENDING_WEBCODECS_FRAMES,
  MAX_PENDING_WEBCODECS_BYTES
} from '../src/runtime/video.ts';
import {
  MAX_DROP_DESCRIPTORS,
  MAX_DROP_FILE_BYTES,
  MAX_DROP_BATCH_BYTES,
  MAX_DROP_FETCH_CONCURRENCY,
  MAX_DIR_TRAVERSAL_DEPTH,
  MAX_DIR_TRAVERSAL_ENTRIES,
  MAX_DIR_PATH_LENGTH,
  MAX_DIR_TRAVERSAL_BYTES,
  MAX_ACTIVE_FILE_HANDLES,
  MAX_FILE_HANDLES_TOTAL_BYTES,
  FILE_HANDLE_TTL_MS,
  isAllowedDropUri
} from '../src/runtime/runtime.ts';
import { Logger } from '../src/core/logger.ts';
import { loadProtos } from '../src/runtime/proto.ts';

// -----------------------------------------------------------------------------
// Test Environment Shims
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
      location: {
        href: 'http://localhost:8080/index.html',
        origin: 'http://localhost:8080'
      },
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
      clearTimeout() {},
      setTimeout(fn: () => void) {
        return 12345;
      },
      setInterval(fn: () => void) {
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
    const NativeURL = globalThis.URL;
    (globalThis as any).URL = class extends NativeURL {
      static createObjectURL() {
        const u = `blob:http://localhost:8080/test-blob-${createdUrls.length + 1}`;
        createdUrls.push(u);
        return u;
      }
      static revokeObjectURL(u: string) {
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

// =============================================================================
// RES-057: Web Video Backpressure and Decode Queue Lifecycle
// =============================================================================

test('RES-057: Constants define bounded capacity for worker and software decode queues', () => {
  assert.equal(MAX_WORKER_IN_FLIGHT_FRAMES, 8);
  assert.equal(MAX_WORKER_IN_FLIGHT_BYTES, 4 * 1024 * 1024);
  assert.equal(MAX_PENDING_SOFTWARE_FRAMES, 8);
  assert.equal(MAX_PENDING_SOFTWARE_BYTES, 4 * 1024 * 1024);
  assert.equal(MAX_SOFTWARE_DECODER_QUEUE_FRAMES, 4);
  assert.equal(MAX_SOFTWARE_DECODER_QUEUE_BYTES, 2 * 1024 * 1024);
  assert.equal(MAX_PENDING_WEBCODECS_FRAMES, 8);
  assert.equal(MAX_PENDING_WEBCODECS_BYTES, 4 * 1024 * 1024);
});

test('RES-057: VideoPipeline lifecycle tracking (generation fence, closed flag, queue clearing)', () => {
  let sinkCalled = 0;
  let refreshCalled = 0;
  const pipeline = new VideoPipeline(
    () => { sinkCalled++; },
    () => { refreshCalled++; }
  );

  assert.equal(pipeline.getGeneration(), 0);
  assert.equal(pipeline.isPipelineClosed(), false);
  assert.equal(pipeline.getWorkerInFlightFrames(), 0);
  assert.equal(pipeline.getWorkerInFlightBytes(), 0);

  // Close the pipeline
  pipeline.close();

  assert.equal(pipeline.getGeneration(), 1);
  assert.equal(pipeline.isPipelineClosed(), true);

  // Subsequent decode calls must be dropped immediately
  pipeline.decode({
    codec: 'h264',
    display: 0,
    key: true,
    pts: 1,
    data: new Uint8Array([1, 2, 3, 4])
  });

  assert.equal(sinkCalled, 0);
  assert.equal(refreshCalled, 0);
});

test('RES-057: VideoPipeline display switch increments generation fence and purges inactive state', () => {
  const pipeline = new VideoPipeline(
    () => {},
    () => {}
  );

  assert.equal(pipeline.getGeneration(), 0);

  // Switch display to 1
  pipeline.switchDisplay(1);
  assert.equal(pipeline.getGeneration(), 1);

  // Set active display to 2
  pipeline.setActiveDisplay(2);
  assert.equal(pipeline.getGeneration(), 2);

  // Set active display to 2 again (no change -> no generation bump)
  pipeline.setActiveDisplay(2);
  assert.equal(pipeline.getGeneration(), 2);

  // Set active display to 0 (changed -> generation bumps)
  pipeline.setActiveDisplay(0);
  assert.equal(pipeline.getGeneration(), 3);
});

test('RES-057: WebCodecs pending decode queue caps frame count and byte budget, dropping old deltas on overflow', () => {
  const pipeline = new VideoPipeline(
    () => {},
    () => {}
  );

  const key = '0:h264';
  const smallDelta = {
    codec: 'h264' as const,
    display: 0,
    key: false,
    pts: 100,
    data: new Uint8Array(1024) // 1 KiB
  };

  // Push 12 delta frames to pending decode queue
  for (let i = 0; i < 12; i++) {
    (pipeline as any).enqueuePendingDecodeInput(key, { ...smallDelta, pts: i });
  }

  // Queue must be capped at 8 frames
  assert.equal(pipeline.getPendingDecodeFrames(key), 8);
  assert.equal(pipeline.getPendingDecodeBytes(key), 8 * 1024);

  // Keyframe arrival resets previous queued deltas and retains only keyframe
  const keyframe = {
    codec: 'h264' as const,
    display: 0,
    key: true,
    pts: 200,
    data: new Uint8Array(4096)
  };
  (pipeline as any).enqueuePendingDecodeInput(key, keyframe);

  assert.equal(pipeline.getPendingDecodeFrames(key), 1);
  assert.equal(pipeline.getPendingDecodeBytes(key), 4096);

  // Pushing frames that exceed MAX_PENDING_WEBCODECS_BYTES (4 MiB) drops older frames from head
  const largeDelta = {
    codec: 'h264' as const,
    display: 0,
    key: false,
    pts: 300,
    data: new Uint8Array(1.5 * 1024 * 1024) // 1.5 MiB
  };
  (pipeline as any).enqueuePendingDecodeInput(key, { ...largeDelta, pts: 301 });
  (pipeline as any).enqueuePendingDecodeInput(key, { ...largeDelta, pts: 302 });
  (pipeline as any).enqueuePendingDecodeInput(key, { ...largeDelta, pts: 303 });

  // Total bytes must not exceed MAX_PENDING_WEBCODECS_BYTES
  assert.ok(pipeline.getPendingDecodeBytes(key) <= MAX_PENDING_WEBCODECS_BYTES);
});

test('RES-057: SoftwareDecoder bounded queue drops non-keyframes on capacity overflow and respects close()', async () => {
  let initCalled = false;
  let closeCalled = false;
  let processedFrames = 0;

  const mockModule: any = {
    init(cb: () => void) {
      initCalled = true;
      cb();
    },
    processFrame(buffer: ArrayBuffer, cb: (ok: boolean) => void) {
      processedFrames++;
      cb(true);
    },
    close() {
      closeCalled = true;
    },
    frameBuffer: {
      format: { width: 64, height: 64 },
      y: { bytes: new Uint8Array(64 * 64), stride: 64 },
      u: { bytes: new Uint8Array(32 * 32), stride: 32 },
      v: { bytes: new Uint8Array(32 * 32), stride: 32 }
    }
  };

  const decoder = new SoftwareDecoder(
    0,
    mockModule,
    new Logger('test-sw-decoder'),
    () => {}
  );

  assert.equal(decoder.isClosed(), false);

  // Decode a keyframe
  const keyInput = {
    codec: 'vp8' as const,
    display: 0,
    key: true,
    pts: 1,
    data: new Uint8Array(100)
  };
  const keyResult = await decoder.decode(keyInput);
  assert.equal(keyResult, true);
  assert.equal(processedFrames, 1);

  // Saturate queue with non-keyframes (simulate queueFrames >= MAX_SOFTWARE_DECODER_QUEUE_FRAMES)
  (decoder as any).queueFrames = MAX_SOFTWARE_DECODER_QUEUE_FRAMES;
  const deltaInput = {
    codec: 'vp8' as const,
    display: 0,
    key: false,
    pts: 2,
    data: new Uint8Array(100)
  };
  const deltaResult = await decoder.decode(deltaInput);
  assert.equal(deltaResult, false, 'Non-keyframe must be dropped under queue backpressure');

  // Reset queueFrames
  (decoder as any).queueFrames = 0;

  // Close decoder
  decoder.close();
  assert.equal(decoder.isClosed(), true);
  assert.equal(closeCalled, true);

  // Once closed, subsequent decode calls reject immediately
  const afterCloseResult = await decoder.decode(keyInput);
  assert.equal(afterCloseResult, false, 'Closed software decoder must reject decode calls');
});

test('RES-057: Worker message ack protocol updates in-flight frame and byte credits', () => {
  const pipeline = new VideoPipeline(
    () => {},
    () => {}
  );

  // Artificially simulate in-flight counters
  (pipeline as any).workerInFlightFrames = 3;
  (pipeline as any).workerInFlightBytes = 3000;

  // Receive ack from worker
  (pipeline as any).handleWorkerMessage({
    type: 'ack',
    display: 0,
    bytes: 1000,
    dropped: false
  });

  assert.equal(pipeline.getWorkerInFlightFrames(), 2);
  assert.equal(pipeline.getWorkerInFlightBytes(), 2000);

  // Receive second ack
  (pipeline as any).handleWorkerMessage({
    type: 'ack',
    display: 0,
    bytes: 2000,
    dropped: false
  });

  assert.equal(pipeline.getWorkerInFlightFrames(), 1);
  assert.equal(pipeline.getWorkerInFlightBytes(), 0);

  // Counter must never underflow below 0
  (pipeline as any).handleWorkerMessage({
    type: 'ack',
    display: 0,
    bytes: 5000,
    dropped: true
  });

  assert.equal(pipeline.getWorkerInFlightFrames(), 0);
  assert.equal(pipeline.getWorkerInFlightBytes(), 0);
});

// =============================================================================
// RES-058: Local File Selection, Directory Traversal, and Dropped Files
// =============================================================================

test('RES-058: Constants define strict bounds on file drops, traversal depth, and handle TTL', () => {
  assert.equal(MAX_DROP_DESCRIPTORS, 200);
  assert.equal(MAX_DROP_FILE_BYTES, 500 * 1024 * 1024);
  assert.equal(MAX_DROP_BATCH_BYTES, 500 * 1024 * 1024);
  assert.equal(MAX_DROP_FETCH_CONCURRENCY, 4);
  assert.equal(MAX_DIR_TRAVERSAL_DEPTH, 32);
  assert.equal(MAX_DIR_TRAVERSAL_ENTRIES, 5000);
  assert.equal(MAX_DIR_PATH_LENGTH, 1024);
  assert.equal(MAX_DIR_TRAVERSAL_BYTES, 1024 * 1024 * 1024);
  assert.equal(MAX_ACTIVE_FILE_HANDLES, 16);
  assert.equal(MAX_FILE_HANDLES_TOTAL_BYTES, 1024 * 1024 * 1024);
  assert.equal(FILE_HANDLE_TTL_MS, 10 * 60 * 1000);
});

test('RES-058: isAllowedDropUri validates same-origin and blob: schemes while rejecting untrusted URIs', () => {
  const base = 'http://localhost:8080/index.html';

  // Allowed: blob scheme
  assert.equal(isAllowedDropUri('blob:http://localhost:8080/4f5a3b2c', base), true);
  assert.equal(isAllowedDropUri('blob:null/1234', base), true);

  // Denied: cross-origin blob scheme
  assert.equal(isAllowedDropUri('blob:https://evil.com/4f5a3b2c', base), false);
  assert.equal(isAllowedDropUri('blob:http://attacker.org/file.bin', base), false);

  // Allowed: same origin
  assert.equal(isAllowedDropUri('http://localhost:8080/assets/data.json', base), true);
  assert.equal(isAllowedDropUri('/assets/data.json', base), true);

  // Denied: external foreign domains
  assert.equal(isAllowedDropUri('http://evil.com/malicious.iso', base), false);
  assert.equal(isAllowedDropUri('https://attacker.org/script.js', base), false);

  // Denied: dangerous schemes
  assert.equal(isAllowedDropUri('javascript:alert(1)', base), false);
  assert.equal(isAllowedDropUri('file:///etc/passwd', base), false);
  assert.equal(isAllowedDropUri('data:text/html,<h1>hack</h1>', base), false);

  // Denied: unsupported protocols
  assert.equal(isAllowedDropUri('ftp://ftp.example.com/file.bin', base), false);

  // Denied: malformed URIs
  assert.equal(isAllowedDropUri('http://[:::1]', base), false);
  assert.equal(isAllowedDropUri('https://[:::1]', base), false);
});

test('RES-058: ManagedFileHandle allocation, TTL expiration, and deterministic cleanup in WebRuntime', async () => {
  await getTestBrowserEnvironment();
  const win = (globalThis as any).window;
  const runtime = win.__CAMELLIA_REMOTE_WEB_BRIDGE__.runtime;

  // Clear existing handles
  (runtime as any).clearFileHandles();
  assert.equal((runtime as any).fileHandles.size, 0);

  // Allocate 16 dummy handles
  for (let i = 1; i <= 16; i++) {
    const mockFile = { name: `file_${i}.dat`, size: 1024 * 1024 } as File;
    const handle = (runtime as any).allocateFileHandle([mockFile]);
    assert.ok(handle > 0, `Handle index ${handle} must be positive`);
  }
  assert.equal((runtime as any).fileHandles.size, 16);

  // Allocating the 17th handle must evict the oldest handle to maintain MAX_ACTIVE_FILE_HANDLES = 16
  const extraFile = { name: 'file_17.dat', size: 1024 * 1024 } as File;
  const extraHandle = (runtime as any).allocateFileHandle([extraFile]);
  assert.ok(extraHandle > 0);
  assert.equal((runtime as any).fileHandles.size, 16);

  // Simulate expiration of first remaining handle
  const firstEntry = (runtime as any).fileHandles.values().next().value;
  firstEntry.expiresAt = Date.now() - 1000; // Expired 1 second ago

  (runtime as any).evictExpiredFileHandles();
  assert.equal((runtime as any).fileHandles.size, 15);

  // Deterministic wipe on clearFileHandles
  (runtime as any).clearFileHandles();
  assert.equal((runtime as any).fileHandles.size, 0);
});

// =============================================================================
// STATE-019: Online Query Correlation Tokens and Page Lifecycle Generation
// =============================================================================

test('STATE-019: Empty query_onlines cancels in-flight queries and immediately returns empty lists', async () => {
  await getTestBrowserEnvironment();
  const win = (globalThis as any).window;
  const runtime = win.__CAMELLIA_REMOTE_WEB_BRIDGE__.runtime;

  const initialGen = (runtime as any).onlineQueryGeneration;

  // Send empty query
  runtime.handleQueryOnlines('[]');

  // Generation must increment and pending queries cleared
  assert.ok(
    (runtime as any).onlineQueryGeneration > initialGen,
    'Empty online query must bump generation fence'
  );
  assert.equal((runtime as any).pendingOnlineQueryIds, undefined);
});

test('STATE-019: Page lifecycle handlers and session close deterministically bump onlineQueryGeneration', async () => {
  await getTestBrowserEnvironment();
  const win = (globalThis as any).window;
  const runtime = win.__CAMELLIA_REMOTE_WEB_BRIDGE__.runtime;

  const genBefore = (runtime as any).onlineQueryGeneration;

  // Simulate close
  win.setByName('session_close', '');

  assert.ok(
    (runtime as any).onlineQueryGeneration > genBefore,
    'Session close must bump onlineQueryGeneration to cancel in-flight queries'
  );
});

// =============================================================================
// COMPAT-002: Web Audio Capability Reconciliation
// =============================================================================

test('COMPAT-002: buildOptionMessage unconditionally enforces disableAudio: BoolOption.Yes', async () => {
  await getTestBrowserEnvironment();
  const win = (globalThis as any).window;

  win.setByName(
    'session_add_sync',
    JSON.stringify({ id: 'audio-build-test', password: 'TestPassword' })
  );
  const runtime = win.__CAMELLIA_REMOTE_WEB_BRIDGE__.runtime;
  const session = runtime.currentSession;

  const msg = await (session as any).buildOptionMessage();
  assert.ok(msg, 'Option message must exist');
  // BoolOption.Yes in protobuf is 2
  assert.equal(msg.disableAudio, 2, 'Web client must declare disableAudio: Yes (2)');

  session.close();
});

test('COMPAT-002: sendOption coerces disableAudio to BoolOption.Yes', async () => {
  await getTestBrowserEnvironment();
  const win = (globalThis as any).window;

  win.setByName(
    'session_add_sync',
    JSON.stringify({ id: 'audio-compat-test', password: 'TestPassword' })
  );
  const runtime = win.__CAMELLIA_REMOTE_WEB_BRIDGE__.runtime;
  const session = runtime.currentSession;

  // Intercept socket send to verify serialized option payload
  let sentData: Uint8Array | null = null;
  const originalTransport = (session as any).transport;
  (session as any).transport = {
    send(data: Uint8Array) {
      sentData = data;
      return true;
    },
    getState() {
      return 'open';
    },
    close() {
      originalTransport?.close?.();
    }
  };

  // Ensure protos are loaded on session
  (session as any).proto = await loadProtos();

  // Attempt to send options
  session.sendOption({ customFps: 30 });

  assert.ok(sentData, 'Option data should have been sent');
  const decoded = (session as any).proto.messageType.decode(sentData);
  assert.equal(
    decoded.misc.option.disableAudio,
    2,
    'disableAudio must be coerced to BoolOption.Yes (2)'
  );

  session.close();
});

test('COMPAT-002: WebSession safely drops incoming audioFrame messages without errors', async () => {
  await getTestBrowserEnvironment();
  const win = (globalThis as any).window;

  win.setByName(
    'session_add_sync',
    JSON.stringify({ id: 'audio-frame-drop-test', password: 'TestPassword' })
  );
  const runtime = win.__CAMELLIA_REMOTE_WEB_BRIDGE__.runtime;
  const session = runtime.currentSession;
  (session as any).proto = await loadProtos();

  // Feed message with audioFrame
  const audioMessage = {
    audioFrame: {
      data: new Uint8Array([1, 2, 3, 4, 5]),
      sampleRate: 48000,
      channels: 2
    }
  };
  const encoded = (session as any).proto.messageType.encode(audioMessage).finish();

  // Must not throw or crash
  await assert.doesNotReject(async () => {
    await (session as any).handleMessage(encoded);
  });

  session.close();
});

test('RES-057: VideoPipeline coalesces multiple worker need_refresh requests within the throttle window', () => {
  let refreshCount = 0;
  let lastRefreshedDisplay = -1;
  const pipeline = new VideoPipeline(
    () => {},
    undefined,
    (display) => {
      refreshCount++;
      lastRefreshedDisplay = display;
    }
  );

  (pipeline as any).activeDisplay = 0;

  // First need_refresh from worker should trigger onNeedRefresh
  (pipeline as any).handleWorkerMessage({ type: 'need_refresh', display: 0 });
  assert.equal(refreshCount, 1, 'First need_refresh must be delivered');
  assert.equal(lastRefreshedDisplay, 0);

  // Subsequent need_refresh within 900ms must be coalesced and dropped
  (pipeline as any).handleWorkerMessage({ type: 'need_refresh', display: 0 });
  (pipeline as any).handleWorkerMessage({ type: 'need_refresh', display: 0 });
  assert.equal(refreshCount, 1, 'Rapid need_refresh bursts must be coalesced');

  pipeline.close();
});

test('RES-058: walkFileSystemEntry handles cyclical directory references and duplicate reader batches', async () => {
  await getTestBrowserEnvironment();
  const win = (globalThis as any).window;
  const runtime = win.__CAMELLIA_REMOTE_WEB_BRIDGE__.runtime;

  // Create cyclical structure: dirA contains dirB, and dirB contains dirA
  const dirA: any = { isFile: false, name: 'dirA', fullPath: '/dirA' };
  const dirB: any = { isFile: false, name: 'dirB', fullPath: '/dirA/dirB' };

  let dirAReads = 0;
  dirA.createReader = () => ({
    readEntries(resolve: (entries: any[]) => void) {
      dirAReads++;
      if (dirAReads === 1) {
        resolve([dirB]);
      } else {
        // Return duplicate entry in batch 2 to verify duplicate batch detection
        resolve([dirB]);
      }
    }
  });

  let dirBReads = 0;
  dirB.createReader = () => ({
    readEntries(resolve: (entries: any[]) => void) {
      dirBReads++;
      if (dirBReads === 1) {
        resolve([dirA]); // cyclical reference back to dirA!
      } else {
        resolve([]);
      }
    }
  });

  const files: File[] = [];
  const emptyDirs: string[] = [];
  const stats = { entryCount: 0, totalBytes: 0 };
  const visitedPaths = new Set<string>();

  // Must terminate cleanly without infinite loop or exceeding traversal bounds
  await (runtime as any).walkFileSystemEntry(
    dirA,
    '',
    files,
    emptyDirs,
    undefined,
    stats,
    visitedPaths
  );

  assert.ok(stats.entryCount < 10, 'Cyclical directory walk must terminate quickly via visitedPaths');
  assert.ok(visitedPaths.has('/dirA'));
  assert.ok(visitedPaths.has('/dirA/dirB'));
});

test('STATE-019: Online query correlation tokens advance on each query and discard responses from superseded queries', async () => {
  await getTestBrowserEnvironment();
  const win = (globalThis as any).window;
  const runtime = win.__CAMELLIA_REMOTE_WEB_BRIDGE__.runtime;

  const initialToken = runtime.getActiveOnlineQueryToken();
  const initialGen = runtime.getOnlineQueryGeneration();

  // Query 1
  runtime.handleQueryOnlines('["peer-alpha"]');
  const token1 = runtime.getActiveOnlineQueryToken();
  assert.ok(token1 > initialToken, 'Token must advance on query 1');

  // Query 2 supersedes Query 1
  runtime.handleQueryOnlines('["peer-beta"]');
  const token2 = runtime.getActiveOnlineQueryToken();
  assert.ok(token2 > token1, 'Token must advance on query 2');

  // Allow pending async flush for Query 2 to settle
  await new Promise((resolve) => setTimeout(resolve, 20));

  // Simulate late response arriving for Query 1 with token1
  let emittedCount = 0;
  runtime.events.onEmit((evt) => {
    if (
      evt.name === 'callback_query_onlines' &&
      String((evt as any).offlines ?? '').includes('peer-alpha')
    ) {
      emittedCount++;
    }
  });

  // queryOnlineStates with stale token1 must discard
  await (runtime as any).queryOnlineStates(['peer-alpha'], initialGen, token1);
  assert.equal(emittedCount, 0, 'Late response with stale query token must be discarded');
});

test('COMPAT-002: session.connect() unconditionally enforces context.policy.disableAudio = true', async () => {
  await getTestBrowserEnvironment();
  const win = (globalThis as any).window;

  win.setByName(
    'session_add_sync',
    JSON.stringify({ id: 'audio-connect-test', password: 'TestPassword' })
  );
  const runtime = win.__CAMELLIA_REMOTE_WEB_BRIDGE__.runtime;
  const session = runtime.currentSession;

  // Pass policy where disableAudio is false
  const mockContext: any = {
    myId: 'test-me',
    myName: 'Test User',
    version: '1.0.0',
    imageQuality: 'balanced',
    policy: {
      viewOnly: false,
      disableKeyboard: false,
      disableClipboard: false,
      disableAudio: false, // explicitly false
      enableFileTransfer: true,
      lockAfterSessionEnd: false,
      showRemoteCursor: false,
      showMyCursor: false,
      followRemoteCursor: false,
      followRemoteWindow: false
    }
  };

  // Mock transport and rendezvous so connect sets context
  (session as any).transport = {
    connect: async () => {},
    close: () => {},
    getState: () => 'idle',
    setCipher: () => {}
  };

  try {
    await session.connect(mockContext);
  } catch {
    // connect might throw at rendezvous route, but context and policy must be set
  }

  assert.equal(
    mockContext.policy.disableAudio,
    true,
    'session.connect() must unconditionally set context.policy.disableAudio = true'
  );

  session.close();
});

test('RES-057: enqueuePendingDecodeInput protects keyframe at head when delta flood arrives', () => {
  let refreshCount = 0;
  const pipeline = new VideoPipeline(
    () => {},
    undefined,
    () => { refreshCount++; }
  );
  (pipeline as any).activeDisplay = 0;

  const key = '0:h264';
  const keyframe = {
    codec: 'h264' as const,
    display: 0,
    key: true,
    pts: 1,
    data: new Uint8Array(2048)
  };
  (pipeline as any).enqueuePendingDecodeInput(key, keyframe);
  assert.equal(pipeline.getPendingDecodeFrames(key), 1);

  // Flood with 12 delta frames
  for (let i = 2; i <= 14; i++) {
    (pipeline as any).enqueuePendingDecodeInput(key, {
      codec: 'h264' as const,
      display: 0,
      key: false,
      pts: i,
      data: new Uint8Array(1024)
    });
  }

  // Queue must be capped at MAX_PENDING_WEBCODECS_FRAMES (8)
  assert.equal(pipeline.getPendingDecodeFrames(key), MAX_PENDING_WEBCODECS_FRAMES);

  // The first frame in queue MUST still be the keyframe!
  const queue = (pipeline as any).pendingDecodeInputs.get(key);
  assert.ok(queue, 'Queue must exist');
  assert.equal(queue[0].key, true, 'Head of queue must remain the keyframe');
  assert.ok(refreshCount > 0, 'Refresh must be requested when delta flood hits capacity');

  pipeline.close();
});

test('RES-057: SoftwareDecoder recovers promise chain if a frame throws during decode', async () => {
  let callCount = 0;
  const mockModule: any = {
    init(cb: () => void) { cb(); },
    processFrame(buffer: ArrayBuffer, cb: (ok: boolean) => void) {
      callCount++;
      if (callCount === 1) {
        throw new Error('Simulated internal WASM crash on frame 1');
      }
      cb(true);
    },
    close() {},
    frameBuffer: {
      format: { width: 32, height: 32 },
      y: { bytes: new Uint8Array(32 * 32), stride: 32 },
      u: { bytes: new Uint8Array(16 * 16), stride: 16 },
      v: { bytes: new Uint8Array(16 * 16), stride: 16 }
    }
  };

  const decoder = new SoftwareDecoder(
    0,
    mockModule,
    new Logger('test-sw-resilience'),
    () => {}
  );

  const frame1 = {
    codec: 'vp8' as const,
    display: 0,
    key: true,
    pts: 1,
    data: new Uint8Array(64)
  };

  // Frame 1 throws
  const res1 = await decoder.decode(frame1);
  assert.equal(res1, false, 'Frame 1 decode must fail closed');

  // Frame 2 must still be processed and not permanently reject the chain
  const frame2 = {
    codec: 'vp8' as const,
    display: 0,
    key: true,
    pts: 2,
    data: new Uint8Array(64)
  };
  const res2 = await decoder.decode(frame2);
  assert.equal(res2, true, 'Frame 2 decode must succeed despite prior frame exception');

  decoder.close();
});

test('COMPAT-002: handleMessage safely discards audioFrame without dropping subsequent fields in the same message', async () => {
  await getTestBrowserEnvironment();
  const win = (globalThis as any).window;

  win.setByName(
    'session_add_sync',
    JSON.stringify({ id: 'audio-multi-field-test', password: 'TestPassword' })
  );
  const runtime = win.__CAMELLIA_REMOTE_WEB_BRIDGE__.runtime;
  const session = runtime.currentSession;
  (session as any).proto = await loadProtos();

  let cursorPositionHandled = false;
  (session as any).handleCursorPosition = () => {
    cursorPositionHandled = true;
  };

  // Feed composite message containing both audioFrame and cursorPosition
  const compositeMessage = {
    audioFrame: {
      data: new Uint8Array([1, 2, 3]),
      sampleRate: 44100,
      channels: 2
    },
    cursorPosition: {
      x: 150,
      y: 250
    }
  };
  const encoded = (session as any).proto.messageType.encode(compositeMessage).finish();

  await (session as any).handleMessage(encoded);
  assert.equal(
    cursorPositionHandled,
    true,
    'Subsequent fields in Message must be processed even when audioFrame is discarded'
  );

  session.close();
});

