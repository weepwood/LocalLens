import { useCallback, useEffect, useState } from 'react';
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

const emptyStatus: RuntimeStatus = {
  running: false,
  serverName: 'LocalLens',
  listenAddress: '0.0.0.0:9527',
  publicUrl: '',
  configPath: '',
  dataDir: '',
  backend: 'Rust',
};

export default function App() {
  const [status, setStatus] = useState<RuntimeStatus>(emptyStatus);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState('正在读取本地服务状态…');

  const refresh = useCallback(async () => {
    try {
      const next = await invoke<RuntimeStatus>('runtime_status');
      setStatus(next);
      setMessage(next.running ? 'Rust 媒体服务正在运行' : 'Rust 媒体服务已停止');
    } catch (error) {
      setMessage(`读取状态失败：${String(error)}`);
    }
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const changeRuntime = async (action: 'start_server' | 'stop_server') => {
    setBusy(true);
    setMessage(action === 'start_server' ? '正在启动 Rust 服务…' : '正在停止 Rust 服务…');
    try {
      await invoke(action);
      await refresh();
    } catch (error) {
      setMessage(`操作失败：${String(error)}`);
    } finally {
      setBusy(false);
    }
  };

  const copyConfigPath = async () => {
    await navigator.clipboard.writeText(status.configPath);
    setMessage('配置文件路径已复制');
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
          <p>
            桌面应用直接嵌入 Rust 服务，不再依赖外部 Go 进程。Android 原生客户端通过同一套局域网 API 浏览媒体。
          </p>
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
        <article className="info-card">
          <span>服务名称</span>
          <strong>{status.serverName}</strong>
          <small>{status.backend} 后端</small>
        </article>
        <article className="info-card">
          <span>监听地址</span>
          <strong>{status.listenAddress}</strong>
          <small>手机需访问 Windows 局域网地址</small>
        </article>
        <article className="info-card">
          <span>公开地址</span>
          <strong>{status.publicUrl || '尚未设置'}</strong>
          <small>用于生成 Android 配对信息</small>
        </article>
        <article className="info-card">
          <span>数据目录</span>
          <strong className="path-value">{status.dataDir || '尚未初始化'}</strong>
          <small>兼容原有 locallens.db</small>
        </article>
      </section>

      <section className="settings-card">
        <div>
          <span className="eyebrow">配置与迁移</span>
          <h3>配置文件</h3>
          <code>{status.configPath || '正在初始化…'}</code>
          <p>Rust 后端继续识别原来的 JSON 配置字段和 SQLite 数据库，迁移时无需删除媒体索引。</p>
        </div>
        <button className="secondary" disabled={!status.configPath} onClick={() => void copyConfigPath()}>复制路径</button>
      </section>

      <footer className="message-bar">{message}</footer>
    </main>
  );
}
