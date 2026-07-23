import { useCallback, useEffect, useMemo, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';

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

function localApiBase(listenAddress: string) {
  const lastColon = listenAddress.lastIndexOf(':');
  const port = lastColon >= 0 ? listenAddress.slice(lastColon + 1) : '9527';
  return `http://127.0.0.1:${port || '9527'}`;
}

async function apiError(response: Response) {
  try {
    const body = await response.json() as { error?: string };
    return body.error || `HTTP ${response.status}`;
  } catch {
    return `HTTP ${response.status}`;
  }
}

async function blobToDataUrl(blob: Blob) {
  return await new Promise<string>((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result));
    reader.onerror = () => reject(reader.error ?? new Error('读取二维码失败'));
    reader.readAsDataURL(blob);
  });
}

function formatDate(value?: string | null) {
  if (!value) return '尚未连接';
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? value : date.toLocaleString();
}

export default function App() {
  const [status, setStatus] = useState<RuntimeStatus>(emptyStatus);
  const [config, setConfig] = useState<AppConfig>(emptyConfig);
  const [busy, setBusy] = useState(false);
  const [pairingBusy, setPairingBusy] = useState(false);
  const [message, setMessage] = useState('正在读取本地服务状态…');
  const [pairing, setPairing] = useState<PairingSession | null>(null);
  const [qrDataUrl, setQrDataUrl] = useState('');
  const [devices, setDevices] = useState<Device[]>([]);
  const [now, setNow] = useState(Date.now());

  const apiBase = useMemo(() => localApiBase(status.listenAddress), [status.listenAddress]);
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
      setMessage(nextStatus.running ? 'Rust 媒体服务正在运行' : 'Rust 媒体服务已停止');
    } catch (error) {
      setMessage(`读取状态失败：${String(error)}`);
    }
  }, []);

  const loadDevices = useCallback(async () => {
    if (!status.running || !config.api_token) {
      setDevices([]);
      return;
    }
    try {
      const response = await fetch(`${apiBase}/api/v1/devices`, {
        headers: { Authorization: `Bearer ${config.api_token}` },
      });
      if (!response.ok) throw new Error(await apiError(response));
      const body = await response.json() as { items: Device[] };
      setDevices(body.items ?? []);
    } catch (error) {
      setMessage(`读取设备失败：${String(error)}`);
    }
  }, [apiBase, config.api_token, status.running]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  useEffect(() => {
    void loadDevices();
  }, [loadDevices]);

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
      setMessage('配置已保存，Rust 服务已重新启动');
    } catch (error) {
      setMessage(`保存配置失败：${String(error)}`);
    } finally {
      setBusy(false);
    }
  };

  const createPairing = async () => {
    setPairingBusy(true);
    setMessage('正在创建一次性配对二维码…');
    try {
      const response = await fetch(`${apiBase}/api/v1/pairing/session`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${config.api_token}` },
      });
      if (!response.ok) throw new Error(await apiError(response));
      const session = await response.json() as PairingSession;
      const qrResponse = await fetch(`${apiBase}${session.qrUrl}`, {
        headers: { Authorization: `Bearer ${config.api_token}` },
      });
      if (!qrResponse.ok) throw new Error(await apiError(qrResponse));
      setPairing(session);
      setQrDataUrl(await blobToDataUrl(await qrResponse.blob()));
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
      const response = await fetch(`${apiBase}/api/v1/devices/${encodeURIComponent(device.id)}`, {
        method: 'DELETE',
        headers: { Authorization: `Bearer ${config.api_token}` },
      });
      if (!response.ok) throw new Error(await apiError(response));
      await loadDevices();
      setMessage(`设备“${device.name}”已撤销`);
    } catch (error) {
      setMessage(`撤销设备失败：${String(error)}`);
    } finally {
      setPairingBusy(false);
    }
  };

  const copyConfigPath = async () => {
    await navigator.clipboard.writeText(status.configPath);
    setMessage('配置文件路径已复制');
  };

  const copyPairingPayload = async () => {
    if (!pairing) return;
    await navigator.clipboard.writeText(pairing.payload);
    setMessage('配对信息已复制');
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

  const regenerateToken = () => {
    update('api_token', `${crypto.randomUUID().replaceAll('-', '')}${crypto.randomUUID().replaceAll('-', '')}`);
  };

  return (
    <main className="app-shell">
      <header className="topbar">
        <div className="brand-mark">L</div>
        <div>
          <h1>LocalLens</h1>
          <p>Rust 本地媒体服务与桌面管理程序</p>
        </div>
        <span className={`status-pill ${status.running ? 'online' : 'offline'}`}>
          <span className="status-dot" />
          {status.running ? '运行中' : '已停止'}
        </span>
      </header>

      <section className="hero-card">
        <div>
          <span className="eyebrow">TAURI 2 · RUST</span>
          <h2>本地优先的媒体库控制中心</h2>
          <p>桌面应用直接嵌入 Rust 服务。Android 原生客户端通过局域网 API 扫码配对、浏览图片并播放视频。</p>
        </div>
        <div className="actions">
          {status.running ? (
            <button className="danger" disabled={busy} onClick={() => void changeRuntime('stop_server')}>停止服务</button>
          ) : (
            <button className="primary" disabled={busy} onClick={() => void changeRuntime('start_server')}>启动服务</button>
          )}
          <button className="secondary" disabled={busy} onClick={() => void refresh()}>刷新状态</button>
        </div>
      </section>

      <section className="grid">
        <article className="info-card"><span>服务名称</span><strong>{status.serverName}</strong><small>{status.backend} 后端</small></article>
        <article className="info-card"><span>监听地址</span><strong>{status.listenAddress}</strong><small>手机需访问 Windows 局域网地址</small></article>
        <article className="info-card"><span>公开地址</span><strong>{status.publicUrl || '尚未设置'}</strong><small>用于生成 Android 配对信息</small></article>
        <article className="info-card"><span>数据目录</span><strong className="path-value">{status.dataDir || '尚未初始化'}</strong><small>兼容原有 locallens.db</small></article>
      </section>

      <section className="config-panel">
        <div className="section-heading">
          <div><span className="eyebrow">移动端连接</span><h3>二维码配对与设备</h3></div>
          <div className="actions">
            <button className="secondary" disabled={!status.running || pairingBusy} onClick={() => void loadDevices()}>刷新设备</button>
            <button className="primary" disabled={!status.running || !config.api_token || pairingBusy} onClick={() => void createPairing()}>{pairing ? '重新生成二维码' : '生成配对二维码'}</button>
          </div>
        </div>
        {!status.running && <div className="empty-state">请先启动 Rust 服务，再生成移动端配对二维码。</div>}
        {status.running && (
          <div className="pairing-layout">
            <div className="pairing-card">
              {qrDataUrl && pairing ? (
                <>
                  <img className={remainingSeconds > 0 ? 'pairing-qr' : 'pairing-qr expired'} src={qrDataUrl} alt="LocalLens 配对二维码" />
                  <strong>{remainingSeconds > 0 ? `二维码将在 ${remainingSeconds} 秒后过期` : '二维码已过期，请重新生成'}</strong>
                  <small>二维码中的地址：{status.publicUrl || config.public_url}</small>
                  <button className="secondary" disabled={remainingSeconds <= 0} onClick={() => void copyPairingPayload()}>复制配对信息</button>
                </>
              ) : (
                <div className="pairing-placeholder">
                  <span>QR</span>
                  <strong>尚未生成二维码</strong>
                  <small>二维码为一次性凭据，成功配对或到期后自动失效。</small>
                </div>
              )}
            </div>
            <div className="device-list">
              {devices.length === 0 && <div className="empty-state">暂无已配对设备。</div>}
              {devices.map((device) => (
                <article className="device-row" key={device.id}>
                  <div>
                    <strong>{device.name}</strong>
                    <span>{device.platform || '未知平台'} · {device.revokedAt ? '已撤销' : '有效'}</span>
                    <small>最近连接：{formatDate(device.lastSeenAt)}　创建：{formatDate(device.createdAt)}</small>
                  </div>
                  <button className="danger" disabled={pairingBusy || Boolean(device.revokedAt)} onClick={() => void revokeDevice(device)}>{device.revokedAt ? '已撤销' : '撤销'}</button>
                </article>
              ))}
            </div>
          </div>
        )}
      </section>

      <section className="config-panel">
        <div className="section-heading">
          <div><span className="eyebrow">服务器配置</span><h3>局域网与后台任务</h3></div>
          <button className="primary" disabled={busy} onClick={() => void saveConfig()}>保存并重启</button>
        </div>
        <div className="form-grid">
          <label>服务名称<input value={config.server_name} onChange={(event) => update('server_name', event.target.value)} /></label>
          <label>监听地址<input value={config.listen_address} onChange={(event) => update('listen_address', event.target.value)} /></label>
          <label className="wide">公开地址<input value={config.public_url} onChange={(event) => update('public_url', event.target.value)} placeholder="http://192.168.1.20:9527" /><small>必须填写手机能够访问的 Windows 局域网地址。</small></label>
          <label className="wide">数据目录<input value={config.data_dir} onChange={(event) => update('data_dir', event.target.value)} /></label>
          <label>缩略图 Worker<input type="number" min="1" max="8" value={config.thumbnail_workers} onChange={(event) => update('thumbnail_workers', Number(event.target.value))} /></label>
          <label>元数据 Worker<input type="number" min="1" max="8" value={config.metadata_workers} onChange={(event) => update('metadata_workers', Number(event.target.value))} /></label>
          <label>转码 Worker<input type="number" min="1" max="4" value={config.transcode_workers} onChange={(event) => update('transcode_workers', Number(event.target.value))} /></label>
          <label>转码缓存 GB<input type="number" min="1" max="500" value={config.transcode_cache_gb} onChange={(event) => update('transcode_cache_gb', Number(event.target.value))} /></label>
          <label>转码方式<select value={config.transcode_hardware} onChange={(event) => update('transcode_hardware', event.target.value)}><option value="software">软件编码</option><option value="nvenc">NVIDIA NVENC</option><option value="qsv">Intel QSV</option><option value="amf">AMD AMF</option></select></label>
          <label>配对有效期（分钟）<input type="number" min="1" max="60" value={config.pairing_ttl_minutes} onChange={(event) => update('pairing_ttl_minutes', Number(event.target.value))} /></label>
          <label className="wide token-field">管理员 Token<div><input type="password" value={config.api_token} onChange={(event) => update('api_token', event.target.value)} /><button className="secondary" type="button" onClick={regenerateToken}>重新生成</button></div></label>
          <label className="check"><input type="checkbox" checked={config.auto_scan} onChange={(event) => update('auto_scan', event.target.checked)} />启动时自动扫描</label>
          <label className="check"><input type="checkbox" checked={config.watch_files} onChange={(event) => update('watch_files', event.target.checked)} />实时监听文件变化</label>
        </div>
      </section>

      <section className="config-panel">
        <div className="section-heading">
          <div><span className="eyebrow">媒体库</span><h3>本地文件夹</h3></div>
          <button className="secondary" onClick={addLibrary}>添加媒体库</button>
        </div>
        <div className="library-list">
          {config.libraries.length === 0 && <div className="empty-state">尚未配置媒体库。添加一个 Windows 图片或视频文件夹后保存。</div>}
          {config.libraries.map((library, index) => (
            <article className="library-row" key={`${library.id}-${index}`}>
              <div className="library-fields">
                <label>名称<input value={library.name} onChange={(event) => updateLibrary(index, 'name', event.target.value)} /></label>
                <label>标识<input value={library.id} onChange={(event) => updateLibrary(index, 'id', event.target.value)} /></label>
                <label className="wide">Windows 文件夹<input value={library.path} onChange={(event) => updateLibrary(index, 'path', event.target.value)} /></label>
                <label className="check"><input type="checkbox" checked={library.recursive} onChange={(event) => updateLibrary(index, 'recursive', event.target.checked)} />递归扫描子目录</label>
                <label className="check"><input type="checkbox" checked={library.enabled} onChange={(event) => updateLibrary(index, 'enabled', event.target.checked)} />启用媒体库</label>
              </div>
              <button className="danger" onClick={() => removeLibrary(index)}>删除</button>
            </article>
          ))}
        </div>
      </section>

      <section className="settings-card">
        <div><span className="eyebrow">配置与迁移</span><h3>配置文件</h3><code>{status.configPath || '正在初始化…'}</code><p>保存配置会校验字段、停止当前服务并使用新配置重新启动。首次 Rust 迁移会自动备份旧数据库。</p></div>
        <button className="secondary" disabled={!status.configPath} onClick={() => void copyConfigPath()}>复制路径</button>
      </section>

      <footer className="message-bar">{message}</footer>
    </main>
  );
}
