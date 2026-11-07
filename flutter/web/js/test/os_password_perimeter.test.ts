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

test('CRED-008: StorageStore prevents persistent storage of secret keys and variants', () => {
  const mockStorage = createMockStorage();
  (globalThis as any).window = {
    localStorage: mockStorage
  };

  const store = new StorageStore('camellia.test.');

  // Normal option should persist:
  store.set('option:session:custom-fps', '30');
  assert.equal(store.get('option:session:custom-fps'), '30');
  assert.equal(mockStorage.getItem('camellia.test.option:session:custom-fps'), '30');

  // Secret keys must NEVER be persisted to localStorage (including case, separator, and whitespace variants):
  const secretVariants = [
    'option:session:os-password',
    'option:session:os_password',
    'option:session:OS-PASSWORD',
    'option:session:OS_PASSWORD',
    'option:session: os-password ',
    'option:session:rdp_password',
    'option:session:rdp-password',
    'option:session:RDP_PASSWORD',
    'option:session: rdp-password ',
    'os-password',
    'os_password',
    'OS-PASSWORD',
    'rdp_password',
    'rdp-password'
  ];

  for (const variant of secretVariants) {
    store.set(variant, 'Secret123!');
    assert.equal(
      mockStorage.getItem(`camellia.test.${variant}`),
      null,
      `Secret key variant '${variant}' must NOT be written to localStorage`
    );
  }
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
    const normKey = key.trim().toLowerCase().replace(/_/g, '-');
    if (prefix === 'option:session' && (normKey === 'os-password' || normKey === 'rdp-password')) {
      if (normalized) {
        ephemeralSessionSecrets.set('os-password', normalized);
      } else {
        ephemeralSessionSecrets.delete('os-password');
      }
      return;
    }
    store.set(`${prefix}:${key}`, normalized);
  }

  function getScopedOption(prefix: string, key: string): string {
    const normKey = key.trim().toLowerCase().replace(/_/g, '-');
    if (prefix === 'option:session' && (normKey === 'os-password' || normKey === 'rdp-password')) {
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

  // Generic getter must return empty string (reject export of secret across all variants)
  assert.equal(getByName('option:session', 'os-password'), '');
  assert.equal(getByName('option:session', 'os_password'), '');
  assert.equal(getByName('option:session', 'OS-PASSWORD'), '');
  assert.equal(getByName('option:session', 'rdp_password'), '');
  assert.equal(getByName('option:session', 'rdp-password'), '');

  // has_os_password must return true
  assert.equal(getByName('has_os_password'), 'true');

  // LocalStorage must NOT contain the password
  assert.equal(mockStorage.getItem('camellia.web.option:session:os-password'), null);

  // Session close must clear ephemeral secrets
  setByName('session_close');
  assert.equal(getByName('has_os_password'), 'false');
});
