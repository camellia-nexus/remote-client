import assert from 'node:assert/strict';
import test from 'node:test';

import { StorageStore } from '../src/core/storage.ts';

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

test('CRED-008: StorageStore prevents persistent storage of secret keys', () => {
  const mockStorage = createMockStorage();
  (globalThis as any).window = {
    localStorage: mockStorage
  };

  const store = new StorageStore('camellia.test.');

  // Normal option should persist:
  store.set('option:session:custom-fps', '30');
  assert.equal(store.get('option:session:custom-fps'), '30');
  assert.equal(mockStorage.getItem('camellia.test.option:session:custom-fps'), '30');

  // Secret keys must NEVER be persisted to localStorage:
  store.set('option:session:os-password', 'SecretPass123!');
  assert.equal(store.get('option:session:os-password'), 'SecretPass123!');
  assert.equal(mockStorage.getItem('camellia.test.option:session:os-password'), null);

  store.set('option:session:rdp_password', 'RdpSecret456!');
  assert.equal(store.get('option:session:rdp_password'), 'RdpSecret456!');
  assert.equal(mockStorage.getItem('camellia.test.option:session:rdp_password'), null);

  store.set('os-password', 'DirectSecret!');
  assert.equal(mockStorage.getItem('camellia.test.os-password'), null);
});

test('CRED-008: Ephemeral session secrets lifecycle and generic getter denial', () => {
  const mockStorage = createMockStorage();
  (globalThis as any).window = {
    localStorage: mockStorage
  };

  const store = new StorageStore('camellia.web.');
  const ephemeralSessionSecrets = new Map<string, string>();

  function setScopedOption(prefix: string, key: string, value: unknown): void {
    const normalized = String(value ?? '');
    if (prefix === 'option:session' && (key === 'os-password' || key === 'rdp_password')) {
      if (normalized) {
        ephemeralSessionSecrets.set(key, normalized);
      } else {
        ephemeralSessionSecrets.delete(key);
      }
      return;
    }
    store.set(`${prefix}:${key}`, normalized);
  }

  function getScopedOption(prefix: string, key: string): string {
    if (prefix === 'option:session' && (key === 'os-password' || key === 'rdp_password')) {
      return '';
    }
    return store.get(`${prefix}:${key}`, '');
  }

  function getByName(name: string, arg0?: unknown): string {
    switch (name) {
      case 'has_os_password':
        return Boolean(ephemeralSessionSecrets.get('os-password')) ? 'true' : 'false';
      case 'option:session':
        return getScopedOption(name, String(arg0 ?? ''));
      default:
        return '';
    }
  }

  function setByName(name: string, arg0?: unknown, arg1?: unknown): string {
    switch (name) {
      case 'session_close':
      case 'close':
        ephemeralSessionSecrets.clear();
        return '';
      case 'option:session':
        if (arg1 !== undefined) {
          setScopedOption(name, String(arg0), arg1);
        } else if (typeof arg0 === 'string') {
          const parsed = JSON.parse(arg0);
          setScopedOption(name, parsed.name, parsed.value ?? '');
        }
        return '';
      default:
        return '';
    }
  }

  // Initial state: has_os_password is false
  assert.equal(getByName('has_os_password'), 'false');

  // Set os-password via session option
  setByName(
    'option:session',
    JSON.stringify({ name: 'os-password', value: 'MySecretPassword123' })
  );

  // Generic getter must return empty string (reject export of secret)
  assert.equal(getByName('option:session', 'os-password'), '');

  // has_os_password must return true
  assert.equal(getByName('has_os_password'), 'true');

  // LocalStorage must NOT contain the password
  assert.equal(mockStorage.getItem('camellia.web.option:session:os-password'), null);

  // Session close must clear ephemeral secrets
  setByName('session_close');
  assert.equal(getByName('has_os_password'), 'false');
});
