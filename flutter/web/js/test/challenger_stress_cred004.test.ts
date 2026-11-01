import assert from 'node:assert/strict';
import test from 'node:test';

import { StorageStore } from '../src/core/storage.ts';
import { purgeAccountCredentials, type StorageLike } from '../src/runtime/account_credentials.ts';

function createMockStorage(): Storage {
  const map = new Map<string, string>();
  return {
    getItem(key: string): string | null {
      return map.has(key) ? map.get(key)! : null;
    },
    setItem(key: string, value: string): void {
      map.set(key, String(value));
    },
    removeItem(key: string): void {
      map.delete(key);
    },
    clear(): void {
      map.clear();
    },
    key(index: number): string | null {
      return Array.from(map.keys())[index] ?? null;
    },
    get length(): number {
      return map.size;
    }
  };
}

test('STRESS CRED-004: 100 cycles of login token setting and purgeAccountCredentials', () => {
  const mockStorage = createMockStorage();
  (globalThis as any).window = {
    localStorage: mockStorage
  };

  const store = new StorageStore('camellia.web.');

  for (let cycle = 0; cycle < 100; cycle++) {
    const canaryToken = `CANARY_TOKEN_CYCLE_${cycle}_${Math.random()}`;
    const canaryUserInfo = `{"user":"user_${cycle}","email":"test@example.com"}`;
    const canaryAuthResult = JSON.stringify({
      access_token: canaryToken,
      type: 'access_token',
      user: { name: `user_${cycle}` }
    });

    // Populate credentials
    store.set('option:local:access_token', canaryToken, true);
    store.set('option:access_token', canaryToken, true);
    store.set('account_auth_result', canaryAuthResult, true);
    store.set('option:local:user_info', canaryUserInfo, true);
    store.setJson('options', {
      access_token: canaryToken,
      theme: 'dark',
      rendezvous_server: 'custom.server.com'
    });

    // Verify populated
    assert.equal(store.get('option:local:access_token'), canaryToken);
    assert.equal(mockStorage.getItem('camellia.web.option:local:access_token'), canaryToken);
    assert.equal(mockStorage.getItem('camellia.web.account_auth_result'), canaryAuthResult);

    // Execute purge
    purgeAccountCredentials(store);

    // Verify completely wiped from memory and storage
    assert.equal(store.get('option:local:access_token'), '', `Cycle ${cycle}: local access_token memory wipe`);
    assert.equal(store.get('option:access_token'), '', `Cycle ${cycle}: access_token memory wipe`);
    assert.equal(store.get('account_auth_result'), '', `Cycle ${cycle}: auth_result memory wipe`);
    assert.equal(store.get('option:local:user_info'), '', `Cycle ${cycle}: user_info memory wipe`);

    assert.equal(mockStorage.getItem('camellia.web.option:local:access_token'), null);
    assert.equal(mockStorage.getItem('camellia.web.option:access_token'), null);
    assert.equal(mockStorage.getItem('camellia.web.account_auth_result'), null);
    assert.equal(mockStorage.getItem('camellia.web.option:local:user_info'), null);

    // Verify non-credential options are safely preserved
    const remainingOptions = store.getJson<Record<string, string>>('options', {});
    assert.equal(remainingOptions['access_token'], undefined);
    assert.equal(remainingOptions['theme'], 'dark');
    assert.equal(remainingOptions['rendezvous_server'], 'custom.server.com');
  }
});

test('STRESS CRED-004: Fault tolerance when localStorage throws SecurityError / DOMException', () => {
  const faultStorage = {
    getItem(): string | null {
      throw new Error('SecurityError: The operation is insecure');
    },
    setItem(): void {
      throw new Error('QuotaExceededError: Storage quota exceeded');
    },
    removeItem(): void {
      throw new Error('SecurityError: Access to localStorage is denied');
    },
    clear(): void {},
    key(): string | null { return null; },
    length: 0
  };

  (globalThis as any).window = {
    localStorage: faultStorage
  };

  const store = new StorageStore('camellia.web.');

  // Set memory credentials
  store.set('option:local:access_token', 'SECRET_IN_MEMORY_ONLY', false);
  store.set('option:access_token', 'SECRET_IN_MEMORY_ONLY', false);
  store.set('account_auth_result', 'SECRET_RESULT', false);

  assert.equal(store.get('option:local:access_token'), 'SECRET_IN_MEMORY_ONLY');

  // Purge must NOT throw and must cleanly delete memory entries
  assert.doesNotThrow(() => {
    purgeAccountCredentials(store);
  });

  assert.equal(store.get('option:local:access_token'), '');
  assert.equal(store.get('option:access_token'), '');
  assert.equal(store.get('account_auth_result'), '');
});

test('STRESS CRED-004: Corrupted or unexpected data in options does not fail purge', () => {
  const mockStorage = createMockStorage();
  (globalThis as any).window = {
    localStorage: mockStorage
  };

  const store = new StorageStore('camellia.web.');

  // Non-JSON string in options
  store.set('options', 'NOT_VALID_JSON{{{', true);
  store.set('option:local:access_token', 'CANARY_TOKEN', true);

  assert.doesNotThrow(() => {
    purgeAccountCredentials(store);
  });

  assert.equal(store.get('option:local:access_token'), '');
  assert.equal(mockStorage.getItem('camellia.web.option:local:access_token'), null);
});

test('STRESS CRED-004: Simulated runtime option handler dispatch on logout and empty token', () => {
  const mockStorage = createMockStorage();
  (globalThis as any).window = {
    localStorage: mockStorage
  };
  const store = new StorageStore('camellia.web.');

  // Emulate WebRuntime.setByName handler logic from runtime.ts:
  // case 'account_logout': this.purgeAccountCredentials()
  // if (prefix === 'option:local' && key === 'access_token' && (!val || val === '')) this.purgeAccountCredentials()
  function runtimeDispatch(name: string, arg0?: unknown, arg1?: unknown): string {
    if (name === 'account_logout') {
      purgeAccountCredentials(store);
      return '';
    }
    if (name === 'option:local') {
      const key = String(arg0 ?? '');
      const val = String(arg1 ?? '');
      if (key === 'access_token' && (!val || val === '')) {
        purgeAccountCredentials(store);
        return '';
      }
      store.set(`option:local:${key}`, val);
    }
    return '';
  }

  // 1. Dispatch account_logout
  store.set('option:local:access_token', 'CANARY_DISPATCH_TOKEN_1', true);
  store.set('account_auth_result', 'CANARY_DISPATCH_RESULT_1', true);
  runtimeDispatch('account_logout');
  assert.equal(store.get('option:local:access_token'), '');
  assert.equal(mockStorage.getItem('camellia.web.option:local:access_token'), null);

  // 2. Dispatch empty option:local:access_token
  store.set('option:local:access_token', 'CANARY_DISPATCH_TOKEN_2', true);
  store.set('option:access_token', 'CANARY_DISPATCH_TOKEN_2', true);
  runtimeDispatch('option:local', 'access_token', '');
  assert.equal(store.get('option:local:access_token'), '');
  assert.equal(store.get('option:access_token'), '');
  assert.equal(mockStorage.getItem('camellia.web.option:local:access_token'), null);
  assert.equal(mockStorage.getItem('camellia.web.option:access_token'), null);
});

test('STRESS CRED-004: Custom StorageLike adapter with spy instrumentation', () => {
  const removedKeys: string[] = [];
  const storageData = new Map<string, unknown>();

  const spyStore: StorageLike = {
    remove(key: string, persist?: boolean): void {
      removedKeys.push(`${key}:${persist}`);
      storageData.delete(key);
    },
    getJson<T>(key: string, fallback: T): T {
      return (storageData.get(key) as T) ?? fallback;
    },
    setJson(key: string, value: unknown): void {
      storageData.set(key, value);
    }
  };

  storageData.set('options', { access_token: 'SECRET_TOKEN', keep_this: 123 });

  purgeAccountCredentials(spyStore);

  assert.ok(removedKeys.includes('option:local:access_token:true'));
  assert.ok(removedKeys.includes('option:access_token:true'));
  assert.ok(removedKeys.includes('account_auth_result:true'));
  assert.ok(removedKeys.includes('option:local:user_info:true'));

  const options = spyStore.getJson<Record<string, unknown>>('options', {});
  assert.equal(options.access_token, undefined);
  assert.equal(options.keep_this, 123);
});
