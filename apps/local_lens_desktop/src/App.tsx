import { useCallback, useEffect, useMemo, useState, type ReactNode } from 'react';
import { invoke } from '@tauri-apps/api/core';
import MediaBrowser from './MediaBrowser';

interface RuntimeStatus {
  running: boolean;
  serverName: string;
  listenAddress: string;
  publicUrl: string;
  configPath: string;
  dataDir: string;
  backend: string;
}

interface LibraryConfig {
  id: string;
  name: string;
  path: string;
  recursive: boolean;
  enabled: boolean;
}

interface AppConfig {
  listen_address: string;
  public_url: string;
  server_name: string;
  data_dir: string;
  api_token: string;
  ffmpeg_path: string;
  ffprobe_path: string;
  auto_scan: boolean;
  watch_files: boolean;
  thumbnail_workers: number;
  metadata_workers: number;
  transcode_workers: number;
  transcode_cache_gb: number;
  transcode_hardware: string;
  pairing_ttl_minutes: number;
  libraries: LibraryConfig[];
}

interface PairingSession {
  id: string;
  payload: string;
  expiresAt: string;
  qrUrl: string;
}

interface Device {
  id: string;
  name: string;
  platform: string;
  scopes: string;
  createdAt: string;
  lastSeenAt?: string | null;
  revokedAt?: string | null;
}

type BinaryPayload = ArrayBuffer | Uint8Array | number[];
type Workspace = 'media' | 'overview' | 'connections' | 'settings';
type IconName =
  | 'logo'
  | 'library'
  | 'dashboard'
  | 'phone'
  | 'settings'
  | 'refresh'
  | 'play'
  | 'stop'
  | 'copy'
  | 'plus'
  | 'trash'
  | 'network'
  | 'database'
  | 'folder'
  | 'sun'
  | 'moon'
  | 'collapse'
  | 'chevron'
  | 'check'
  | 'server';

const iconPaths: Record<IconName, string[]> = {
  logo: ['M4 5.5 12 2l8 3.5v13L12 22l-8-3.5z', 'M8 8.5h8v7H8z', 'm9 14 2-2 2 2 2-2 1 1'],
  library: ['M4 4h6v7H4z', 'M14 4h6v7h-6z', 'M4 15h6v5H4z', 'M14 15h6v5h-6z'],
  dashboard: ['M4 4h7v7H4z', 'M15 4h5v4h-5z', 'M15 12h5v8h-5z', 'M4 15h7v5H4z'],
  phone: ['M8 3h8a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2Z', 'M10 17h4'],
  settings: ['M12 15.5a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7Z', 'M19 12a7 7 0 0 0-.1-1l2-1.5-2-3.4-2.3.8a8 8 0 0 0-1.8-1L14.4 3h-4.8l-.4 2.9a8 8 0 0 0-1.8 1L5.1 6.1l-2 3.4L5.1 11a7 7 0 0 0 0 2l-2 1.5 2 3.4 2.3-.8a8 8 0 0 0 1.8 1l.4 2.9h4.8l.4-2.9a8 8 0 0 0 1.8-1l2.3.8 2-3.4-2-1.5a7 7 0 0 0 .1-1Z'],
  refresh: ['M20 6v5h-5', 'M4 18v-5h5', 'M18.5 10A7 7 0 0 0 6.2 6.3L4 11', 'M5.5 14A7 7 0 0 0 17.8 17.7L20 13'],
  play: ['M8 5v14l11-7Z'],
  stop: ['M7 7h10v10H7z'],
  copy: ['M8 8h11v11H8z', 'M5 16H4V4h12v1'],
  plus: ['M12 5v14', 'M5 12h14'],
  trash: ['M4 7h16', 'M9 7V4h6v3', 'm7 7 1 13h8l1-13'],
  network: ['M5 12a7 7 0 0 1 14 0', 'M8 12a4 4 0 0 1 8 0', 'M12 16h.01'],
  database: ['M4 6c0 2 3.6 3 8 3s8-1 8-3-3.6-3-8-3-8 1-8 3Z', 'M4 6v6c0 2 3.6 3 8 3s8-1 8-3V6', 'M4 12v6c0 2 3.6 3 8 3s8-1 8-3v-6'],
  folder: ['M3 6h7l2 2h9v11H3z'],
  sun: ['M12 4V2', 'M12 22v-2', 'M4 12H2', 'M22 12h-2', 'm5.6 5.6-1.4-1.4', 'm15.6 15.6-1.4-1.4', 'm18.4 5.6 1.4-1.4', 'm4.2 19.8 1.4-1.4', 'M16 12a4 4 0 1 1-8 0 4 4 0 0 1 8 0Z'],
  moon: ['M20 15.2A8.5 8.5 0 0 1 8.8 4 8.5 8.5 0 1 0 20 15.2Z'],
  collapse: ['m14 6-6 6 6 6', 'M20 6v12'],
  chevron: ['m9 18 6-6-6-6'],
  check: ['m5 12 4 4L19 6'],
  server: ['M4 5h16v5H4z', 'M4 14h16v5H4z', 'M7 7.5h.01', 'M7 16.5h.01'],
};

function Icon({ name, size = 20 }: { name: IconName; size?: number }) {
  return (
    <svg aria-hidden="true" className="lap-icon" fill="none" height={size} viewBox="0 0 24 24" width={size}>
      {iconPaths[name].map((path) => (
        <path d={path} key={path} stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.7" />
      ))}
    </svg>
  );
}

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

async function binaryToDataUrl(payload: BinaryPayload, mimeType: string) {
  const blob = new Blob([binaryBuffer(payload)], { type: mimeType });
  return await new Promise<string>((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result));
    reader.onerror = () => reject(reader.error ?? new Error('读取二进制内容失败'));
    reader.readAsDataURL(blob);
  });
}

function formatDate(value?: string | null) {
  if (!value) return '尚未连接';
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? value : date.toLocaleString();
}

const emptyStatus: RuntimeStatus = {
  running: false,
  serverName: 'LocalLens',
  listenAddress: '0.0.0.0:9527',
  publicUrl: '',
  configPath: '',
  dataDir: '',
  backend: 'Rust',
};

const emptyConfig: AppConfig = {
  listen_address: '0.0.0.0:9527',
  public_url: 'http://127.0.0.1:9527',
  server_name: 'LocalLens',
  data_dir: './data',
  api_token: '',
  ffmpeg_path: 'runtime/media-tools/ffmpeg.exe',
  ffprobe_path: 'runtime/media-tools/ffprobe.exe',
  auto_scan: true,
  watch_files: true,
  thumbnail_workers: 2,
  metadata_workers: 2,
  transcode_workers: 1,
  transcode_cache_gb: 20,
  transcode_hardware: 'software',
  pairing_ttl_minutes: 5,
  libraries: [],
};

const workspaceMeta: Record<Workspace, { title: string; description: string }> = {
  media: { title: '资料库', description: '浏览与整理本地图片、视频、文件夹、相册和标签' },
  overview: { title: '概览', description: '查看本地媒体服务、索引与运行环境' },
  connections: { title: '移动设备', description: '生成一次性配对二维码并管理授权设备' },
  settings: { title: '偏好设置', description: '配置媒体库、网络、后台任务和安全选项' },
};

function Panel({
  title,
  description,
  children,
  className = '',
  action,
}: {
  title: string;
  description?: string;
  children: ReactNode;
  className?: string;
  action?: ReactNode;
}) {
  return (
    <section className={`lap-panel ${className}`}>
      <header className="lap-panel-header">
        <div>
          <h2>{title}</h2>
          {description && <p>{description}</p>}
        </div>
        {action}
      </header>
      <div className="lap-panel-body">{children}</div>
    </section>
  );
}

export default function App() {
  const [workspace, setWorkspace] = useState<Workspace>('media');
  const [status, setStatus] = useState<RuntimeStatus>(emptyStatus);
  const [config, setConfig] = useState<AppConfig>(emptyConfig);
  const [busy, setBusy] = useState(false);
  const [pairingBusy, setPairingBusy] = useState(false);
  const [message, setMessage] = useState('正在初始化本地 Rust 服务…');
  const [pairing, setPairing] = useState<PairingSession | null>(null);
  const [qrDataUrl, setQrDataUrl] = useState('');
  const [devices, setDevices] = useState<Device[]>([]);
  const [now, setNow] = useState(Date.now());
  const [refreshKey, setRefreshKey] = useState(0);
  const [railExpanded, setRailExpanded] = useState(() => localStorage.getItem('locallens.rail-expanded') === 'true');
  const [darkMode, setDarkMode] = useState(() => localStorage.getItem('locallens.theme') !== 'light');

  const currentMeta = workspaceMeta[workspace];
  const remainingSeconds = pairing
    ? Math.max(0, Math.ceil((new Date(pairing.expiresAt).getTime() - now) / 1000))
    : 0;

  useEffect(() => {
    document.documentElement.dataset.theme = darkMode ? 'locallens-dark' : 'locallens-light';
    localStorage.setItem('locallens.theme', darkMode ? 'dark' : 'light');
  }, [darkMode]);

  useEffect(() => {
    localStorage.setItem('locallens.rail-expanded', String(railExpanded));
  }, [railExpanded]);

  const refresh = useCallback(async () => {
    try {
      const [nextStatus, nextConfig] = await Promise.all([
        invoke<RuntimeStatus>('runtime_status'),
        invoke<AppConfig>('read_config'),
      ]);
      setStatus(nextStatus);
      setConfig(nextConfig);
      setMessage(nextStatus.running ? 'Rust 媒体服务正在运行' : 'Rust 媒体服务尚未启动');
      return nextStatus;
    } catch (error) {
      setMessage(`读取状态失败：${String(error)}`);
      return null;
    }
  }, []);

  const loadDevices = useCallback(async () => {
    if (!status.running) {
      setDevices([]);
      return;
    }
    try {
      setDevices(await invoke<Device[]>('desktop_devices'));
    } catch (error) {
      setMessage(`读取设备失败：${String(error)}`);
    }
  }, [status.running]);

  useEffect(() => {
    let active = true;
    let timer = 0;
    let attempts = 0;
    const poll = async () => {
      const next = await refresh();
      if (!active || next?.running || attempts >= 30) return;
      attempts += 1;
      timer = window.setTimeout(() => void poll(), 500);
    };
    void poll();
    return () => {
      active = false;
      window.clearTimeout(timer);
    };
  }, [refresh]);

  useEffect(() => {
    void loadDevices();
  }, [loadDevices, refreshKey]);

  useEffect(() => {
    if (!pairing) return undefined;
    setNow(Date.now());
    const timer = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(timer);
  }, [pairing]);

  const changeRuntime = async (action: 'start_server' | 'stop_server') => {
    setBusy(true);
    setMessage(action === 'start_server' ? '正在启动 Rust 服务…' : '正在停止 Rust 服务…');
    try {
      await invoke(action);
      await refresh();
      setRefreshKey((value) => value + 1);
      if (action === 'stop_server') {
        setPairing(null);
        setQrDataUrl('');
        setDevices([]);
      }
    } catch (error) {
      setMessage(`操作失败：${String(error)}`);
    } finally {
      setBusy(false);
    }
  };

  const saveConfig = async () => {
    setBusy(true);
    setMessage('正在保存配置并重启 Rust 服务…');
    try {
      await invoke('save_config', { config });
      setPairing(null);
      setQrDataUrl('');
      await refresh();
      setRefreshKey((value) => value + 1);
      setMessage('配置已保存，Rust 服务已完成重启');
    } catch (error) {
      setMessage(`保存配置失败：${String(error)}`);
    } finally {
      setBusy(false);
    }
  };

  const detectPublicUrl = async () => {
    setBusy(true);
    try {
      const value = await invoke<string>('detect_public_url');
      setConfig((current) => ({ ...current, public_url: value }));
      setMessage(`已检测到局域网公开地址：${value}，保存后生效`);
    } catch (error) {
      setMessage(`自动检测公开地址失败：${String(error)}`);
    } finally {
      setBusy(false);
    }
  };

  const createPairing = async () => {
    setPairingBusy(true);
    setMessage('正在创建一次性配对二维码…');
    try {
      const session = await invoke<PairingSession>('desktop_create_pairing');
      const payload = await invoke<BinaryPayload>('desktop_pairing_qr', { sessionId: session.id });
      setPairing(session);
      setQrDataUrl(await binaryToDataUrl(payload, 'image/png'));
      setNow(Date.now());
      setMessage('二维码已生成，请使用 Android 客户端扫描');
    } catch (error) {
      setPairing(null);
      setQrDataUrl('');
      setMessage(`创建配对二维码失败：${String(error)}`);
    } finally {
      setPairingBusy(false);
    }
  };

  const revokeDevice = async (device: Device) => {
    if (!window.confirm(`确定撤销设备“${device.name}”吗？撤销后该设备需要重新配对。`)) return;
    setPairingBusy(true);
    try {
      await invoke('desktop_revoke_device', { id: device.id });
      await loadDevices();
      setMessage(`设备“${device.name}”已撤销`);
    } catch (error) {
      setMessage(`撤销设备失败：${String(error)}`);
    } finally {
      setPairingBusy(false);
    }
  };

  const update = <K extends keyof AppConfig>(key: K, value: AppConfig[K]) => {
    setConfig((current) => ({ ...current, [key]: value }));
  };

  const updateLibrary = <K extends keyof LibraryConfig>(index: number, key: K, value: LibraryConfig[K]) => {
    setConfig((current) => ({
      ...current,
      libraries: current.libraries.map((library, itemIndex) =>
        itemIndex === index ? { ...library, [key]: value } : library,
      ),
    }));
  };

  const addLibrary = () => {
    const id = crypto.randomUUID().replaceAll('-', '').slice(0, 16);
    update('libraries', [
      ...config.libraries,
      { id, name: '新媒体库', path: 'D:\\Media', recursive: true, enabled: true },
    ]);
  };

  const removeLibrary = (index: number) => {
    update('libraries', config.libraries.filter((_, itemIndex) => itemIndex !== index));
  };

  const statusItems = useMemo(() => [
    { icon: 'server' as IconName, label: '服务名称', value: status.serverName, hint: `${status.backend} 后端` },
    { icon: 'network' as IconName, label: '监听地址', value: status.listenAddress, hint: '供局域网设备访问' },
    { icon: 'phone' as IconName, label: '公开地址', value: status.publicUrl || '尚未设置', hint: '用于移动端配对' },
    { icon: 'database' as IconName, label: '数据目录', value: status.dataDir || '尚未初始化', hint: '索引、缓存与配置' },
  ], [status]);

  const navItems: Array<{ key: Workspace; icon: IconName; label: string }> = [
    { key: 'media', icon: 'library', label: '资料库' },
    { key: 'overview', icon: 'dashboard', label: '概览' },
    { key: 'connections', icon: 'phone', label: '移动设备' },
  ];

  return (
    <div className={railExpanded ? 'lap-app rail-expanded' : 'lap-app'}>
      <aside className="lap-rail" aria-label="主导航">
        <button className="lap-brand-button" onClick={() => setWorkspace('media')} title="LocalLens">
          <span className="lap-brand-mark"><Icon name="logo" size={22} /></span>
          {railExpanded && <span className="lap-brand-copy"><strong>LocalLens</strong><small>本地媒体库</small></span>}
        </button>

        <nav className="lap-rail-nav">
          {navItems.map((item) => (
            <button
              aria-current={workspace === item.key ? 'page' : undefined}
              className={workspace === item.key ? 'lap-rail-button active' : 'lap-rail-button'}
              key={item.key}
              onClick={() => setWorkspace(item.key)}
              title={item.label}
            >
              <Icon name={item.icon} />
              {railExpanded && <span>{item.label}</span>}
            </button>
          ))}
        </nav>

        <div className="lap-rail-spacer" />

        <div className="lap-rail-state" title={status.running ? status.publicUrl || status.listenAddress : '服务已停止'}>
          <span className={status.running ? 'lap-state-dot online' : 'lap-state-dot'} />
          {railExpanded && <span>{status.running ? '服务运行中' : '服务已停止'}</span>}
        </div>

        <button className="lap-rail-button" onClick={() => setDarkMode((value) => !value)} title={darkMode ? '切换到浅色' : '切换到深色'}>
          <Icon name={darkMode ? 'sun' : 'moon'} />
          {railExpanded && <span>{darkMode ? '浅色模式' : '深色模式'}</span>}
        </button>

        <button
          className={workspace === 'settings' ? 'lap-rail-button active' : 'lap-rail-button'}
          onClick={() => setWorkspace('settings')}
          title="偏好设置"
        >
          <Icon name="settings" />
          {railExpanded && <span>偏好设置</span>}
        </button>

        <button className="lap-rail-button lap-collapse-button" onClick={() => setRailExpanded((value) => !value)} title={railExpanded ? '收起侧栏' : '展开侧栏'}>
          <Icon name={railExpanded ? 'collapse' : 'chevron'} />
          {railExpanded && <span>收起侧栏</span>}
        </button>
      </aside>

      <main className="lap-main">
        <header className="lap-topbar">
          <div className="lap-topbar-copy">
            <span>LocalLens</span>
            <Icon name="chevron" size={13} />
            <strong>{currentMeta.title}</strong>
            <small>{currentMeta.description}</small>
          </div>
          <div className="lap-topbar-actions">
            <span className={status.running ? 'lap-service-pill online' : 'lap-service-pill'}>
              <span className={status.running ? 'lap-state-dot online' : 'lap-state-dot'} />
              {status.running ? '运行中' : '已停止'}
            </span>
            <button className="lap-icon-button" disabled={busy} onClick={() => { void refresh(); setRefreshKey((value) => value + 1); }} title="刷新">
              <Icon name="refresh" />
            </button>
            {status.running ? (
              <button className="lap-button danger" disabled={busy} onClick={() => void changeRuntime('stop_server')}>
                <Icon name="stop" size={16} />停止服务
              </button>
            ) : (
              <button className="lap-button primary" disabled={busy} onClick={() => void changeRuntime('start_server')}>
                <Icon name="play" size={16} />启动服务
              </button>
            )}
          </div>
        </header>

        <div className={workspace === 'media' ? 'lap-workspace media-workspace' : 'lap-workspace'}>
          {workspace === 'media' && (
            <MediaBrowser onMessage={setMessage} refreshKey={refreshKey} running={status.running} />
          )}

          {workspace === 'overview' && (
            <div className="lap-page overview-page">
              <section className="lap-hero">
                <div>
                  <span className="lap-kicker">LOCAL-FIRST · RUST · TAURI 2</span>
                  <h1>照片留在磁盘，索引留在本机。</h1>
                  <p>LocalLens 直接浏览现有文件夹，维护缩略图、元数据、相册、标签与移动端访问，不要求上传云端。</p>
                  <div className="lap-hero-actions">
                    <button className="lap-button primary" onClick={() => setWorkspace('media')}><Icon name="library" size={17} />打开资料库</button>
                    <button className="lap-button" onClick={() => setWorkspace('settings')}><Icon name="folder" size={17} />管理文件夹</button>
                  </div>
                </div>
                <div className="lap-hero-orbit"><Icon name="logo" size={64} /></div>
              </section>

              <div className="lap-metric-grid">
                {statusItems.map((item) => (
                  <article className="lap-metric" key={item.label}>
                    <span className="lap-metric-icon"><Icon name={item.icon} /></span>
                    <small>{item.label}</small>
                    <strong title={item.value}>{item.value}</strong>
                    <p>{item.hint}</p>
                  </article>
                ))}
              </div>

              <div className="lap-two-column">
                <Panel title="快速入口" description="常用操作">
                  <div className="lap-quick-grid">
                    <button onClick={() => setWorkspace('media')}><Icon name="library" /><span><strong>浏览媒体</strong><small>图片、视频与目录</small></span></button>
                    <button onClick={() => setWorkspace('connections')}><Icon name="phone" /><span><strong>连接手机</strong><small>二维码与授权设备</small></span></button>
                    <button onClick={() => setWorkspace('settings')}><Icon name="folder" /><span><strong>添加文件夹</strong><small>扩展本地媒体来源</small></span></button>
                  </div>
                </Panel>

                <Panel title="运行信息" description="当前宿主环境">
                  <dl className="lap-runtime-list">
                    <div><dt>配置文件</dt><dd>{status.configPath || '正在初始化…'}</dd></div>
                    <div><dt>媒体库</dt><dd>{config.libraries.length} 个</dd></div>
                    <div><dt>文件监听</dt><dd>{config.watch_files ? '已启用' : '已关闭'}</dd></div>
                  </dl>
                  <button
                    className="lap-button"
                    disabled={!status.configPath}
                    onClick={() => void navigator.clipboard.writeText(status.configPath).then(() => setMessage('配置文件路径已复制'))}
                  >
                    <Icon name="copy" size={16} />复制配置路径
                  </button>
                </Panel>
              </div>
            </div>
          )}

          {workspace === 'connections' && (
            <div className="lap-page connection-page">
              <Panel title="一次性二维码" description="成功使用或到期后自动失效" className="pairing-panel">
                {!status.running ? (
                  <div className="lap-empty"><Icon name="server" size={34} /><strong>服务尚未启动</strong><span>启动 Rust 服务后才能生成配对二维码。</span></div>
                ) : qrDataUrl && pairing ? (
                  <div className="lap-qr-stage">
                    <div className={remainingSeconds > 0 ? 'lap-qr-frame' : 'lap-qr-frame expired'}><img alt="LocalLens 配对二维码" src={qrDataUrl} /></div>
                    <span className={remainingSeconds > 0 ? 'lap-countdown' : 'lap-countdown expired'}>
                      {remainingSeconds > 0 ? `${remainingSeconds} 秒后过期` : '二维码已过期'}
                    </span>
                    <p>{status.publicUrl || config.public_url}</p>
                    <div className="lap-inline-actions">
                      <button className="lap-button" disabled={remainingSeconds <= 0} onClick={() => void navigator.clipboard.writeText(pairing.payload).then(() => setMessage('配对信息已复制'))}><Icon name="copy" size={16} />复制</button>
                      <button className="lap-button primary" disabled={pairingBusy} onClick={() => void createPairing()}><Icon name="refresh" size={16} />重新生成</button>
                    </div>
                  </div>
                ) : (
                  <div className="lap-empty qr-empty">
                    <div className="lap-qr-placeholder">QR</div>
                    <strong>尚未生成二维码</strong>
                    <span>使用 Android 客户端扫描后即可访问媒体库。</span>
                    <button className="lap-button primary" disabled={pairingBusy} onClick={() => void createPairing()}><Icon name="plus" size={16} />生成配对二维码</button>
                  </div>
                )}
              </Panel>

              <Panel
                title="已配对设备"
                description={`${devices.length} 台设备已记录`}
                className="devices-panel"
                action={<button className="lap-button compact" disabled={!status.running || pairingBusy} onClick={() => void loadDevices()}><Icon name="refresh" size={15} />刷新</button>}
              >
                <div className="lap-device-list">
                  {devices.length === 0 && <div className="lap-empty"><Icon name="phone" size={32} /><strong>暂无设备</strong><span>生成二维码并使用手机扫描。</span></div>}
                  {devices.map((device) => (
                    <article className="lap-device" key={device.id}>
                      <span className="lap-device-icon"><Icon name="phone" /></span>
                      <div><strong>{device.name}</strong><span>{device.platform || '未知平台'} · 最近连接 {formatDate(device.lastSeenAt)}</span><small>创建于 {formatDate(device.createdAt)}</small></div>
                      <span className={device.revokedAt ? 'lap-device-status revoked' : 'lap-device-status'}>{device.revokedAt ? '已撤销' : '有效'}</span>
                      <button className="lap-icon-button danger" disabled={pairingBusy || Boolean(device.revokedAt)} onClick={() => void revokeDevice(device)} title="撤销设备"><Icon name="trash" size={17} /></button>
                    </article>
                  ))}
                </div>
              </Panel>
            </div>
          )}

          {workspace === 'settings' && (
            <div className="lap-page settings-page">
              <aside className="lap-settings-nav">
                <span>偏好设置</span>
                <a href="#general">常规</a>
                <a href="#tasks">后台任务</a>
                <a href="#security">安全与自动化</a>
                <a href="#libraries">媒体库</a>
              </aside>

              <div className="lap-settings-content">
                <Panel title="常规" description="网络与基础服务" className="settings-panel">
                  <div className="lap-form-grid" id="general">
                    <label><span>服务名称</span><input value={config.server_name} onChange={(event) => update('server_name', event.target.value)} /></label>
                    <label><span>监听地址</span><input value={config.listen_address} onChange={(event) => update('listen_address', event.target.value)} /></label>
                    <label className="span-2"><span>公开地址</span><div className="lap-field-action"><input value={config.public_url} onChange={(event) => update('public_url', event.target.value)} placeholder="http://192.168.1.20:9527" /><button className="lap-button compact" disabled={busy} onClick={() => void detectPublicUrl()}>自动检测</button></div><small>填写手机能够访问的 Windows 局域网地址。</small></label>
                    <label className="span-2"><span>数据目录</span><input value={config.data_dir} onChange={(event) => update('data_dir', event.target.value)} /></label>
                  </div>
                </Panel>

                <Panel title="后台任务" description="按电脑性能调整并发与转码" className="settings-panel">
                  <div className="lap-form-grid compact-grid" id="tasks">
                    <label><span>缩略图 Worker</span><input max={8} min={1} type="number" value={config.thumbnail_workers} onChange={(event) => update('thumbnail_workers', Number(event.target.value))} /></label>
                    <label><span>元数据 Worker</span><input max={8} min={1} type="number" value={config.metadata_workers} onChange={(event) => update('metadata_workers', Number(event.target.value))} /></label>
                    <label><span>转码 Worker</span><input max={4} min={1} type="number" value={config.transcode_workers} onChange={(event) => update('transcode_workers', Number(event.target.value))} /></label>
                    <label><span>转码缓存 GB</span><input max={500} min={1} type="number" value={config.transcode_cache_gb} onChange={(event) => update('transcode_cache_gb', Number(event.target.value))} /></label>
                    <label className="span-2"><span>转码方式</span><select value={config.transcode_hardware} onChange={(event) => update('transcode_hardware', event.target.value)}><option value="software">软件编码</option><option value="nvenc">NVIDIA NVENC</option><option value="qsv">Intel QSV</option><option value="amf">AMD AMF</option></select></label>
                  </div>
                </Panel>

                <Panel title="安全与自动化" description="配对凭据与媒体库维护策略" className="settings-panel">
                  <div className="lap-form-grid" id="security">
                    <label><span>配对有效期（分钟）</span><input max={60} min={1} type="number" value={config.pairing_ttl_minutes} onChange={(event) => update('pairing_ttl_minutes', Number(event.target.value))} /></label>
                    <label><span>管理员 Token</span><div className="lap-field-action"><input type="password" value={config.api_token} onChange={(event) => update('api_token', event.target.value)} /><button className="lap-button compact" onClick={() => update('api_token', `${crypto.randomUUID().replaceAll('-', '')}${crypto.randomUUID().replaceAll('-', '')}`)}>重新生成</button></div></label>
                    <label className="lap-toggle span-2"><input checked={config.auto_scan} type="checkbox" onChange={(event) => update('auto_scan', event.target.checked)} /><span><strong>启动时自动扫描</strong><small>程序启动后自动发现新增和变更文件。</small></span></label>
                    <label className="lap-toggle span-2"><input checked={config.watch_files} type="checkbox" onChange={(event) => update('watch_files', event.target.checked)} /><span><strong>实时监听文件变化</strong><small>媒体文件变化时自动更新索引。</small></span></label>
                  </div>
                </Panel>

                <Panel
                  title="媒体库"
                  description="直接使用现有文件夹，不搬移原始媒体"
                  className="settings-panel libraries-panel"
                  action={<button className="lap-button compact" onClick={addLibrary}><Icon name="plus" size={15} />添加媒体库</button>}
                >
                  <div className="lap-library-list" id="libraries">
                    {config.libraries.length === 0 && <div className="lap-empty"><Icon name="folder" size={34} /><strong>尚未配置媒体库</strong><span>添加一个保存图片或视频的 Windows 文件夹。</span></div>}
                    {config.libraries.map((library, index) => (
                      <article className="lap-library-editor" key={`${library.id}-${index}`}>
                        <span className="lap-library-icon"><Icon name="folder" /></span>
                        <div className="lap-form-grid">
                          <label><span>名称</span><input value={library.name} onChange={(event) => updateLibrary(index, 'name', event.target.value)} /></label>
                          <label><span>标识</span><input value={library.id} onChange={(event) => updateLibrary(index, 'id', event.target.value)} /></label>
                          <label className="span-2"><span>Windows 文件夹</span><input value={library.path} onChange={(event) => updateLibrary(index, 'path', event.target.value)} /></label>
                          <label className="lap-check"><input checked={library.recursive} type="checkbox" onChange={(event) => updateLibrary(index, 'recursive', event.target.checked)} />递归扫描子目录</label>
                          <label className="lap-check"><input checked={library.enabled} type="checkbox" onChange={(event) => updateLibrary(index, 'enabled', event.target.checked)} />启用媒体库</label>
                        </div>
                        <button className="lap-icon-button danger" onClick={() => removeLibrary(index)} title="删除媒体库"><Icon name="trash" size={17} /></button>
                      </article>
                    ))}
                  </div>
                </Panel>

                <div className="lap-save-bar">
                  <div><strong>保存后将重启本地服务</strong><span>系统会校验配置并等待当前端口释放。</span></div>
                  <button className="lap-button primary" disabled={busy} onClick={() => void saveConfig()}><Icon name="refresh" size={16} />保存并重启</button>
                </div>
              </div>
            </div>
          )}
        </div>

        <footer className="lap-statusbar">
          <div><span className={status.running ? 'lap-state-dot online' : 'lap-state-dot'} />{message}</div>
          <div><span>{config.libraries.length} 个媒体库</span><span>LocalLens v0.7.1</span><span>Lap-style workspace</span></div>
        </footer>
      </main>
    </div>
  );
}
