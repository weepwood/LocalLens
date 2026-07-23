import { useCallback, useEffect, useMemo, useState } from 'react';
import { Button, Card, Chip, Input, Spinner } from '@heroui/react';
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
type Workspace = 'overview' | 'media' | 'connections' | 'settings';

type IconName = 'home' | 'media' | 'phone' | 'settings' | 'server' | 'refresh' | 'play' | 'stop' | 'copy' | 'plus' | 'trash' | 'network' | 'database' | 'folder';

const iconPaths: Record<IconName, string[]> = {
  home: ['M3 11.5 12 4l9 7.5', 'M5 10.5V20h14v-9.5', 'M9 20v-6h6v6'],
  media: ['M4 5h16v14H4z', 'm7 14 4-4 3 3 2-2 3 3', 'M9 9h.01'],
  phone: ['M8 3h8a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2Z', 'M10 17h4'],
  settings: ['M12 15.5a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7Z', 'M19.4 15a1.7 1.7 0 0 0 .34 1.88l.06.06-2.1 3.64-.08-.02a1.7 1.7 0 0 0-1.8-.28l-.04.02a1.7 1.7 0 0 0-1.02 1.58V22h-4.2v-.12a1.7 1.7 0 0 0-1.02-1.58l-.04-.02a1.7 1.7 0 0 0-1.8.28l-.08.02-2.1-3.64.06-.06A1.7 1.7 0 0 0 4.6 15v-.04A1.7 1.7 0 0 0 3.2 13.7H3V9.5h.2a1.7 1.7 0 0 0 1.4-1.26V8.2a1.7 1.7 0 0 0-.34-1.88l-.06-.06 2.1-3.64.08.02a1.7 1.7 0 0 0 1.8.28l.04-.02A1.7 1.7 0 0 0 9.24 1.34V1.2h4.2v.14a1.7 1.7 0 0 0 1.02 1.58l.04.02a1.7 1.7 0 0 0 1.8-.28l.08-.02 2.1 3.64-.06.06a1.7 1.7 0 0 0-.34 1.88v.04a1.7 1.7 0 0 0 1.4 1.26h.2v4.2h-.2a1.7 1.7 0 0 0-1.4 1.26Z'],
  server: ['M4 5h16v5H4z', 'M4 14h16v5H4z', 'M7 7.5h.01', 'M7 16.5h.01'],
  refresh: ['M20 6v5h-5', 'M4 18v-5h5', 'M18.5 10A7 7 0 0 0 6.2 6.3L4 11', 'M5.5 14A7 7 0 0 0 17.8 17.7L20 13'],
  play: ['M8 5v14l11-7Z'],
  stop: ['M7 7h10v10H7z'],
  copy: ['M8 8h11v11H8z', 'M5 16H4V4h12v1'],
  plus: ['M12 5v14', 'M5 12h14'],
  trash: ['M4 7h16', 'M9 7V4h6v3', 'm7 7 1 13h8l1-13'],
  network: ['M5 12a7 7 0 0 1 14 0', 'M8 12a4 4 0 0 1 8 0', 'M12 16h.01'],
  database: ['M4 6c0 2 3.6 3 8 3s8-1 8-3-3.6-3-8-3-8 1-8 3Z', 'M4 6v6c0 2 3.6 3 8 3s8-1 8-3V6', 'M4 12v6c0 2 3.6 3 8 3s8-1 8-3v-6'],
  folder: ['M3 6h7l2 2h9v11H3z'],
};

function Icon({ name, size = 19 }: { name: IconName; size?: number }) {
  return (
    <svg aria-hidden="true" className="ui-icon" fill="none" height={size} viewBox="0 0 24 24" width={size}>
      {iconPaths[name].map((path) => <path d={path} key={path} stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.8" />)}
    </svg>
  );
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

const workspaceMeta: Record<Workspace, { eyebrow: string; title: string; description: string }> = {
  overview: { eyebrow: '工作台', title: '本地媒体服务', description: '查看服务状态、入口地址和当前运行环境。' },
  media: { eyebrow: '媒体中心', title: '图片与视频', description: '浏览、筛选和整理所有本地媒体内容。' },
  connections: { eyebrow: '移动端', title: '配对与设备', description: '生成一次性二维码并管理已授权的移动设备。' },
  settings: { eyebrow: '系统设置', title: '服务与媒体库', description: '配置网络、后台任务、安全选项和本地文件夹。' },
};

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

  const currentMeta = workspaceMeta[workspace];
  const remainingSeconds = pairing
    ? Math.max(0, Math.ceil((new Date(pairing.expiresAt).getTime() - now) / 1000))
    : 0;

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
    setMessage('正在检测 Windows 局域网地址…');
    try {
      const value = await invoke<string>('suggest_public_url');
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
    { icon: 'database' as IconName, label: '数据目录', value: status.dataDir || '尚未初始化', hint: '保存索引、缓存和配置' },
  ], [status]);

  return (
    <div className="desktop-shell">
      <aside className="desktop-sidebar">
        <div className="brand-block">
          <div className="brand-symbol">L</div>
          <div><strong>LocalLens</strong><span>Windows 媒体中心</span></div>
        </div>

        <nav className="sidebar-nav" aria-label="主导航">
          {([
            ['overview', 'home', '概览'],
            ['media', 'media', '媒体中心'],
            ['connections', 'phone', '移动端连接'],
            ['settings', 'settings', '系统设置'],
          ] as Array<[Workspace, IconName, string]>).map(([key, icon, label]) => (
            <button className={workspace === key ? 'nav-item active' : 'nav-item'} key={key} onClick={() => setWorkspace(key)}>
              <Icon name={icon} />
              <span>{label}</span>
            </button>
          ))}
        </nav>

        <Card className="sidebar-status" variant="secondary">
          <Card.Content>
            <div className="sidebar-status-row"><span className={status.running ? 'live-dot online' : 'live-dot'} /><strong>{status.running ? '服务运行中' : '服务已停止'}</strong></div>
            <p>{status.running ? status.publicUrl || status.listenAddress : '启动服务后可浏览媒体并连接手机。'}</p>
          </Card.Content>
        </Card>

        <div className="sidebar-version">LocalLens v0.7.1 · HeroUI</div>
      </aside>

      <main className="desktop-main">
        <header className="workspace-header">
          <div>
            <span className="workspace-eyebrow">{currentMeta.eyebrow}</span>
            <h1>{currentMeta.title}</h1>
            <p>{currentMeta.description}</p>
          </div>
          <div className="header-actions">
            <Chip className={status.running ? 'status-chip online' : 'status-chip'}>{status.running ? '运行中' : '已停止'}</Chip>
            <Button isIconOnly aria-label="刷新状态" isDisabled={busy} onPress={() => { void refresh(); setRefreshKey((value) => value + 1); }} variant="secondary"><Icon name="refresh" /></Button>
            {status.running ? (
              <Button isDisabled={busy} onPress={() => void changeRuntime('stop_server')} variant="danger-soft"><Icon name="stop" />停止服务</Button>
            ) : (
              <Button isDisabled={busy} onPress={() => void changeRuntime('start_server')} variant="primary"><Icon name="play" />启动服务</Button>
            )}
          </div>
        </header>

        <div className="workspace-scroll">
          {workspace === 'overview' && (
            <section className="overview-layout">
              <div className="overview-banner">
                <div>
                  <Chip className="banner-chip">TAURI 2 · RUST · HEROUI</Chip>
                  <h2>你的本地图片与视频，始终留在自己的电脑上。</h2>
                  <p>LocalLens 负责索引、缩略图、移动端访问与整理；打开媒体时直接调用 Windows 默认图片或视频应用。</p>
                </div>
                <div className="banner-orb"><Icon name="media" size={42} /></div>
              </div>

              <div className="status-card-grid">
                {statusItems.map((item) => (
                  <Card className="metric-card" key={item.label}>
                    <Card.Content>
                      <div className="metric-icon"><Icon name={item.icon} /></div>
                      <span>{item.label}</span>
                      <strong title={item.value}>{item.value}</strong>
                      <small>{item.hint}</small>
                    </Card.Content>
                  </Card>
                ))}
              </div>

              <div className="overview-columns">
                <Card className="feature-card">
                  <Card.Header><Card.Title>快速开始</Card.Title><Card.Description>常用入口集中在这里。</Card.Description></Card.Header>
                  <Card.Content className="quick-actions">
                    <button onClick={() => setWorkspace('media')}><span><Icon name="media" /></span><div><strong>浏览媒体</strong><small>打开图片、视频和整理工具</small></div></button>
                    <button onClick={() => setWorkspace('connections')}><span><Icon name="phone" /></span><div><strong>连接手机</strong><small>生成二维码并管理设备</small></div></button>
                    <button onClick={() => setWorkspace('settings')}><span><Icon name="folder" /></span><div><strong>添加文件夹</strong><small>配置本地媒体库来源</small></div></button>
                  </Card.Content>
                </Card>

                <Card className="feature-card">
                  <Card.Header><Card.Title>运行信息</Card.Title><Card.Description>当前配置文件与数据位置。</Card.Description></Card.Header>
                  <Card.Content className="runtime-details">
                    <div><span>配置文件</span><code>{status.configPath || '正在初始化…'}</code></div>
                    <div><span>媒体库数量</span><strong>{config.libraries.length}</strong></div>
                    <div><span>文件监听</span><strong>{config.watch_files ? '已启用' : '已关闭'}</strong></div>
                    <Button isDisabled={!status.configPath} onPress={() => void navigator.clipboard.writeText(status.configPath).then(() => setMessage('配置文件路径已复制'))} variant="secondary"><Icon name="copy" />复制配置路径</Button>
                  </Card.Content>
                </Card>
              </div>
            </section>
          )}

          {workspace === 'media' && <MediaBrowser onMessage={setMessage} refreshKey={refreshKey} running={status.running} />}

          {workspace === 'connections' && (
            <section className="connection-layout">
              <Card className="pairing-panel">
                <Card.Header>
                  <Card.Title>一次性二维码</Card.Title>
                  <Card.Description>二维码成功使用或到期后自动失效。</Card.Description>
                </Card.Header>
                <Card.Content>
                  {!status.running ? (
                    <div className="panel-empty"><Icon name="server" size={34} /><strong>服务尚未启动</strong><span>启动 Rust 服务后才能生成配对二维码。</span></div>
                  ) : qrDataUrl && pairing ? (
                    <div className="qr-stage">
                      <div className={remainingSeconds > 0 ? 'qr-frame' : 'qr-frame expired'}><img alt="LocalLens 配对二维码" src={qrDataUrl} /></div>
                      <Chip className={remainingSeconds > 0 ? 'countdown-chip' : 'countdown-chip expired'}>{remainingSeconds > 0 ? `${remainingSeconds} 秒后过期` : '二维码已过期'}</Chip>
                      <p>{status.publicUrl || config.public_url}</p>
                      <div className="inline-actions">
                        <Button isDisabled={remainingSeconds <= 0} onPress={() => void navigator.clipboard.writeText(pairing.payload).then(() => setMessage('配对信息已复制'))} variant="secondary"><Icon name="copy" />复制配对信息</Button>
                        <Button isDisabled={pairingBusy} onPress={() => void createPairing()} variant="primary"><Icon name="refresh" />重新生成</Button>
                      </div>
                    </div>
                  ) : (
                    <div className="panel-empty qr-empty"><div className="qr-placeholder">QR</div><strong>尚未生成二维码</strong><span>使用 Android 客户端扫描后即可访问媒体库。</span><Button isDisabled={pairingBusy} onPress={() => void createPairing()} variant="primary">{pairingBusy ? <Spinner size="sm" /> : <Icon name="plus" />}生成配对二维码</Button></div>
                  )}
                </Card.Content>
              </Card>

              <Card className="devices-panel">
                <Card.Header className="split-card-header"><div><Card.Title>已配对设备</Card.Title><Card.Description>{devices.length} 台设备已记录</Card.Description></div><Button isDisabled={!status.running || pairingBusy} onPress={() => void loadDevices()} variant="secondary"><Icon name="refresh" />刷新</Button></Card.Header>
                <Card.Content className="device-stack">
                  {devices.length === 0 && <div className="panel-empty"><Icon name="phone" size={32} /><strong>暂无设备</strong><span>生成二维码并使用手机扫描。</span></div>}
                  {devices.map((device) => (
                    <div className="device-item" key={device.id}>
                      <div className="device-avatar"><Icon name="phone" /></div>
                      <div className="device-copy"><strong>{device.name}</strong><span>{device.platform || '未知平台'} · 最近连接 {formatDate(device.lastSeenAt)}</span><small>创建于 {formatDate(device.createdAt)}</small></div>
                      <Chip className={device.revokedAt ? 'device-state revoked' : 'device-state'}>{device.revokedAt ? '已撤销' : '有效'}</Chip>
                      <Button isDisabled={pairingBusy || Boolean(device.revokedAt)} isIconOnly aria-label="撤销设备" onPress={() => void revokeDevice(device)} variant="danger-soft"><Icon name="trash" /></Button>
                    </div>
                  ))}
                </Card.Content>
              </Card>
            </section>
          )}

          {workspace === 'settings' && (
            <section className="settings-layout">
              <Card className="settings-section">
                <Card.Header><Card.Title>网络与基础服务</Card.Title><Card.Description>决定 Windows 服务如何被本机和移动设备访问。</Card.Description></Card.Header>
                <Card.Content className="settings-grid">
                  <label><span>服务名称</span><Input fullWidth value={config.server_name} onChange={(event) => update('server_name', event.target.value)} variant="secondary" /></label>
                  <label><span>监听地址</span><Input fullWidth value={config.listen_address} onChange={(event) => update('listen_address', event.target.value)} variant="secondary" /></label>
                  <label className="span-2"><span>公开地址</span><div className="field-with-action"><Input fullWidth value={config.public_url} onChange={(event) => update('public_url', event.target.value)} placeholder="http://192.168.1.20:9527" variant="secondary" /><Button isDisabled={busy} onPress={() => void detectPublicUrl()} variant="secondary">自动检测</Button></div><small>填写手机能够访问的 Windows 局域网地址。</small></label>
                  <label className="span-2"><span>数据目录</span><Input fullWidth value={config.data_dir} onChange={(event) => update('data_dir', event.target.value)} variant="secondary" /></label>
                </Card.Content>
              </Card>

              <Card className="settings-section">
                <Card.Header><Card.Title>后台任务与转码</Card.Title><Card.Description>按电脑性能调整并发任务和转码缓存。</Card.Description></Card.Header>
                <Card.Content className="settings-grid compact-grid">
                  <label><span>缩略图 Worker</span><Input fullWidth max={8} min={1} type="number" value={config.thumbnail_workers} onChange={(event) => update('thumbnail_workers', Number(event.target.value))} variant="secondary" /></label>
                  <label><span>元数据 Worker</span><Input fullWidth max={8} min={1} type="number" value={config.metadata_workers} onChange={(event) => update('metadata_workers', Number(event.target.value))} variant="secondary" /></label>
                  <label><span>转码 Worker</span><Input fullWidth max={4} min={1} type="number" value={config.transcode_workers} onChange={(event) => update('transcode_workers', Number(event.target.value))} variant="secondary" /></label>
                  <label><span>转码缓存 GB</span><Input fullWidth max={500} min={1} type="number" value={config.transcode_cache_gb} onChange={(event) => update('transcode_cache_gb', Number(event.target.value))} variant="secondary" /></label>
                  <label className="span-2"><span>转码方式</span><select className="hero-select" value={config.transcode_hardware} onChange={(event) => update('transcode_hardware', event.target.value)}><option value="software">软件编码</option><option value="nvenc">NVIDIA NVENC</option><option value="qsv">Intel QSV</option><option value="amf">AMD AMF</option></select></label>
                </Card.Content>
              </Card>

              <Card className="settings-section">
                <Card.Header><Card.Title>安全与自动化</Card.Title><Card.Description>控制配对凭据和媒体库自动维护策略。</Card.Description></Card.Header>
                <Card.Content className="settings-grid">
                  <label><span>配对有效期（分钟）</span><Input fullWidth max={60} min={1} type="number" value={config.pairing_ttl_minutes} onChange={(event) => update('pairing_ttl_minutes', Number(event.target.value))} variant="secondary" /></label>
                  <label><span>管理员 Token</span><div className="field-with-action"><Input fullWidth type="password" value={config.api_token} onChange={(event) => update('api_token', event.target.value)} variant="secondary" /><Button onPress={() => update('api_token', `${crypto.randomUUID().replaceAll('-', '')}${crypto.randomUUID().replaceAll('-', '')}`)} variant="secondary">重新生成</Button></div></label>
                  <label className="toggle-row"><input checked={config.auto_scan} type="checkbox" onChange={(event) => update('auto_scan', event.target.checked)} /><div><strong>启动时自动扫描</strong><small>程序启动后自动发现新增和变更文件。</small></div></label>
                  <label className="toggle-row"><input checked={config.watch_files} type="checkbox" onChange={(event) => update('watch_files', event.target.checked)} /><div><strong>实时监听文件变化</strong><small>媒体文件变化时自动更新索引。</small></div></label>
                </Card.Content>
              </Card>

              <Card className="settings-section libraries-settings">
                <Card.Header className="split-card-header"><div><Card.Title>媒体库文件夹</Card.Title><Card.Description>每个来源可以单独启用、关闭或递归扫描。</Card.Description></div><Button onPress={addLibrary} variant="secondary"><Icon name="plus" />添加媒体库</Button></Card.Header>
                <Card.Content className="configured-libraries">
                  {config.libraries.length === 0 && <div className="panel-empty"><Icon name="folder" size={34} /><strong>尚未配置媒体库</strong><span>添加一个保存图片或视频的 Windows 文件夹。</span></div>}
                  {config.libraries.map((library, index) => (
                    <div className="configured-library" key={`${library.id}-${index}`}>
                      <div className="library-index"><Icon name="folder" /></div>
                      <div className="library-fields-modern">
                        <label><span>名称</span><Input fullWidth value={library.name} onChange={(event) => updateLibrary(index, 'name', event.target.value)} variant="secondary" /></label>
                        <label><span>标识</span><Input fullWidth value={library.id} onChange={(event) => updateLibrary(index, 'id', event.target.value)} variant="secondary" /></label>
                        <label className="span-2"><span>Windows 文件夹</span><Input fullWidth value={library.path} onChange={(event) => updateLibrary(index, 'path', event.target.value)} variant="secondary" /></label>
                        <label className="mini-check"><input checked={library.recursive} type="checkbox" onChange={(event) => updateLibrary(index, 'recursive', event.target.checked)} />递归扫描子目录</label>
                        <label className="mini-check"><input checked={library.enabled} type="checkbox" onChange={(event) => updateLibrary(index, 'enabled', event.target.checked)} />启用媒体库</label>
                      </div>
                      <Button isIconOnly aria-label="删除媒体库" onPress={() => removeLibrary(index)} variant="danger-soft"><Icon name="trash" /></Button>
                    </div>
                  ))}
                </Card.Content>
              </Card>

              <div className="settings-save-bar">
                <div><strong>保存后将重启本地服务</strong><span>系统会校验配置并等待当前端口释放。</span></div>
                <Button isDisabled={busy} onPress={() => void saveConfig()} variant="primary">{busy ? <Spinner size="sm" /> : <Icon name="refresh" />}保存并重启</Button>
              </div>
            </section>
          )}
        </div>
      </main>

      <div className="global-message"><span className={status.running ? 'message-indicator online' : 'message-indicator'} />{message}</div>
    </div>
  );
}
