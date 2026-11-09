import { readdir, readFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

import { protoSourceDigest } from './proto-sources.mjs';

const toolsDir = dirname(fileURLToPath(import.meta.url));
const generatedProto = resolve(toolsDir, '../src/proto/generated.js');
const webDist = resolve(toolsDir, '../dist');
const generated = await readFile(generatedProto, 'utf8');
const expectedDigest = await protoSourceDigest();
const digestMatch = generated.match(
  /^\/\/ camellia-proto-source-sha256: ([a-f0-9]{64})$/mu
);

if (digestMatch?.[1] !== expectedDigest) {
  throw new Error(
    'Generated protobuf codecs do not match libs/camellia_remote_protocol/protos; run `npm run generate:proto`.'
  );
}

const dynamicCodePatterns = [
  ['eval()', /(?:^|[^\w$.])eval\s*\(/u],
  ['Function constructor', /\b(?:new\s+)?Function\s*\(/u],
  ['string-based timer', /\bset(?:Interval|Timeout)\s*\(\s*['"`]/u]
];
const cspSources = [
  ...(await findJavaScript(webDist)),
  resolve(toolsDir, '../../ogvjs-1.8.6/ogv-decoder-video-vp8-wasm.js'),
  resolve(toolsDir, '../../ogvjs-1.8.6/ogv-decoder-video-vp9-wasm.js'),
  resolve(toolsDir, '../../ogvjs-1.8.6/ogv-decoder-video-av1-wasm.js')
];
for (const source of cspSources) {
  const contents = await readFile(source, 'utf8');
  const violations = dynamicCodePatterns
    .filter(([, pattern]) => pattern.test(contents))
    .map(([name]) => name);
  if (violations.length > 0) {
    throw new Error(
      `${source} requires CSP unsafe-eval (${violations.join(', ')}); remove dynamic code generation.`
    );
  }
}

const undefinedPatterns = [
  ['empty glob Object.assign', /Object\.assign\(\{\}\)\[/u],
  ['undefined URL path', /new\s+URL\s*\(\s*['"`][^'"`]*\/undefined['"`]/u],
  ['undefined URL resolution', /new\s+URL\s*\(\s*(?:undefined|void\s+0)\b/u],
  ['root absolute /js/dist worker path', /['"`]\/js\/dist\/assets\/video_worker/u]
];
const distFiles = await findJavaScript(webDist);
for (const file of distFiles) {
  const contents = await readFile(file, 'utf8');
  for (const [desc, pattern] of undefinedPatterns) {
    if (pattern.test(contents)) {
      throw new Error(
        `Bundle artifact ${file} contains illegal pattern '${desc}'; check asset base and dynamic URL imports.`
      );
    }
  }
}

const bundleCombined = (
  await Promise.all(distFiles.map((file) => readFile(file, 'utf8')))
).join('\n');
const requiredDecoderScripts = [
  'ogv-decoder-video-vp8-wasm.js',
  'ogv-decoder-video-vp8-wasm.wasm',
  'ogv-decoder-video-vp9-wasm.js',
  'ogv-decoder-video-vp9-wasm.wasm',
  'ogv-decoder-video-av1-wasm.js',
  'ogv-decoder-video-av1-wasm.wasm'
];
for (const script of requiredDecoderScripts) {
  if (!bundleCombined.includes(script)) {
    throw new Error(
      `Bundle is missing static reference to software decoder script: ${script}`
    );
  }
}

const { hbb } = await import(pathToFileURL(generatedProto).href);
const idPkWire = hbb.IdPk.encode({
  id: 'csp-build-check',
  pk: new Uint8Array([1, 2, 3])
}).finish();
const idPk = hbb.IdPk.toObject(hbb.IdPk.decode(idPkWire), {
  bytes: Uint8Array,
  defaults: false
});
const proxyWire = hbb.RendezvousMessage.encode({
  httpProxyRequest: {
    method: 'GET',
    path: '/health',
    licenceKey: 'build-check'
  }
}).finish();
const proxy = hbb.RendezvousMessage.toObject(
  hbb.RendezvousMessage.decode(proxyWire),
  { bytes: Uint8Array, defaults: false }
);
if (
  idPk.id !== 'csp-build-check' ||
  !(idPk.pk instanceof Uint8Array) ||
  idPk.pk.length !== 3 ||
  proxy.httpProxyRequest?.licenceKey !== 'build-check'
) {
  throw new Error('Generated protobuf codecs failed the protocol round-trip check.');
}

process.stdout.write('Web bundle is synchronized and CSP-safe.\n');

async function findJavaScript(directory) {
  const results = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = resolve(directory, entry.name);
    if (entry.isDirectory()) {
      results.push(...(await findJavaScript(path)));
    } else if (entry.isFile() && entry.name.endsWith('.js')) {
      results.push(path);
    }
  }
  return results;
}
