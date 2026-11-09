import { isMobileDevice } from '../core/platform.ts';
import { WebRuntime } from '../runtime/runtime.ts';

export function attachBridge(runtime: WebRuntime): void {
  window.isMobile = isMobileDevice;
  window.setByName = runtime.setByName.bind(runtime);
  window.getByName = runtime.getByName.bind(runtime);
  window.getDeviceProof = runtime.getDeviceProof.bind(runtime);
  window.__CAMELLIA_REMOTE_WEB_BRIDGE__ = { runtime };
  window.init = runtime.init.bind(runtime);
}
