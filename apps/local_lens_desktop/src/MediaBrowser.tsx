import { FormEvent, useCallback, useEffect, useMemo, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';

interface MediaStats {
  total: number;
  images: number;
  videos: number;
  favorites: number;
  sizeBytes: number;
  metadataPending: number;
  thumbnailsPending: number;
  transcodesPending: number;
}

interface LibraryInfo {
  id: string;
  name: string;
  recursive: boolean;
  enabled: boolean;
  lastScannedAt?: string | null;
  mediaCount: number;
}

interface MediaItem {
  id: string;
  libraryId: string;
  relativePath: string;
  folderPath: string;
  fileName: string;
  type: 'image' | 'video';
  mimeType: string;
  sizeBytes: number;
  modifiedAt: string;
  capturedAt: string;
  capturedAtSource: string;
  width: number;
  height: number;
  durationMs: number;
  codec: string;
  cameraModel: string;
  metadataStatus: string;
  metadataError: string;
  favorite: boolean;
  rating: number;
}

interface MediaPage {
  items: MediaItem[];
  total: number;
  limit: number;
  offset: number;
  nextCursor?: string | null;
  hasMore: boolean;
}

interface ScanStatus {
  running: boolean;
  current: string;
  discovered: number;
  indexed: number;
  failed: number;
  errorMessage: string;
}

interface MediaBrowserProps {
  running: boolean;
  refreshKey: number;
  onMessage: (message: string) => void;
}

type BinaryPayload = ArrayBuffer | Uint8Array | number[];

const emptyStats: MediaStats = {
  total: 0,
  images: 0,
  videos: 0,
  favorites: 0,
  sizeBytes: 0,
  metadataPending: 0,
  thumbnailsPending: 0,
  transcodesPending: 0,
};

function binaryBytes(payload: BinaryPayload) {
  if (payload instanceof ArrayBuffer) return new Uint8Array(payload);
  if (payload instanceof Uint8Array) return payload;
  return new Uint8Array(payload);
}

function formatBytes(value: number) {
  if (!Number.isFinite(value) || value <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  const index = Math.min(units.length - 1, Math.floor(Math.log(value) / Math.log(1024)));
  return `${(value / 1024 ** index).toFixed(index === 0 ? 0 : 1)} ${units[index]}`;
}

function formatDuration(value: number) {
  if (!value) return '';
  const total = Math.floor(value / 1000);
  const minutes = Math.floor(total / 60);
  const seconds = total % 60;
  return `${minutes}:${seconds.toString().padStart(2, '0')}`;
}

function formatDate(value: string) {
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? value : date.toLocaleString();
}

function MediaThumbnail({ item, width = 480 }: { item: MediaItem; width?: number }) {
  const [url, setUrl] = useState('');
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    let active = true;
    let objectUrl = '';
    setFailed(false);
    void invoke<BinaryPayload>('desktop_media_bytes', {
      id: item.id,
      thumbnail: true,
      width,
    }).then((payload) => {
      if (!active) return;
      objectUrl = URL.createObjectURL(new Blob([binaryBytes(payload)], { type: 'image/jpeg' }));
      setUrl(objectUrl);
    }).catch(() => {
      if (active) setFailed(true);
    });
    return () => {
      active = false;
      if (objectUrl) URL.revokeObjectURL(objectUrl);
    };
  }, [item.id, item.modifiedAt, width]);

  if (failed) return <div className="media-thumb-placeholder">无法生成缩略图</div>;
  if (!url) return <div className="media-thumb-placeholder loading">正在生成缩略图…</div>;
  return <img src={url} alt={item.fileName} loading="lazy" />;
}

function MediaPreview({ item, onClose }: { item: MediaItem; onClose: () => void }) {
  const [url, setUrl] = useState('');
  const [error, setError] = useState('');

  useEffect(() => {
    if (item.type !== 'image') return undefined;
    let active = true;
    let objectUrl = '';
    void invoke<BinaryPayload>('desktop_media_bytes', {
      id: item.id,
      thumbnail: false,
      width: 0,
    }).then((payload) => {
      if (!active) return;
      objectUrl = URL.createObjectURL(new Blob([binaryBytes(payload)], { type: item.mimeType || 'image/jpeg' }));
      setUrl(objectUrl);
    }).catch((reason) => {
      if (active) setError(String(reason));
    });
    return () => {
      active = false;
      if (objectUrl) URL.revokeObjectURL(objectUrl);
    };
  }, [item]);

  return (
    <div className="media-preview-backdrop" onClick={onClose} role="presentation">
      <div className="media-preview" onClick={(event) => event.stopPropagation()} role="dialog" aria-modal="true">
        <button className="media-preview-close" onClick={onClose}>关闭</button>
        <div className="media-preview-stage">
          {item.type === 'image' && url && <img src={url} alt={item.fileName} />}
          {item.type === 'image' && !url && !error && <div className="media-thumb-placeholder loading">正在读取原图…</div>}
          {item.type === 'video' && <><MediaThumbnail item={item} width={960} /><div className="video-preview-note">桌面端当前展示视频封面与信息；视频播放可在 Android 客户端中使用直接播放或 HLS。</div></>}
          {error && <div className="empty-state">读取媒体失败：{error}</div>}
        </div>
        <div className="media-preview-info">
          <strong>{item.fileName}</strong>
          <span>{item.relativePath}</span>
          <small>{item.width > 0 ? `${item.width} × ${item.height}` : '尺寸待提取'} · {formatBytes(item.sizeBytes)}{item.durationMs > 0 ? ` · ${formatDuration(item.durationMs)}` : ''}</small>
        </div>
      </div>
    </div>
  );
}

export default function MediaBrowser({ running, refreshKey, onMessage }: MediaBrowserProps) {
  const [stats, setStats] = useState<MediaStats>(emptyStats);
  const [libraries, setLibraries] = useState<LibraryInfo[]>([]);
  const [items, setItems] = useState<MediaItem[]>([]);
  const [total, setTotal] = useState(0);
  const [offset, setOffset] = useState(0);
  const [loading, setLoading] = useState(false);
  const [search, setSearch] = useState('');
  const [submittedSearch, setSubmittedSearch] = useState('');
  const [kind, setKind] = useState('');
  const [libraryId, setLibraryId] = useState('');
  const [favoriteOnly, setFavoriteOnly] = useState(false);
  const [sort, setSort] = useState('timeline');
  const [preview, setPreview] = useState<MediaItem | null>(null);
  const [scan, setScan] = useState<ScanStatus | null>(null);
  const limit = 48;

  const query = useMemo(() => ({
    type: kind || undefined,
    q: submittedSearch || undefined,
    libraryId: libraryId || undefined,
    favorite: favoriteOnly,
    sort,
    limit,
    offset,
  }), [favoriteOnly, kind, libraryId, offset, sort, submittedSearch]);

  const loadOverview = useCallback(async () => {
    if (!running) {
      setStats(emptyStats);
      setLibraries([]);
      return;
    }
    try {
      const [nextStats, nextLibraries] = await Promise.all([
        invoke<MediaStats>('desktop_stats'),
        invoke<LibraryInfo[]>('desktop_libraries'),
      ]);
      setStats(nextStats);
      setLibraries(nextLibraries);
    } catch (error) {
      onMessage(`读取媒体概览失败：${String(error)}`);
    }
  }, [onMessage, running]);

  const loadMedia = useCallback(async () => {
    if (!running) {
      setItems([]);
      setTotal(0);
      return;
    }
    setLoading(true);
    try {
      const page = await invoke<MediaPage>('desktop_media_page', { query });
      setItems(page.items ?? []);
      setTotal(page.total ?? 0);
    } catch (error) {
      setItems([]);
      setTotal(0);
      onMessage(`读取媒体内容失败：${String(error)}`);
    } finally {
      setLoading(false);
    }
  }, [onMessage, query, running]);

  useEffect(() => {
    void loadOverview();
  }, [loadOverview, refreshKey]);

  useEffect(() => {
    void loadMedia();
  }, [loadMedia, refreshKey]);

  useEffect(() => {
    if (!running || !scan?.running) return undefined;
    const timer = window.setInterval(() => {
      void invoke<ScanStatus>('desktop_scan_status').then((next) => {
        setScan(next);
        if (!next.running) {
          void loadOverview();
          void loadMedia();
          onMessage(next.errorMessage ? `扫描完成，但存在错误：${next.errorMessage}` : `扫描完成，已索引 ${next.indexed} 个媒体文件`);
        }
      });
    }, 1000);
    return () => window.clearInterval(timer);
  }, [loadMedia, loadOverview, onMessage, running, scan?.running]);

  const submitSearch = (event: FormEvent) => {
    event.preventDefault();
    setOffset(0);
    setSubmittedSearch(search.trim());
  };

  const changeFilter = (callback: () => void) => {
    setOffset(0);
    callback();
  };

  const startScan = async () => {
    try {
      const started = await invoke<boolean>('desktop_start_scan');
      const next = await invoke<ScanStatus>('desktop_scan_status');
      setScan(next);
      onMessage(started ? '已开始扫描媒体库' : '媒体库扫描已经在进行中');
    } catch (error) {
      onMessage(`启动扫描失败：${String(error)}`);
    }
  };

  const updateFavorite = async (item: MediaItem) => {
    try {
      const updated = await invoke<MediaItem>('desktop_set_favorite', { id: item.id, favorite: !item.favorite });
      setItems((current) => current.map((value) => value.id === item.id ? updated : value));
      setStats((current) => ({ ...current, favorites: current.favorites + (updated.favorite ? 1 : -1) }));
    } catch (error) {
      onMessage(`更新收藏失败：${String(error)}`);
    }
  };

  const updateRating = async (item: MediaItem, rating: number) => {
    try {
      const updated = await invoke<MediaItem>('desktop_set_rating', { id: item.id, rating });
      setItems((current) => current.map((value) => value.id === item.id ? updated : value));
    } catch (error) {
      onMessage(`更新评分失败：${String(error)}`);
    }
  };

  return (
    <section className="config-panel media-browser-panel">
      <div className="section-heading">
        <div><span className="eyebrow">WINDOWS 媒体库</span><h3>图片与视频</h3></div>
        <div className="actions">
          <button className="secondary" disabled={!running || Boolean(scan?.running)} onClick={() => void startScan()}>{scan?.running ? '扫描中…' : '重新扫描'}</button>
          <button className="secondary" disabled={!running || loading} onClick={() => { void loadOverview(); void loadMedia(); }}>刷新内容</button>
        </div>
      </div>

      {!running && <div className="empty-state">Rust 服务启动后，这里会显示媒体库中的图片和视频。</div>}
      {running && (
        <>
          <div className="media-stats-grid">
            <article><span>全部媒体</span><strong>{stats.total}</strong><small>{formatBytes(stats.sizeBytes)}</small></article>
            <article><span>图片</span><strong>{stats.images}</strong><small>已索引图片</small></article>
            <article><span>视频</span><strong>{stats.videos}</strong><small>已索引视频</small></article>
            <article><span>收藏</span><strong>{stats.favorites}</strong><small>收藏内容</small></article>
          </div>

          {scan?.running && <div className="scan-progress">正在扫描 {scan.current || '媒体库'}：发现 {scan.discovered}，已索引 {scan.indexed}，失败 {scan.failed}</div>}

          <form className="media-toolbar" onSubmit={submitSearch}>
            <div className="media-search"><input value={search} onChange={(event) => setSearch(event.target.value)} placeholder="搜索文件名或相对路径" /><button className="primary" type="submit">搜索</button></div>
            <select value={kind} onChange={(event) => changeFilter(() => setKind(event.target.value))}><option value="">全部类型</option><option value="image">图片</option><option value="video">视频</option></select>
            <select value={libraryId} onChange={(event) => changeFilter(() => setLibraryId(event.target.value))}><option value="">全部媒体库</option>{libraries.map((library) => <option key={library.id} value={library.id}>{library.name}（{library.mediaCount}）</option>)}</select>
            <select value={sort} onChange={(event) => changeFilter(() => setSort(event.target.value))}><option value="timeline">拍摄时间</option><option value="modified">修改时间</option><option value="name">文件名</option></select>
            <label className="media-favorite-filter"><input type="checkbox" checked={favoriteOnly} onChange={(event) => changeFilter(() => setFavoriteOnly(event.target.checked))} />只看收藏</label>
          </form>

          {loading && <div className="empty-state">正在读取媒体内容…</div>}
          {!loading && items.length === 0 && <div className="empty-state">当前筛选条件下没有媒体。首次添加文件夹后，请点击“重新扫描”。</div>}
          {!loading && items.length > 0 && (
            <div className="media-grid">
              {items.map((item) => (
                <article className="media-card" key={item.id}>
                  <button className="media-thumb-button" onClick={() => setPreview(item)} title="查看媒体">
                    <MediaThumbnail item={item} />
                    {item.type === 'video' && <span className="media-duration">{formatDuration(item.durationMs) || '视频'}</span>}
                  </button>
                  <div className="media-card-body">
                    <strong title={item.fileName}>{item.fileName}</strong>
                    <span title={item.relativePath}>{item.folderPath || '媒体库根目录'}</span>
                    <small>{item.width > 0 ? `${item.width} × ${item.height}` : item.metadataStatus === 'pending' ? '元数据处理中' : '尺寸未知'} · {formatBytes(item.sizeBytes)}</small>
                    <div className="media-card-actions">
                      <button className={item.favorite ? 'favorite active' : 'favorite'} onClick={() => void updateFavorite(item)}>{item.favorite ? '★ 已收藏' : '☆ 收藏'}</button>
                      <select aria-label="评分" value={item.rating} onChange={(event) => void updateRating(item, Number(event.target.value))}><option value="0">未评分</option><option value="1">★</option><option value="2">★★</option><option value="3">★★★</option><option value="4">★★★★</option><option value="5">★★★★★</option></select>
                    </div>
                  </div>
                </article>
              ))}
            </div>
          )}

          <div className="media-pagination">
            <span>共 {total} 项，第 {total === 0 ? 0 : Math.floor(offset / limit) + 1} / {Math.max(1, Math.ceil(total / limit))} 页</span>
            <div className="actions"><button className="secondary" disabled={offset <= 0 || loading} onClick={() => setOffset(Math.max(0, offset - limit))}>上一页</button><button className="secondary" disabled={offset + limit >= total || loading} onClick={() => setOffset(offset + limit)}>下一页</button></div>
          </div>
        </>
      )}

      {preview && <MediaPreview item={preview} onClose={() => setPreview(null)} />}
    </section>
  );
}
