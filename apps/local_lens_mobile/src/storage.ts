import * as SecureStore from 'expo-secure-store';

import type { ServerSettings } from './types';

const BASE_URL_KEY = 'local-lens.base-url';
const TOKEN_KEY = 'local-lens.device-token';

export function normalizeBaseUrl(value: string): string {
  return value.trim().replace(/\/+$/, '');
}

export async function loadSettings(): Promise<ServerSettings | null> {
  const [baseUrl, token] = await Promise.all([
    SecureStore.getItemAsync(BASE_URL_KEY),
    SecureStore.getItemAsync(TOKEN_KEY),
  ]);

  if (!baseUrl || !token) {
    return null;
  }

  return {
    baseUrl: normalizeBaseUrl(baseUrl),
    token,
  };
}

export async function saveSettings(settings: ServerSettings): Promise<void> {
  const normalized = normalizeBaseUrl(settings.baseUrl);
  await Promise.all([
    SecureStore.setItemAsync(BASE_URL_KEY, normalized),
    SecureStore.setItemAsync(TOKEN_KEY, settings.token),
  ]);
}

export async function clearSettings(): Promise<void> {
  await Promise.all([
    SecureStore.deleteItemAsync(BASE_URL_KEY),
    SecureStore.deleteItemAsync(TOKEN_KEY),
  ]);
}
