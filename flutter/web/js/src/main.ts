import { WebRuntime } from './runtime/runtime.ts';
import { attachBridge } from './bridge/index.ts';

const runtime = new WebRuntime();
attachBridge(runtime);

// Allow direct init in case the host calls it late.
if (document.readyState === 'complete') {
  runtime.init();
} else {
  window.addEventListener('load', () => runtime.init());
}
