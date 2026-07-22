export type MediaKind = 'image' | 'video';

export interface ServerSettings {
  baseUrl: string;
  token: string;
}

export interface ServerInfo {
  name: string;
  version: string;
  apiVersion: string;
  capabilities: string[];
}

export interface PairingPayload {
  version: number;
  baseUrl: string;
  serverName: string;
  pairingId: string;
  secret: string;
  expiresAt: string;
}

export interface PairingClaimResponse {
  device: {
    id: string;
    name: string;
    platform: string;
  };
  token: string;
}

export interface MediaItem {
  id: string;
  libraryId: string;
  relativePath: string;
  folderPath: string;
  fileName: string;
  type: MediaKind;
  mimeType: string;
  sizeBytes: number;
  modifiedAt: string;
  capturedAt: string;
  capturedAtSource: string;
  width: number;
  height: number;
  durationMs: number;
  codec: string;
  latitude?: number;
  longitude?: number;
  cameraModel: string;
  metadataStatus: string;
  metadataError: string;
  favorite: boolean;
  rating: number;
  thumbnailUrl: string;
  originalUrl: string;
  streamUrl: string;
}

export interface MediaPage {
  items: MediaItem[];
  total: number;
  limit: number;
  offset: number;
  nextCursor?: string;
  hasMore: boolean;
}

export interface MediaQuery {
  type?: MediaKind;
  search?: string;
  favorite?: boolean;
  cursor?: string;
  limit?: number;
}
