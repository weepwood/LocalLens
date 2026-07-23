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

interface FolderInfo {
  id: string;
  libraryId: string;
  path: string;
  parentPath: string;
  name: string;
  mediaCount: number;
  childCount: number;
}

interface Album {
  id: string;
  name: string;
  description: string;
  itemCount: number;
  createdAt: string;
  updatedAt: string;
}

interface Tag {
  id: string;
  name: string;
  color: string;
  itemCount: number;
  createdAt: string;
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

interface MediaCollections {
  albumIds: string[];
  tagIds: string[];
}

interface BatchMediaResult {
  updated: number;
  failed: string[];
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

type BatchPatch = {
  favorite?: boolean;
  rating?: number;
  albumId?: string;
  tagId?: string;
  addToCollection?: boolean;
};

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

function binaryBuffer(payload: BinaryPayload): ArrayBuffer {
  const source = payload instanceof ArrayBuffer
    ? new Uint8Array(payload)
    : payload instanceof Uint8Array
      ? payload
      : new Uint8Array(payload);
  const copy = new Uint8Array(source.byteLength);
  copy.set(source);
  return copy.buffer;
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
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const seconds = total % 60;
  return hours > 0
    ? `${hours}:${minutes.toString().padStart(2, '0')}:${seconds.toString().padStart(2, '0')}`
    : `${minutes}:${seconds.toString().padStart(2, '0')}`;
}

function formatDate(value?: string | null) {
  if (!value) return '未知';
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
    setUrl('');
    void invoke<BinaryPayload>('desktop_media_bytes', {
      id: item.id,
      thumbnail: true,
      width,
    }).then((payload) => {
      if (!active) return;
      objectUrl = URL.createObjectURL(new Blob([binaryBuffer(payload)], { type: 'image/jpeg' }));
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

interface MediaPreviewProps {
  item: MediaItem;
  albums: Album[];
  tags: Tag[];
  onClose: () => void;
  onChanged: () => void;
  onMessage: (message: string) => void;
}

function MediaPreview({ item, albums, tags, onClose, onChanged, onMessage }: MediaPreviewProps) {
  const [url, setUrl] = useState('');
  const [error, setError] = useState('');
  const [collections, setCollections] = useState<MediaCollections>({ albumIds: [], tagIds: [] });
  const [collectionBusy, setCollectionBusy] = useState(false);

  useEffect(() => {
    let active = true;
    void invoke<MediaCollections>('desktop_media_collections', { id: item.id })
      .then((value) => {
        if (active) setCollections(value);
      })
      .catch((reason) => {
        if (active) onMessage(`读取媒体归属失败：${String(reason)}`);
      });
    return () => {
      active = false;
    };
  }, [item.id, onMessage]);

  useEffect(() => {
    if (item.type !== 'image') return undefined;
    let active = true;
    let objectUrl = '';
    setError('');
    setUrl('');
    void invoke<BinaryPayload>('desktop_media_bytes', {
      id: item.id,
      thumbnail: false,
      width: 0,
    }).then((payload) => {
      if (!active) return;
      objectUrl = URL.createObjectURL(new Blob([binaryBuffer(payload)], { type: item.mimeType || 'image/jpeg' }));
      setUrl(objectUrl);
    }).catch((reason) => {
      if (active) setError(String(reason));
    });
    return () => {
      active = false;
      if (objectUrl) URL.revokeObjectURL(objectUrl);
    };
  }, [item]);

  const toggleAlbum = async (album: Album) => {
    const add = !collections.albumIds.includes(album.id);
    setCollectionBusy(true);
    try {
      await invoke('desktop_set_album_item', { albumId: album.id, mediaId: item.id, add });
      setCollections((current) => ({
        ...current,
        albumIds: add
          ? [...current.albumIds, album.id]
          : current.albumIds.filter((id) => id !== album.id),
      }));
      onChanged();
    } catch (reason) {
      onMessage(`更新相册归属失败：${String(reason)}`);
    } finally {
      setCollectionBusy(false);
    }
  };

  const toggleTag = async (tag: Tag) => {
    const add = !collections.tagIds.includes(tag.id);
    setCollectionBusy(true);
    try {
      await invoke('desktop_set_media_tag', { mediaId: item.id, tagId: tag.id, add });
      setCollections((current) => ({
        ...current,
        tagIds: add
          ? [...current.tagIds, tag.id]
          : current.tagIds.filter((id) => id !== tag.id),
      }));
      onChanged();
    } catch (reason) {
      onMessage(`更新标签失败：${String(reason)}`);
    } finally {
      setCollectionBusy(false);
    }
  };

  const reveal = async () => {
    try {
      await invoke('desktop_reveal_media', { id: item.id });
      onMessage(`已在资源管理器中定位“${item.fileName}”`);
    } catch (reason) {
      onMessage(`定位原文件失败：${String(reason)}`);
    }
  };

  return (
    <div className="media-preview-backdrop" onClick={onClose} role="presentation">
      <div className="media-preview media-preview-with-inspector" onClick={(event) => event.stopPropagation()} role="dialog" aria-modal="true">
        <button className="media-preview-close" onClick={onClose}>关闭</button>
        <div className="media-preview-stage">
          {item.type === 'image' && url && <img src={url} alt={item.fileName} />}
          {item.type === 'image' && !url && !error && <div className="media-thumb-placeholder loading">正在读取原图…</div>}
          {item.type === 'video' && (
            <>
              <MediaThumbnail item={item} width={960} />
              <div className="video-preview-note">当前展示视频封面与整理信息；视频仍可通过 Android 客户端直接播放或 HLS 播放。</div>
            </>
          )}
          {error && <div className="empty-state">读取媒体失败：{error}</div>}
        </div>
        <aside className="media-inspector">
          <div className="media-inspector-heading">
            <span className="eyebrow">媒体详情</span>
            <strong title={item.fileName}>{item.fileName}</strong>
            <span title={item.relativePath}>{item.relativePath}</span>
            <button className="secondary" onClick={() => void reveal()}>在资源管理器中定位</button>
          </div>

          <dl className="media-detail-list">
            <div><dt>类型</dt><dd>{item.type === 'image' ? '图片' : '视频'} · {item.mimeType || '未知格式'}</dd></div>
            <div><dt>尺寸</dt><dd>{item.width > 0 ? `${item.width} × ${item.height}` : '待提取'}</dd></div>
            <div><dt>文件大小</dt><dd>{formatBytes(item.sizeBytes)}</dd></div>
            <div><dt>拍摄时间</dt><dd>{formatDate(item.capturedAt)}</dd></div>
            <div><dt>修改时间</dt><dd>{formatDate(item.modifiedAt)}</dd></div>
            <div><dt>相机/编码</dt><dd>{item.cameraModel || item.codec || '未知'}</dd></div>
            {item.durationMs > 0 && <div><dt>时长</dt><dd>{formatDuration(item.durationMs)}</dd></div>}
            <div><dt>元数据</dt><dd>{item.metadataStatus || '未知'}{item.metadataError ? `：${item.metadataError}` : ''}</dd></div>
          </dl>

          <section className="inspector-collections">
            <div className="sidebar-heading"><strong>相册</strong><small>点击切换归属</small></div>
            {albums.length === 0 && <p>尚未创建相册。</p>}
            <div className="collection-chip-list">
              {albums.map((album) => (
                <button
                  key={album.id}
                  className={collections.albumIds.includes(album.id) ? 'collection-chip active' : 'collection-chip'}
                  disabled={collectionBusy}
                  onClick={() => void toggleAlbum(album)}
                >
                  {collections.albumIds.includes(album.id) ? '✓ ' : ''}{album.name}
                </button>
              ))}
            </div>
          </section>

          <section className="inspector-collections">
            <div className="sidebar-heading"><strong>标签</strong><small>点击切换标签</small></div>
            {tags.length === 0 && <p>尚未创建标签。</p>}
            <div className="collection-chip-list">
              {tags.map((tag) => (
                <button
                  key={tag.id}
                  className={collections.tagIds.includes(tag.id) ? 'collection-chip active' : 'collection-chip'}
                  disabled={collectionBusy}
                  onClick={() => void toggleTag(tag)}
                >
                  <span className="tag-dot" style={{ background: tag.color || '#6675df' }} />
                  {tag.name}
                </button>
              ))}
            </div>
          </section>
        </aside>
      </div>
    </div>
  );
}

export default function MediaBrowser({ running, refreshKey, onMessage }: MediaBrowserProps) {
  const [stats, setStats] = useState<MediaStats>(emptyStats);
  const [libraries, setLibraries] = useState<LibraryInfo[]>([]);
  const [folders, setFolders] = useState<FolderInfo[]>([]);
  const [albums, setAlbums] = useState<Album[]>([]);
  const [tags, setTags] = useState<Tag[]>([]);
  const [items, setItems] = useState<MediaItem[]>([]);
  const [total, setTotal] = useState(0);
  const [offset, setOffset] = useState(0);
  const [loading, setLoading] = useState(false);
  const [search, setSearch] = useState('');
  const [submittedSearch, setSubmittedSearch] = useState('');
  const [kind, setKind] = useState('');
  const [libraryId, setLibraryId] = useState('');
  const [folderPath, setFolderPath] = useState('');
  const [folderRecursive, setFolderRecursive] = useState(true);
  const [albumId, setAlbumId] = useState('');
  const [tagId, setTagId] = useState('');
  const [favoriteOnly, setFavoriteOnly] = useState(false);
  const [sort, setSort] = useState('timeline');
  const [preview, setPreview] = useState<MediaItem | null>(null);
  const [scan, setScan] = useState<ScanStatus | null>(null);
  const [selectedIds, setSelectedIds] = useState<string[]>([]);
  const [albumName, setAlbumName] = useState('');
  const [tagName, setTagName] = useState('');
  const [tagColor, setTagColor] = useState('#6675df');
  const [batchRating, setBatchRating] = useState('0');
  const [batchAlbumId, setBatchAlbumId] = useState('');
  const [batchTagId, setBatchTagId] = useState('');
  const [batchBusy, setBatchBusy] = useState(false);
  const limit = 48;

  const query = useMemo(() => ({
    type: kind || undefined,
    q: submittedSearch || undefined,
    libraryId: libraryId || undefined,
    folder: folderPath || undefined,
    recursive: folderRecursive,
    favorite: favoriteOnly,
    albumId: albumId || undefined,
    tagId: tagId || undefined,
    sort,
    limit,
    offset,
  }), [albumId, favoriteOnly, folderPath, folderRecursive, kind, libraryId, offset, sort, submittedSearch, tagId]);

  const loadCatalog = useCallback(async () => {
    if (!running) {
      setStats(emptyStats);
      setLibraries([]);
      setAlbums([]);
      setTags([]);
      return;
    }
    try {
      const [nextStats, nextLibraries, nextAlbums, nextTags] = await Promise.all([
        invoke<MediaStats>('desktop_stats'),
        invoke<LibraryInfo[]>('desktop_libraries'),
        invoke<Album[]>('desktop_albums'),
        invoke<Tag[]>('desktop_tags'),
      ]);
      setStats(nextStats);
      setLibraries(nextLibraries);
      setAlbums(nextAlbums);
      setTags(nextTags);
    } catch (error) {
      onMessage(`读取媒体目录失败：${String(error)}`);
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

  const loadFolders = useCallback(async () => {
    if (!running || !libraryId) {
      setFolders([]);
      return;
    }
    try {
      const next = await invoke<FolderInfo[]>('desktop_folders', { libraryId, parent: folderPath });
      setFolders(next);
    } catch (error) {
      setFolders([]);
      onMessage(`读取文件夹失败：${String(error)}`);
    }
  }, [folderPath, libraryId, onMessage, running]);

  useEffect(() => {
    void loadCatalog();
  }, [loadCatalog, refreshKey]);

  useEffect(() => {
    void loadMedia();
  }, [loadMedia, refreshKey]);

  useEffect(() => {
    void loadFolders();
  }, [loadFolders, refreshKey]);

  useEffect(() => {
    if (!running || !scan?.running) return undefined;
    const timer = window.setInterval(() => {
      void invoke<ScanStatus>('desktop_scan_status').then((next) => {
        setScan(next);
        if (!next.running) {
          void loadCatalog();
          void loadFolders();
          void loadMedia();
          onMessage(next.errorMessage ? `扫描完成，但存在错误：${next.errorMessage}` : `扫描完成，已索引 ${next.indexed} 个媒体文件`);
        }
      });
    }, 1000);
    return () => window.clearInterval(timer);
  }, [loadCatalog, loadFolders, loadMedia, onMessage, running, scan?.running]);

  const folderBreadcrumb = useMemo(() => {
    const segments = folderPath.split('/').filter(Boolean);
    return segments.map((name, index) => ({
      name,
      path: segments.slice(0, index + 1).join('/'),
    }));
  }, [folderPath]);

  const submitSearch = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setOffset(0);
    setSelectedIds([]);
    setSubmittedSearch(search.trim());
  };

  const changeFilter = (callback: () => void) => {
    setOffset(0);
    setSelectedIds([]);
    callback();
  };

  const selectLibrary = (id: string) => {
    changeFilter(() => {
      setLibraryId(id);
      setFolderPath('');
    });
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

  const createAlbum = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const name = albumName.trim();
    if (!name) return;
    try {
      const album = await invoke<Album>('desktop_create_album', { name, description: '' });
      setAlbumName('');
      await loadCatalog();
      setBatchAlbumId(album.id);
      onMessage(`相册“${album.name}”已创建`);
    } catch (error) {
      onMessage(`创建相册失败：${String(error)}`);
    }
  };

  const deleteAlbum = async (album: Album) => {
    if (!window.confirm(`确定删除相册“${album.name}”吗？媒体文件不会被删除。`)) return;
    try {
      await invoke('desktop_delete_album', { id: album.id });
      if (albumId === album.id) setAlbumId('');
      if (batchAlbumId === album.id) setBatchAlbumId('');
      await loadCatalog();
      await loadMedia();
      onMessage(`相册“${album.name}”已删除`);
    } catch (error) {
      onMessage(`删除相册失败：${String(error)}`);
    }
  };

  const createTag = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const name = tagName.trim();
    if (!name) return;
    try {
      const tag = await invoke<Tag>('desktop_create_tag', { name, color: tagColor });
      setTagName('');
      await loadCatalog();
      setBatchTagId(tag.id);
      onMessage(`标签“${tag.name}”已创建`);
    } catch (error) {
      onMessage(`创建标签失败：${String(error)}`);
    }
  };

  const deleteTag = async (tag: Tag) => {
    if (!window.confirm(`确定删除标签“${tag.name}”吗？媒体文件不会被删除。`)) return;
    try {
      await invoke('desktop_delete_tag', { id: tag.id });
      if (tagId === tag.id) setTagId('');
      if (batchTagId === tag.id) setBatchTagId('');
      await loadCatalog();
      await loadMedia();
      onMessage(`标签“${tag.name}”已删除`);
    } catch (error) {
      onMessage(`删除标签失败：${String(error)}`);
    }
  };

  const toggleSelected = (id: string) => {
    setSelectedIds((current) => current.includes(id)
      ? current.filter((value) => value !== id)
      : [...current, id]);
  };

  const selectCurrentPage = () => {
    setSelectedIds((current) => Array.from(new Set([...current, ...items.map((item) => item.id)])));
  };

  const runBatch = async (patch: BatchPatch, successMessage: string) => {
    if (selectedIds.length === 0) return;
    setBatchBusy(true);
    try {
      const result = await invoke<BatchMediaResult>('desktop_batch_update', {
        request: {
          ids: selectedIds,
          addToCollection: true,
          ...patch,
        },
      });
      await Promise.all([loadCatalog(), loadMedia()]);
      const failed = result.failed.length > 0 ? `，${result.failed.length} 项失败` : '';
      onMessage(`${successMessage}：已处理 ${result.updated} 项${failed}`);
    } catch (error) {
      onMessage(`批量操作失败：${String(error)}`);
    } finally {
      setBatchBusy(false);
    }
  };

  const activeAlbum = albums.find((album) => album.id === albumId);
  const activeTag = tags.find((tag) => tag.id === tagId);

  return (
    <section className="config-panel media-browser-panel">
      <div className="section-heading">
        <div><span className="eyebrow">WINDOWS 媒体库</span><h3>浏览、整理与归档</h3></div>
        <div className="actions">
          <button className="secondary" disabled={!running || Boolean(scan?.running)} onClick={() => void startScan()}>{scan?.running ? '扫描中…' : '重新扫描'}</button>
          <button className="secondary" disabled={!running || loading} onClick={() => { void loadCatalog(); void loadFolders(); void loadMedia(); }}>刷新内容</button>
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

          <div className="media-workspace">
            <aside className="media-sidebar">
              <section className="media-sidebar-section">
                <div className="sidebar-heading"><strong>媒体库</strong><small>{libraries.length} 个来源</small></div>
                <button className={!libraryId ? 'sidebar-filter active' : 'sidebar-filter'} onClick={() => selectLibrary('')}><span>全部媒体库</span><small>{stats.total}</small></button>
                {libraries.map((library) => (
                  <button key={library.id} className={libraryId === library.id ? 'sidebar-filter active' : 'sidebar-filter'} onClick={() => selectLibrary(library.id)}>
                    <span>{library.name}</span><small>{library.mediaCount}</small>
                  </button>
                ))}
              </section>

              <section className="media-sidebar-section">
                <div className="sidebar-heading"><strong>文件夹</strong><small>{libraryId ? '按目录浏览' : '先选择媒体库'}</small></div>
                {libraryId ? (
                  <>
                    <div className="folder-breadcrumb">
                      <button className={!folderPath ? 'active' : ''} onClick={() => changeFilter(() => setFolderPath(''))}>根目录</button>
                      {folderBreadcrumb.map((segment) => (
                        <button key={segment.path} className={folderPath === segment.path ? 'active' : ''} onClick={() => changeFilter(() => setFolderPath(segment.path))}>{segment.name}</button>
                      ))}
                    </div>
                    <label className="sidebar-check"><input type="checkbox" checked={folderRecursive} onChange={(event) => changeFilter(() => setFolderRecursive(event.target.checked))} />包含子文件夹</label>
                    <div className="folder-list">
                      {folders.map((folder) => (
                        <button key={folder.id} className="sidebar-filter folder-filter" onClick={() => changeFilter(() => setFolderPath(folder.path))}>
                          <span>▸ {folder.name}</span><small>{folder.mediaCount}{folder.childCount > 0 ? ` · ${folder.childCount} 子目录` : ''}</small>
                        </button>
                      ))}
                      {folders.length === 0 && <p>当前目录没有子文件夹。</p>}
                    </div>
                  </>
                ) : <p>选择一个媒体库后显示目录树。</p>}
              </section>

              <section className="media-sidebar-section">
                <div className="sidebar-heading"><strong>相册</strong><small>{albums.length} 个</small></div>
                <form className="sidebar-create" onSubmit={(event) => void createAlbum(event)}>
                  <input value={albumName} onChange={(event) => setAlbumName(event.target.value)} placeholder="新相册名称" />
                  <button className="primary" type="submit" disabled={!albumName.trim()}>+</button>
                </form>
                <button className={!albumId ? 'sidebar-filter active' : 'sidebar-filter'} onClick={() => changeFilter(() => setAlbumId(''))}><span>全部相册</span></button>
                {albums.map((album) => (
                  <div className="sidebar-filter-row" key={album.id}>
                    <button className={albumId === album.id ? 'sidebar-filter active' : 'sidebar-filter'} onClick={() => changeFilter(() => setAlbumId(album.id))}><span>{album.name}</span><small>{album.itemCount}</small></button>
                    <button className="sidebar-delete" title="删除相册" onClick={() => void deleteAlbum(album)}>×</button>
                  </div>
                ))}
              </section>

              <section className="media-sidebar-section">
                <div className="sidebar-heading"><strong>标签</strong><small>{tags.length} 个</small></div>
                <form className="sidebar-create tag-create" onSubmit={(event) => void createTag(event)}>
                  <input type="color" value={tagColor} onChange={(event) => setTagColor(event.target.value)} aria-label="标签颜色" />
                  <input value={tagName} onChange={(event) => setTagName(event.target.value)} placeholder="新标签名称" />
                  <button className="primary" type="submit" disabled={!tagName.trim()}>+</button>
                </form>
                <button className={!tagId ? 'sidebar-filter active' : 'sidebar-filter'} onClick={() => changeFilter(() => setTagId(''))}><span>全部标签</span></button>
                {tags.map((tag) => (
                  <div className="sidebar-filter-row" key={tag.id}>
                    <button className={tagId === tag.id ? 'sidebar-filter active' : 'sidebar-filter'} onClick={() => changeFilter(() => setTagId(tag.id))}>
                      <span><i className="tag-dot" style={{ background: tag.color || '#6675df' }} />{tag.name}</span><small>{tag.itemCount}</small>
                    </button>
                    <button className="sidebar-delete" title="删除标签" onClick={() => void deleteTag(tag)}>×</button>
                  </div>
                ))}
              </section>
            </aside>

            <div className="media-content">
              <form className="media-toolbar" onSubmit={submitSearch}>
                <div className="media-search"><input value={search} onChange={(event) => setSearch(event.target.value)} placeholder="搜索文件名或相对路径" /><button className="primary" type="submit">搜索</button></div>
                <select value={kind} onChange={(event) => changeFilter(() => setKind(event.target.value))}><option value="">全部类型</option><option value="image">图片</option><option value="video">视频</option></select>
                <select value={sort} onChange={(event) => changeFilter(() => setSort(event.target.value))}><option value="timeline">拍摄时间</option><option value="modified">修改时间</option><option value="name">文件名</option></select>
                <label className="media-favorite-filter"><input type="checkbox" checked={favoriteOnly} onChange={(event) => changeFilter(() => setFavoriteOnly(event.target.checked))} />只看收藏</label>
              </form>

              {(folderPath || activeAlbum || activeTag || submittedSearch) && (
                <div className="active-filter-bar">
                  <span>当前范围：</span>
                  {folderPath && <button onClick={() => changeFilter(() => setFolderPath(''))}>文件夹：{folderPath} ×</button>}
                  {activeAlbum && <button onClick={() => changeFilter(() => setAlbumId(''))}>相册：{activeAlbum.name} ×</button>}
                  {activeTag && <button onClick={() => changeFilter(() => setTagId(''))}>标签：{activeTag.name} ×</button>}
                  {submittedSearch && <button onClick={() => { setSearch(''); changeFilter(() => setSubmittedSearch('')); }}>搜索：{submittedSearch} ×</button>}
                </div>
              )}

              {selectedIds.length > 0 && (
                <div className="batch-toolbar">
                  <div className="batch-summary"><strong>已选择 {selectedIds.length} 项</strong><button onClick={() => setSelectedIds([])}>清空</button></div>
                  <div className="batch-actions">
                    <button className="secondary" disabled={batchBusy} onClick={() => void runBatch({ favorite: true }, '批量收藏完成')}>收藏</button>
                    <button className="secondary" disabled={batchBusy} onClick={() => void runBatch({ favorite: false }, '取消收藏完成')}>取消收藏</button>
                    <div className="batch-group"><select value={batchRating} onChange={(event) => setBatchRating(event.target.value)}><option value="0">清除评分</option><option value="1">★</option><option value="2">★★</option><option value="3">★★★</option><option value="4">★★★★</option><option value="5">★★★★★</option></select><button className="secondary" disabled={batchBusy} onClick={() => void runBatch({ rating: Number(batchRating) }, '批量评分完成')}>应用</button></div>
                    <div className="batch-group"><select value={batchAlbumId} onChange={(event) => setBatchAlbumId(event.target.value)}><option value="">选择相册</option>{albums.map((album) => <option key={album.id} value={album.id}>{album.name}</option>)}</select><button className="secondary" disabled={batchBusy || !batchAlbumId} onClick={() => void runBatch({ albumId: batchAlbumId, addToCollection: true }, '已加入相册')}>加入</button><button className="secondary" disabled={batchBusy || !batchAlbumId} onClick={() => void runBatch({ albumId: batchAlbumId, addToCollection: false }, '已移出相册')}>移出</button></div>
                    <div className="batch-group"><select value={batchTagId} onChange={(event) => setBatchTagId(event.target.value)}><option value="">选择标签</option>{tags.map((tag) => <option key={tag.id} value={tag.id}>{tag.name}</option>)}</select><button className="secondary" disabled={batchBusy || !batchTagId} onClick={() => void runBatch({ tagId: batchTagId, addToCollection: true }, '已添加标签')}>添加</button><button className="secondary" disabled={batchBusy || !batchTagId} onClick={() => void runBatch({ tagId: batchTagId, addToCollection: false }, '已移除标签')}>移除</button></div>
                  </div>
                </div>
              )}

              <div className="media-list-heading">
                <span>共 {total} 项</span>
                <div className="actions"><button className="secondary" disabled={items.length === 0} onClick={selectCurrentPage}>选择当前页</button><button className="secondary" disabled={selectedIds.length === 0} onClick={() => setSelectedIds([])}>取消选择</button></div>
              </div>

              {loading && <div className="empty-state">正在读取媒体内容…</div>}
              {!loading && items.length === 0 && <div className="empty-state">当前范围没有媒体。首次添加文件夹后，请点击“重新扫描”。</div>}
              {!loading && items.length > 0 && (
                <div className="media-grid">
                  {items.map((item) => {
                    const selected = selectedIds.includes(item.id);
                    return (
                      <article className={selected ? 'media-card selected' : 'media-card'} key={item.id}>
                        <label className="media-select"><input type="checkbox" checked={selected} onChange={() => toggleSelected(item.id)} /><span>选择</span></label>
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
                    );
                  })}
                </div>
              )}

              <div className="media-pagination">
                <span>第 {total === 0 ? 0 : Math.floor(offset / limit) + 1} / {Math.max(1, Math.ceil(total / limit))} 页</span>
                <div className="actions"><button className="secondary" disabled={offset <= 0 || loading} onClick={() => setOffset(Math.max(0, offset - limit))}>上一页</button><button className="secondary" disabled={offset + limit >= total || loading} onClick={() => setOffset(offset + limit)}>下一页</button></div>
              </div>
            </div>
          </div>
        </>
      )}

      {preview && (
        <MediaPreview
          item={preview}
          albums={albums}
          tags={tags}
          onClose={() => setPreview(null)}
          onChanged={() => { void loadCatalog(); void loadMedia(); }}
          onMessage={onMessage}
        />
      )}
    </section>
  );
}
