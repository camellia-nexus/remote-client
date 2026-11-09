import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

import {
  softwareDecoderScriptUrl,
  loadSoftwareDecoderScript
} from '../src/runtime/video.ts';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const webDir = path.resolve(__dirname, '../..');

test('softwareDecoderScriptUrl returns correct relative URLs for valid targets', () => {
  const vp8Url = softwareDecoderScriptUrl('vp8');
  assert.match(vp8Url, /ogv-decoder-video-vp8-wasm\.js$/);

  const vp8Upper = softwareDecoderScriptUrl('VP8');
  assert.strictEqual(vp8Upper, vp8Url);

  const vp8Wasm = softwareDecoderScriptUrl('ogv-decoder-video-vp8-wasm.wasm');
  assert.match(vp8Wasm, /ogv-decoder-video-vp8-wasm\.wasm$/);

  const vp8ByName = softwareDecoderScriptUrl('ogv-decoder-video-vp8-wasm.js');
  assert.strictEqual(vp8ByName, vp8Url);

  const vp9Url = softwareDecoderScriptUrl('vp9');
  assert.match(vp9Url, /ogv-decoder-video-vp9-wasm\.js$/);

  const vp9Wasm = softwareDecoderScriptUrl('ogv-decoder-video-vp9-wasm.wasm');
  assert.match(vp9Wasm, /ogv-decoder-video-vp9-wasm\.wasm$/);

  const vp9ByName = softwareDecoderScriptUrl('ogv-decoder-video-vp9-wasm.js');
  assert.strictEqual(vp9ByName, vp9Url);

  const av1Url = softwareDecoderScriptUrl('av1');
  assert.match(av1Url, /ogv-decoder-video-av1-wasm\.js$/);

  const av1Wasm = softwareDecoderScriptUrl('ogv-decoder-video-av1-wasm.wasm');
  assert.match(av1Wasm, /ogv-decoder-video-av1-wasm\.wasm$/);

  const av1ByName = softwareDecoderScriptUrl('ogv-decoder-video-av1-wasm.js');
  assert.strictEqual(av1ByName, av1Url);
});

test('softwareDecoderScriptUrl rejects invalid or unknown decoder targets', () => {
  assert.throws(() => {
    softwareDecoderScriptUrl('h264' as any);
  }, /unknown software decoder target: h264/);

  assert.throws(() => {
    softwareDecoderScriptUrl('hevc' as any);
  }, /unknown software decoder target: hevc/);

  assert.throws(() => {
    softwareDecoderScriptUrl('invalid.js' as any);
  }, /unknown software decoder target: invalid\.js/);

  assert.throws(() => {
    softwareDecoderScriptUrl('' as any);
  }, /unknown software decoder target:/);
});

test('softwareDecoderScriptUrl refuses cross-origin URL when location is defined', () => {
  const originalLocation = (globalThis as any).location;
  try {
    (globalThis as any).location = { origin: 'https://malicious-origin.example.com' };
    assert.throws(() => {
      softwareDecoderScriptUrl('vp8');
    }, /refusing cross-origin software decoder/);
  } finally {
    if (originalLocation === undefined) {
      delete (globalThis as any).location;
    } else {
      (globalThis as any).location = originalLocation;
    }
  }
});

test('relative asset URL resolution works properly for nested base deployments', () => {
  // Simulate Web Client embedded under Django static root: /static/web_client/
  const simulatedBridgeUrl = 'https://camellia.example.com/static/web_client/js/dist/web_bridge.js';

  // Worker chunk resolution relative to web_bridge.js
  const workerRel = 'assets/video_worker-mock.js';
  const resolvedWorkerUrl = new URL(workerRel, simulatedBridgeUrl).href;
  assert.strictEqual(
    resolvedWorkerUrl,
    'https://camellia.example.com/static/web_client/js/dist/assets/video_worker-mock.js'
  );

  // OGV JS decoder resolution relative to web_bridge.js
  const ogvRel = '../../ogvjs-1.8.6/ogv-decoder-video-vp8-wasm.js';
  const resolvedOgvUrl = new URL(ogvRel, simulatedBridgeUrl).href;
  assert.strictEqual(
    resolvedOgvUrl,
    'https://camellia.example.com/static/web_client/ogvjs-1.8.6/ogv-decoder-video-vp8-wasm.js'
  );
});

test('web_codec_manifest.json matches all committed codec assets by size and SHA-256', () => {
  const manifestPath = path.join(webDir, 'tools/web_codec_manifest.json');
  assert.ok(fs.existsSync(manifestPath), 'tools/web_codec_manifest.json must exist');

  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf-8'));
  assert.strictEqual(manifest.schema_version, 1);
  assert.ok(manifest.files && typeof manifest.files === 'object');

  const expectedKeys = [
    'libopus.js',
    'libopus.wasm',
    'yuv-canvas-1.2.6.js',
    'ogvjs-1.8.6/ogv-decoder-video-av1-wasm.js',
    'ogvjs-1.8.6/ogv-decoder-video-av1-wasm.wasm',
    'ogvjs-1.8.6/ogv-decoder-video-vp8-wasm.js',
    'ogvjs-1.8.6/ogv-decoder-video-vp8-wasm.wasm',
    'ogvjs-1.8.6/ogv-decoder-video-vp9-wasm.js',
    'ogvjs-1.8.6/ogv-decoder-video-vp9-wasm.wasm'
  ];

  for (const relKey of expectedKeys) {
    const entry = manifest.files[relKey];
    assert.ok(entry, `Manifest must contain entry for ${relKey}`);
    assert.ok(typeof entry.size === 'number' && entry.size > 0);
    assert.match(entry.sha256, /^[0-9a-f]{64}$/);

    const filePath = path.join(webDir, relKey);
    assert.ok(fs.existsSync(filePath), `Asset file ${filePath} must exist on disk`);

    const data = fs.readFileSync(filePath);
    assert.strictEqual(data.length, entry.size, `Size mismatch for ${relKey}`);

    const hash = crypto.createHash('sha256').update(data).digest('hex');
    assert.strictEqual(hash, entry.sha256, `SHA-256 mismatch for ${relKey}`);
  }
});

test('compiled web_bridge bundle contains no dynamic glob failures or root-absolute worker paths', () => {
  const distDir = path.resolve(__dirname, '../dist');
  if (!fs.existsSync(distDir)) {
    // Dist may not exist if build has not run yet in raw test runner
    return;
  }

  const bridgePath = path.join(distDir, 'web_bridge.js');
  assert.ok(fs.existsSync(bridgePath), 'dist/web_bridge.js must exist');
  const bridgeContent = fs.readFileSync(bridgePath, 'utf-8');

  // Must not contain Vite's failed dynamic import glob Object.assign({})[...]
  assert.doesNotMatch(bridgeContent, /Object\.assign\(\{\}\)\[/);

  // Must not contain undefined URL requests
  assert.doesNotMatch(bridgeContent, /new URL\([^)]*\/undefined/);
  assert.doesNotMatch(bridgeContent, /new URL\(undefined/);

  // Must not contain root-absolute /js/dist/assets/video_worker
  assert.doesNotMatch(bridgeContent, /["']\/js\/dist\/assets\/video_worker/);

  // Must contain static references to all three OGV decoder scripts
  assert.ok(bridgeContent.includes('ogv-decoder-video-vp8-wasm.js'));
  assert.ok(bridgeContent.includes('ogv-decoder-video-vp9-wasm.js'));
  assert.ok(bridgeContent.includes('ogv-decoder-video-av1-wasm.js'));

  // Video worker asset must exist in dist/assets
  const assetsDir = path.join(distDir, 'assets');
  assert.ok(fs.existsSync(assetsDir), 'dist/assets directory must exist');
  const files = fs.readdirSync(assetsDir);
  const workerMatches = files.filter(f => f.startsWith('video_worker-') && f.endsWith('.js'));
  assert.ok(workerMatches.length >= 1, 'Expected at least one video_worker-*.js chunk in dist/assets');
});

test('loadSoftwareDecoderScript correctly resolves with factory functions and locateFile', async () => {
  const originalDoc = (globalThis as any).document;
  try {
    const appendedScripts: any[] = [];
    (globalThis as any).document = {
      createElement: (tag: string) => {
        return {
          tagName: tag.toUpperCase(),
          src: '',
          async: false,
          onload: null as any,
          onerror: null as any,
          remove: () => {}
        };
      },
      head: {
        append: (el: any) => {
          appendedScripts.push(el);
          // Simulate script execution defining a factory function (ogvjs style)
          (globalThis as any).OGVDecoderVideoVP8W = (options?: any) => {
            const locateResult = options?.locateFile ? options.locateFile('ogv-decoder-video-vp8-wasm.wasm') : '';
            return Promise.resolve({
              _mock: true,
              locatedWasm: locateResult
            });
          };
          if (typeof el.onload === 'function') {
            queueMicrotask(() => el.onload());
          }
        }
      }
    };

    const decoderModule = await loadSoftwareDecoderScript({
      globalName: 'OGVDecoderVideoVP8W',
      scriptName: 'ogv-decoder-video-vp8-wasm.js'
    });

    assert.ok(decoderModule && (decoderModule as any)._mock);
    assert.match((decoderModule as any).locatedWasm, /ogv-decoder-video-vp8-wasm\.wasm$/);
  } finally {
    if (originalDoc === undefined) {
      delete (globalThis as any).document;
    } else {
      (globalThis as any).document = originalDoc;
    }
    delete (globalThis as any).OGVDecoderVideoVP8W;
  }
});

test('loadSoftwareDecoderScript rejects properly when factory throws or global is missing', async () => {
  const originalDoc = (globalThis as any).document;
  try {
    (globalThis as any).document = {
      createElement: () => ({
        src: '',
        async: false,
        onload: null as any,
        onerror: null as any,
        remove: () => {}
      }),
      head: {
        append: (el: any) => {
          // Define factory that throws
          (globalThis as any).OGVDecoderVideoVP9W = () => {
            throw new Error('simulated factory initialization failure');
          };
          if (typeof el.onload === 'function') {
            queueMicrotask(() => el.onload());
          }
        }
      }
    };

    await assert.rejects(
      async () => {
        await loadSoftwareDecoderScript({
          globalName: 'OGVDecoderVideoVP9W',
          scriptName: 'ogv-decoder-video-vp9-wasm.js'
        });
      },
      /simulated factory initialization failure/
    );

    // Now test missing global export
    (globalThis as any).document.head.append = (el: any) => {
      delete (globalThis as any).OGVDecoderVideoAV1W;
      if (typeof el.onload === 'function') {
        queueMicrotask(() => el.onload());
      }
    };

    await assert.rejects(
      async () => {
        await loadSoftwareDecoderScript({
          globalName: 'OGVDecoderVideoAV1W',
          scriptName: 'ogv-decoder-video-av1-wasm.js'
        });
      },
      /ogv-decoder-video-av1-wasm\.js did not expose OGVDecoderVideoAV1W/
    );
  } finally {
    if (originalDoc === undefined) {
      delete (globalThis as any).document;
    } else {
      (globalThis as any).document = originalDoc;
    }
    delete (globalThis as any).OGVDecoderVideoVP9W;
    delete (globalThis as any).OGVDecoderVideoAV1W;
  }
});
