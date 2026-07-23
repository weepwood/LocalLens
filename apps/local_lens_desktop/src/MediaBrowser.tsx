import { FormEvent, useCallback, useEffect, useMemo, useState } from 'react';
import { Button, Card, Chip, Input, Spinner } from '@heroui/react';
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
type ViewMode = 'grid' | 'list';
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

function MediaThumbnail({ item, width = 520 }: { item: MediaItem; width?: number }) {
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

  if (failed) return <div className="thumbnail-state">缩略图不可用</div>;
  if (!url) return <div className="thumbnail-state"><Spinner size="sm" /><span>生成缩略图</span></div>;
  return <img alt={item.fileName} loading="lazy" src={url} />;
}

interface InspectorProps {
  item: MediaItem;
  albums: Album[];
  tags: Tag[];
  onClose: () => void;
  onChanged: () => void;
  onMessage: (message: string) => void;
}

function MediaInspector({ item, albums, tags, onClose, onChanged, onMessage }: InspectorProps) {
  const [collections, setCollections] = useState<MediaCollections>({ albumIds: [], tagIds: [] });
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    let active = true;
    void invoke<MediaCollections>('desktop_media_collections', { id: item.id })
      .then((value) => { if (active) setCollections(value); })
      .catch((error) => { if (active) onMessage(`读取媒体归属失败：${String(error)}`); });
    return () => { active = false; };
  }, [item.id, onMessage]);

  const openDefault = async () => {
    try {
      await invoke('desktop_open_media', { id: item.id });
      onMessage(`已使用 Windows 默认应用打开“${item.fileName}”`);
    } catch (error) {
      onMessage(`打开媒体失败：${String(error)}`);
    }
  };

  const reveal = async () => {
    try {
      await invoke('desktop_reveal_media', { id: item.id });
      onMessage(`已在资源管理器中定位“${item.fileName}”`);
    } catch (error) {
      onMessage(`定位原文件失败：${String(error)}`);
    }
  };

  const toggleAlbum = async (album: Album) => {
    const add = !collections.albumIds.includes(album.id);
    setBusy(true);
    try {
      await invoke('desktop_set_album_item', { albumId: album.id, mediaId: item.id, add });
      setCollections((current) => ({
        ...current,
        albumIds: add ? [...current.albumIds, album.id] : current.albumIds.filter((id) => id !== album.id),
      }));
      onChanged();
    } catch (error) {
      onMessage(`更新相册归属失败：${String(error)}`);
    } finally {
      setBusy(false);
    }
  };

  const toggleTag = async (tag: Tag) => {
    const add = !collections.tagIds.includes(tag.id);
    setBusy(true);
    try {
      await invoke('desktop_set_media_tag', { mediaId: item.id, tagId: tag.id, add });
      setCollections((current) => ({
        ...current,
        tagIds: add ? [...current.tagIds, tag.id] : current.tagIds.filter((id) => id !== tag.id),
      }));
      onChanged();
    } catch (error) {
      onMessage(`更新标签失败：${String(error)}`);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="inspector-backdrop" onClick={onClose} role="presentation">
      <Card className="media-inspector-card" onClick={(event) => event.stopPropagation()} role="dialog">
        <Card.Header className="inspector-header">
          <div><Chip className="media-kind-chip">{item.type === 'image' ? '图片' : '视频'}</Chip><Card.Title title={item.fileName}>{item.fileName}</Card.Title><Card.Description title={item.relativePath}>{item.relativePath}</Card.Description></div>
          <button aria-label="关闭详情" className="inspector-close" onClick={onClose}>×</button>
        </Card.Header>
        <Card.Content className="inspector-body">
          <div className="inspector-preview">
            <MediaThumbnail item={item} width={960} />
            <div className="default-open-note"><strong>媒体由 Windows 默认应用打开</strong><span>LocalLens 只负责浏览、索引与整理，不重复实现播放器。</span></div>
            <div className="inspector-primary-actions">
              <Button onPress={() => void openDefault()} variant="primary">使用默认应用打开</Button>
              <Button onPress={() => void reveal()} variant="secondary">在资源管理器中定位</Button>
            </div>
          </div>

          <div className="inspector-details">
            <dl className="detail-grid">
              <div><dt>格式</dt><dd>{item.mimeType || '未知'}</dd></div>
              <div><dt>大小</dt><dd>{formatBytes(item.sizeBytes)}</dd></div>
              <div><dt>尺寸</dt><dd>{item.width > 0 ? `${item.width} × ${item.height}` : '待提取'}</dd></div>
              <div><dt>时长</dt><dd>{item.durationMs > 0 ? formatDuration(item.durationMs) : '—'}</dd></div>
              <div><dt>拍摄时间</dt><dd>{formatDate(item.capturedAt)}</dd></div>
              <div><dt>修改时间</dt><dd>{formatDate(item.modifiedAt)}</dd></div>
              <div><dt>相机 / 编码</dt><dd>{item.cameraModel || item.codec || '未知'}</dd></div>
              <div><dt>元数据</dt><dd>{item.metadataStatus || '未知'}</dd></div>
            </dl>

            {item.metadataError && <div className="metadata-error">{item.metadataError}</div>}

            <section className="collection-section">
              <div><strong>相册</strong><span>点击切换归属</span></div>
              <div className="collection-list">
                {albums.length === 0 && <small>尚未创建相册。</small>}
                {albums.map((album) => (
                  <button className={collections.albumIds.includes(album.id) ? 'collection-pill active' : 'collection-pill'} disabled={busy} key={album.id} onClick={() => void toggleAlbum(album)}>{collections.albumIds.includes(album.id) ? '✓ ' : ''}{album.name}</button>
                ))}
              </div>
            </section>

            <section className="collection-section">
              <div><strong>标签</strong><span>点击切换标签</span></div>
              <div className="collection-list">
                {tags.length === 0 && <small>尚未创建标签。</small>}
                {tags.map((tag) => (
                  <button className={collections.tagIds.includes(tag.id) ? 'collection-pill active' : 'collection-pill'} disabled={busy} key={tag.id} onClick={() => void toggleTag(tag)}><i style={{ background: tag.color || '#6d5dfc' }} />{tag.name}</button>
                ))}
              </div>
            </section>
          </div>
        </Card.Content>
      </Card>
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
  const [inspector, setInspector] = useState<MediaItem | null>(null);
  const [scan, setScan] = useState<ScanStatus | null>(null);
  const [selectedIds, setSelectedIds] = useState<string[]>([]);
  const [albumName, setAlbumName] = useState('');
  const [tagName, setTagName] = useState('');
  const [tagColor, setTagColor] = useState('#6d5dfc');
  const [batchRating, setBatchRating] = useState('0');
  const [batchAlbumId, setBatchAlbumId] = useState('');
  const [batchTagId, setBatchTagId] = useState('');
  const [batchBusy, setBatchBusy] = useState(false);
  const [viewMode, setViewMode] = useState<ViewMode>('grid');
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
      setFolders(await invoke<FolderInfo[]>('desktop_folders', { libraryId, parent: folderPath }));
    } catch (error) {
      setFolders([]);
      onMessage(`读取文件夹失败：${String(error)}`);
    }
  }, [folderPath, libraryId, onMessage, running]);

  useEffect(() => { void loadCatalog(); }, [loadCatalog, refreshKey]);
  useEffect(() => { void loadMedia(); }, [loadMedia, refreshKey]);
  useEffect(() => { void loadFolders(); }, [loadFolders, refreshKey]);

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

  const changeFilter = (callback: () => void) => {
    setOffset(0);
    setSelectedIds([]);
    callback();
  };

  const submitSearch = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    changeFilter(() => setSubmittedSearch(search.trim()));
  };

  const selectLibrary = (id: string) => {
    changeFilter(() => {
      setLibraryId(id);
      setFolderPath('');
    });
  };

  const folderBreadcrumb = useMemo(() => {
    const segments = folderPath.split('/').filter(Boolean);
    return segments.map((name, index) => ({ name, path: segments.slice(0, index + 1).join('/') }));
  }, [folderPath]);

  const startScan = async () => {
    try {
      const started = await invoke<boolean>('desktop_start_scan');
      setScan(await invoke<ScanStatus>('desktop_scan_status'));
      onMessage(started ? '已开始扫描媒体库' : '媒体库扫描已经在进行中');
    } catch (error) {
      onMessage(`启动扫描失败：${String(error)}`);
    }
  };

  const openMedia = async (item: MediaItem) => {
    try {
      await invoke('desktop_open_media', { id: item.id });
      onMessage(`已使用 Windows 默认应用打开“${item.fileName}”`);
    } catch (error) {
      onMessage(`打开媒体失败：${String(error)}`);
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
      await Promise.all([loadCatalog(), loadMedia()]);
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
      await Promise.all([loadCatalog(), loadMedia()]);
      onMessage(`标签“${tag.name}”已删除`);
    } catch (error) {
      onMessage(`删除标签失败：${String(error)}`);
    }
  };

  const toggleSelected = (id: string) => {
    setSelectedIds((current) => current.includes(id) ? current.filter((value) => value !== id) : [...current, id]);
  };

  const selectCurrentPage = () => {
    setSelectedIds((current) => Array.from(new Set([...current, ...items.map((item) => item.id)])));
  };

  const runBatch = async (patch: BatchPatch, successMessage: string) => {
    if (selectedIds.length === 0) return;
    setBatchBusy(true);
    try {
      const result = await invoke<BatchMediaResult>('desktop_batch_update', {
        request: { ids: selectedIds, addToCollection: true, ...patch },
      });
      await Promise.all([loadCatalog(), loadMedia()]);
      onMessage(`${successMessage}：已处理 ${result.updated} 项${result.failed.length > 0 ? `，${result.failed.length} 项失败` : ''}`);
    } catch (error) {
      onMessage(`批量操作失败：${String(error)}`);
    } finally {
      setBatchBusy(false);
    }
  };

  const activeAlbum = albums.find((album) => album.id === albumId);
  const activeTag = tags.find((tag) => tag.id === tagId);
  const page = Math.floor(offset / limit) + 1;
  const pageCount = Math.max(1, Math.ceil(total / limit));

  if (!running) {
    return <Card className="media-offline"><Card.Content><div className="panel-empty"><div className="offline-symbol">L</div><strong>媒体服务尚未启动</strong><span>启动 Rust 服务后，这里会显示本地图片与视频。</span></div></Card.Content></Card>;
  }

  return (
    <section className="media-browser">
      <div className="media-summary-grid">
        {[
          ['全部媒体', stats.total, formatBytes(stats.sizeBytes)],
          ['图片', stats.images, '已索引图片'],
          ['视频', stats.videos, '已索引视频'],
          ['收藏', stats.favorites, '收藏内容'],
        ].map(([label, value, hint]) => (
          <Card className="media-summary-card" key={label as string}><Card.Content><span>{label}</span><strong>{value}</strong><small>{hint}</small></Card.Content></Card>
        ))}
      </div>

      {scan?.running && <div className="scan-banner"><Spinner size="sm" /><div><strong>正在扫描媒体库</strong><span>{scan.current || '准备中'} · 发现 {scan.discovered} · 已索引 {scan.indexed} · 失败 {scan.failed}</span></div></div>}

      <div className="media-layout">
        <aside className="catalog-sidebar">
          <div className="catalog-section">
            <div className="catalog-heading"><strong>媒体库</strong><span>{libraries.length}</span></div>
            <button className={!libraryId ? 'catalog-item active' : 'catalog-item'} onClick={() => selectLibrary('')}><span>全部媒体库</span><small>{stats.total}</small></button>
            {libraries.map((library) => <button className={libraryId === library.id ? 'catalog-item active' : 'catalog-item'} key={library.id} onClick={() => selectLibrary(library.id)}><span>{library.name}</span><small>{library.mediaCount}</small></button>)}
          </div>

          <div className="catalog-section">
            <div className="catalog-heading"><strong>文件夹</strong><span>{libraryId ? folders.length : '—'}</span></div>
            {libraryId ? (
              <>
                <div className="breadcrumb-row"><button className={!folderPath ? 'active' : ''} onClick={() => changeFilter(() => setFolderPath(''))}>根目录</button>{folderBreadcrumb.map((segment) => <button className={folderPath === segment.path ? 'active' : ''} key={segment.path} onClick={() => changeFilter(() => setFolderPath(segment.path))}>{segment.name}</button>)}</div>
                <label className="recursive-check"><input checked={folderRecursive} type="checkbox" onChange={(event) => changeFilter(() => setFolderRecursive(event.target.checked))} />包含子文件夹</label>
                {folders.map((folder) => <button className="catalog-item folder-item" key={folder.id} onClick={() => changeFilter(() => setFolderPath(folder.path))}><span>› {folder.name}</span><small>{folder.mediaCount}</small></button>)}
                {folders.length === 0 && <p className="catalog-empty">当前目录没有子文件夹。</p>}
              </>
            ) : <p className="catalog-empty">选择媒体库后浏览目录。</p>}
          </div>

          <div className="catalog-section">
            <div className="catalog-heading"><strong>相册</strong><span>{albums.length}</span></div>
            <form className="catalog-create" onSubmit={(event) => void createAlbum(event)}><Input fullWidth value={albumName} onChange={(event) => setAlbumName(event.target.value)} placeholder="新相册" variant="secondary" /><Button isDisabled={!albumName.trim()} isIconOnly aria-label="创建相册" type="submit" variant="primary">+</Button></form>
            <button className={!albumId ? 'catalog-item active' : 'catalog-item'} onClick={() => changeFilter(() => setAlbumId(''))}><span>全部相册</span></button>
            {albums.map((album) => <div className="catalog-item-row" key={album.id}><button className={albumId === album.id ? 'catalog-item active' : 'catalog-item'} onClick={() => changeFilter(() => setAlbumId(album.id))}><span>{album.name}</span><small>{album.itemCount}</small></button><button aria-label="删除相册" onClick={() => void deleteAlbum(album)}>×</button></div>)}
          </div>

          <div className="catalog-section">
            <div className="catalog-heading"><strong>标签</strong><span>{tags.length}</span></div>
            <form className="catalog-create tag-create" onSubmit={(event) => void createTag(event)}><input aria-label="标签颜色" type="color" value={tagColor} onChange={(event) => setTagColor(event.target.value)} /><Input fullWidth value={tagName} onChange={(event) => setTagName(event.target.value)} placeholder="新标签" variant="secondary" /><Button isDisabled={!tagName.trim()} isIconOnly aria-label="创建标签" type="submit" variant="primary">+</Button></form>
            <button className={!tagId ? 'catalog-item active' : 'catalog-item'} onClick={() => changeFilter(() => setTagId(''))}><span>全部标签</span></button>
            {tags.map((tag) => <div className="catalog-item-row" key={tag.id}><button className={tagId === tag.id ? 'catalog-item active' : 'catalog-item'} onClick={() => changeFilter(() => setTagId(tag.id))}><span><i style={{ background: tag.color || '#6d5dfc' }} />{tag.name}</span><small>{tag.itemCount}</small></button><button aria-label="删除标签" onClick={() => void deleteTag(tag)}>×</button></div>)}
          </div>
        </aside>

        <div className="media-stage">
          <Card className="media-toolbar-card">
            <Card.Content>
              <form className="media-toolbar-modern" onSubmit={submitSearch}>
                <div className="search-control"><Input fullWidth value={search} onChange={(event) => setSearch(event.target.value)} placeholder="搜索文件名或相对路径" variant="secondary" /><Button type="submit" variant="primary">搜索</Button></div>
                <select className="hero-select compact" value={kind} onChange={(event) => changeFilter(() => setKind(event.target.value))}><option value="">全部类型</option><option value="image">图片</option><option value="video">视频</option></select>
                <select className="hero-select compact" value={sort} onChange={(event) => changeFilter(() => setSort(event.target.value))}><option value="timeline">拍摄时间</option><option value="modified">修改时间</option><option value="name">文件名</option></select>
                <label className="favorite-filter"><input checked={favoriteOnly} type="checkbox" onChange={(event) => changeFilter(() => setFavoriteOnly(event.target.checked))} />只看收藏</label>
                <div className="view-switch"><button className={viewMode === 'grid' ? 'active' : ''} onClick={() => setViewMode('grid')} type="button">网格</button><button className={viewMode === 'list' ? 'active' : ''} onClick={() => setViewMode('list')} type="button">列表</button></div>
                <Button isDisabled={Boolean(scan?.running)} onPress={() => void startScan()} variant="secondary">{scan?.running ? <Spinner size="sm" /> : null}重新扫描</Button>
              </form>
            </Card.Content>
          </Card>

          {(folderPath || activeAlbum || activeTag || submittedSearch) && <div className="filter-chips"><span>当前范围</span>{folderPath && <button onClick={() => changeFilter(() => setFolderPath(''))}>文件夹：{folderPath} ×</button>}{activeAlbum && <button onClick={() => changeFilter(() => setAlbumId(''))}>相册：{activeAlbum.name} ×</button>}{activeTag && <button onClick={() => changeFilter(() => setTagId(''))}>标签：{activeTag.name} ×</button>}{submittedSearch && <button onClick={() => { setSearch(''); changeFilter(() => setSubmittedSearch('')); }}>搜索：{submittedSearch} ×</button>}</div>}

          {selectedIds.length > 0 && (
            <Card className="batch-card"><Card.Content>
              <div className="batch-head"><strong>已选择 {selectedIds.length} 项</strong><button onClick={() => setSelectedIds([])}>清空选择</button></div>
              <div className="batch-controls">
                <Button isDisabled={batchBusy} onPress={() => void runBatch({ favorite: true }, '批量收藏完成')} variant="secondary">收藏</Button>
                <Button isDisabled={batchBusy} onPress={() => void runBatch({ favorite: false }, '取消收藏完成')} variant="secondary">取消收藏</Button>
                <div><select className="hero-select compact" value={batchRating} onChange={(event) => setBatchRating(event.target.value)}><option value="0">清除评分</option><option value="1">★</option><option value="2">★★</option><option value="3">★★★</option><option value="4">★★★★</option><option value="5">★★★★★</option></select><Button isDisabled={batchBusy} onPress={() => void runBatch({ rating: Number(batchRating) }, '批量评分完成')} variant="secondary">应用</Button></div>
                <div><select className="hero-select compact" value={batchAlbumId} onChange={(event) => setBatchAlbumId(event.target.value)}><option value="">选择相册</option>{albums.map((album) => <option key={album.id} value={album.id}>{album.name}</option>)}</select><Button isDisabled={batchBusy || !batchAlbumId} onPress={() => void runBatch({ albumId: batchAlbumId, addToCollection: true }, '已加入相册')} variant="secondary">加入</Button><Button isDisabled={batchBusy || !batchAlbumId} onPress={() => void runBatch({ albumId: batchAlbumId, addToCollection: false }, '已移出相册')} variant="secondary">移出</Button></div>
                <div><select className="hero-select compact" value={batchTagId} onChange={(event) => setBatchTagId(event.target.value)}><option value="">选择标签</option>{tags.map((tag) => <option key={tag.id} value={tag.id}>{tag.name}</option>)}</select><Button isDisabled={batchBusy || !batchTagId} onPress={() => void runBatch({ tagId: batchTagId, addToCollection: true }, '已添加标签')} variant="secondary">添加</Button><Button isDisabled={batchBusy || !batchTagId} onPress={() => void runBatch({ tagId: batchTagId, addToCollection: false }, '已移除标签')} variant="secondary">移除</Button></div>
              </div>
            </Card.Content></Card>
          )}

          <div className="media-result-heading"><div><strong>{total}</strong><span> 项媒体</span></div><div><Button isDisabled={items.length === 0} onPress={selectCurrentPage} variant="secondary">选择当前页</Button><Button isDisabled={selectedIds.length === 0} onPress={() => setSelectedIds([])} variant="secondary">取消选择</Button><Button isDisabled={loading} onPress={() => { void loadCatalog(); void loadFolders(); void loadMedia(); }} variant="secondary">刷新</Button></div></div>

          {loading && <div className="media-loading"><Spinner /><span>正在读取媒体内容…</span></div>}
          {!loading && items.length === 0 && <div className="panel-empty media-empty"><div className="offline-symbol">L</div><strong>当前范围没有媒体</strong><span>首次添加文件夹后，请点击“重新扫描”。</span></div>}

          {!loading && items.length > 0 && (
            <div className={viewMode === 'grid' ? 'media-cards' : 'media-cards list-mode'}>
              {items.map((item) => {
                const selected = selectedIds.includes(item.id);
                return (
                  <Card className={selected ? 'media-card-modern selected' : 'media-card-modern'} key={item.id}>
                    <Card.Content>
                      <label className="media-checkbox"><input checked={selected} type="checkbox" onChange={() => toggleSelected(item.id)} /><span /></label>
                      <button className="media-open-area" onClick={() => void openMedia(item)} title="使用 Windows 默认应用打开">
                        <div className="media-visual"><MediaThumbnail item={item} /><div className="open-overlay"><span>{item.type === 'image' ? '打开图片' : '播放视频'}</span></div>{item.type === 'video' && item.durationMs > 0 && <em>{formatDuration(item.durationMs)}</em>}</div>
                      </button>
                      <div className="media-card-copy"><div><Chip className="tiny-type-chip">{item.type === 'image' ? '图片' : '视频'}</Chip><strong title={item.fileName}>{item.fileName}</strong></div><span title={item.relativePath}>{item.relativePath}</span><small>{formatDate(item.capturedAt)} · {formatBytes(item.sizeBytes)}</small></div>
                      <div className="media-card-actions"><button className={item.favorite ? 'favorite-button active' : 'favorite-button'} onClick={() => void updateFavorite(item)} title="收藏">♥</button><div className="rating-row">{[1, 2, 3, 4, 5].map((rating) => <button className={item.rating >= rating ? 'active' : ''} key={rating} onClick={() => void updateRating(item, item.rating === rating ? 0 : rating)}>★</button>)}</div><Button onPress={() => setInspector(item)} variant="secondary">详情</Button></div>
                    </Card.Content>
                  </Card>
                );
              })}
            </div>
          )}

          <div className="pagination-bar"><span>第 {page} / {pageCount} 页</span><div><Button isDisabled={offset === 0 || loading} onPress={() => setOffset(Math.max(0, offset - limit))} variant="secondary">上一页</Button><Button isDisabled={offset + limit >= total || loading} onPress={() => setOffset(offset + limit)} variant="secondary">下一页</Button></div></div>
        </div>
      </div>

      {inspector && <MediaInspector albums={albums} item={inspector} tags={tags} onChanged={() => { void loadCatalog(); void loadMedia(); }} onClose={() => setInspector(null)} onMessage={onMessage} />}
    </section>
  );
}
