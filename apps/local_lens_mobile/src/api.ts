import type {
  MediaItem,
  MediaPage,
  MediaQuery,
  PairingClaimResponse,
  PairingPayload,
  ServerInfo,
  ServerSettings,
} from './types';
import { normalizeBaseUrl } from './storage';

const REQUEST_TIMEOUT_MS = 25_000;

export class ApiError extends Error {
  constructor(
    message: string,
    readonly statusCode?: number,
  ) {
    super(message);
    this.name = 'ApiError';
  }
}

export class LocalLensApi {
  readonly settings: ServerSettings;

  constructor(settings: ServerSettings) {
    this.settings = {
      baseUrl: normalizeBaseUrl(settings.baseUrl),
      token: settings.token.trim(),
    };
  }

  get authorizationHeaders(): Record<string, string> {
    return { Authorization: `Bearer ${this.settings.token}` };
  }

  resolve(path: string): string {
    if (/^https?:\/\//i.test(path)) {
      return path;
    }
    return `${this.settings.baseUrl}${path.startsWith('/') ? path : `/${path}`}`;
  }

  mediaSource(path: string): { uri: string; headers: Record<string, string> } {
    return {
      uri: this.resolve(path),
      headers: this.authorizationHeaders,
    };
  }

  async verify(): Promise<ServerInfo> {
    const server = await this.request<ServerInfo>('/api/v1/server', {
      authenticated: false,
    });
    if (server.apiVersion !== 'v1') {
      throw new ApiError(`服务器 API 版本不受支持：${server.apiVersion}`);
    }
    await this.listMedia({ limit: 1 });
    return server;
  }

  async listMedia(query: MediaQuery = {}): Promise<MediaPage> {
    const params = new URLSearchParams();
    params.set('limit', String(query.limit ?? 60));
    params.set('sort', 'timeline');
    if (query.type) params.set('type', query.type);
    if (query.search?.trim()) params.set('q', query.search.trim());
    if (query.favorite) params.set('favorite', 'true');
    if (query.cursor) params.set('cursor', query.cursor);
    else params.set('offset', '0');

    return this.request<MediaPage>(`/api/v1/media?${params.toString()}`);
  }

  async setFavorite(mediaId: string, favorite: boolean): Promise<MediaItem> {
    return this.request<MediaItem>(`/api/v1/media/${encodeURIComponent(mediaId)}/favorite`, {
      method: favorite ? 'PUT' : 'DELETE',
    });
  }

  async request<T>(
    path: string,
    options: {
      method?: string;
      authenticated?: boolean;
      body?: unknown;
    } = {},
  ): Promise<T> {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
    const headers: Record<string, string> = { Accept: 'application/json' };
    if (options.authenticated !== false) {
      Object.assign(headers, this.authorizationHeaders);
    }
    if (options.body !== undefined) {
      headers['Content-Type'] = 'application/json';
    }

    const requestInit: RequestInit = {
      method: options.method ?? 'GET',
      headers,
      signal: controller.signal,
    };
    if (options.body !== undefined) {
      requestInit.body = JSON.stringify(options.body);
    }

    try {
      const response = await fetch(this.resolve(path), requestInit);
      const raw = await response.text();
      if (!response.ok) {
        throw new ApiError(extractErrorMessage(raw), response.status);
      }
      if (!raw.trim()) {
        return {} as T;
      }
      try {
        return JSON.parse(raw) as T;
      } catch {
        throw new ApiError('服务器返回了无法解析的数据');
      }
    } catch (error) {
      if (error instanceof ApiError) throw error;
      if (error instanceof Error && error.name === 'AbortError') {
        throw new ApiError('请求超时，请检查局域网连接和服务器状态');
      }
      throw new ApiError(error instanceof Error ? `无法连接服务器：${error.message}` : '无法连接服务器');
    } finally {
      clearTimeout(timeout);
    }
  }
}

export function parsePairingPayload(raw: string): PairingPayload {
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    throw new ApiError('二维码不是有效的 LocalLens 配对信息');
  }

  if (!value || typeof value !== 'object') {
    throw new ApiError('二维码内容格式无效');
  }

  const payload = value as Partial<PairingPayload>;
  if (payload.version !== 1) {
    throw new ApiError('不支持的配对二维码版本');
  }
  if (!payload.baseUrl || !payload.pairingId || !payload.secret || !payload.expiresAt) {
    throw new ApiError('配对二维码缺少必要字段');
  }
  if (Date.now() > Date.parse(payload.expiresAt)) {
    throw new ApiError('二维码已经过期，请在 Windows 管理端重新生成');
  }

  return {
    version: 1,
    baseUrl: normalizeBaseUrl(payload.baseUrl),
    serverName: payload.serverName || 'LocalLens',
    pairingId: payload.pairingId,
    secret: payload.secret,
    expiresAt: payload.expiresAt,
  };
}

export async function claimPairing(
  payload: PairingPayload,
  deviceName: string,
  platform: string,
): Promise<ServerSettings> {
  const api = new LocalLensApi({ baseUrl: payload.baseUrl, token: '' });
  const result = await api.request<PairingClaimResponse>('/api/v1/pairing/claim', {
    method: 'POST',
    authenticated: false,
    body: {
      pairingId: payload.pairingId,
      secret: payload.secret,
      deviceName,
      platform,
    },
  });

  if (!result.token) {
    throw new ApiError('服务器没有返回设备 Token');
  }

  return {
    baseUrl: payload.baseUrl,
    token: result.token,
  };
}

function extractErrorMessage(raw: string): string {
  const fallback = raw.trim() || '请求失败';
  try {
    const parsed = JSON.parse(raw) as Record<string, unknown>;
    const message = parsed.message ?? parsed.error ?? parsed.detail;
    return typeof message === 'string' && message.trim() ? message : fallback;
  } catch {
    return fallback;
  }
}
