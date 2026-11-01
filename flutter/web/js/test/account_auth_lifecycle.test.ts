import assert from 'node:assert/strict';
import test from 'node:test';

import { StorageStore } from '../src/core/storage.ts';
import { purgeAccountCredentials } from '../src/runtime/account_credentials.ts';

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

test('purgeAccountCredentials removes tokens from memory and localStorage', () => {
  const mockStorage = createMockStorage();
  (globalThis as any).window = {
    localStorage: mockStorage
  };

  const store = new StorageStore('camellia.web.');

  // Populate credentials simulating active session
  store.set('option:local:access_token', 'canary_access_token_123', true);
  store.set('option:access_token', 'canary_access_token_123', true);
  store.set('account_auth_result', '{"access_token":"canary"}', false);
  store.set('option:local:user_info', '{"name":"test"}', true);
  store.setJson('options', { access_token: 'canary_access_token_123', other: 'kept' });

  assert.equal(store.get('option:local:access_token'), 'canary_access_token_123');
  assert.equal(store.get('option:access_token'), 'canary_access_token_123');
  assert.equal(mockStorage.getItem('camellia.web.option:local:access_token'), 'canary_access_token_123');
  assert.equal(mockStorage.getItem('camellia.web.option:access_token'), 'canary_access_token_123');

  // Purge account credentials
  purgeAccountCredentials(store);

  assert.equal(store.get('option:local:access_token'), '');
  assert.equal(store.get('option:access_token'), '');
  assert.equal(store.get('account_auth_result'), '');
  assert.equal(store.get('option:local:user_info'), '');
  assert.equal(mockStorage.getItem('camellia.web.option:local:access_token'), null);
  assert.equal(mockStorage.getItem('camellia.web.option:access_token'), null);
  assert.equal(mockStorage.getItem('camellia.web.account_auth_result'), null);
  assert.deepEqual(store.getJson('options', {}), { other: 'kept' });
});
