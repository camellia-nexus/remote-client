export interface StorageLike {
  remove(key: string, persist?: boolean): void;
  getJson<T>(key: string, fallback: T): T;
  setJson(key: string, value: unknown): void;
}

export function purgeAccountCredentials(store: StorageLike): void {
  store.remove('option:local:access_token', true);
  store.remove('option:access_token', true);
  store.remove('account_auth_result', true);
  store.remove('option:local:user_info', true);
  const options = store.getJson<Record<string, string>>('options', {});
  if ('access_token' in options) {
    delete options['access_token'];
    store.setJson('options', options);
  }
}
