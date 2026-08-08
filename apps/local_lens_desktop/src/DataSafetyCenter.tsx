import { useCallback, useEffect, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';

interface DatabaseHealth {
  status: string;
  quickCheck: string;
  foreignKeyViolations: number;
  databaseSizeBytes: number;
  walSizeBytes: number;
  databasePath: string;
  checkedAt: string;
}

interface BackupSnapshot {
  id: string;
  createdAt: string;
  path: string;
  databaseSizeBytes: number;
  databaseSha256: string;
  verified: boolean;
}

function formatBytes(value: number) {
  if (!Number.isFinite(value) || value <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  const index = Math.min(Math.floor(Math.log(value) / Math.log(1024)), units.length - 1);
  const amount = value / 1024 ** index;
  return `${amount >= 100 || index === 0 ? amount.toFixed(0) : amount.toFixed(1)} ${units[index]}`;
}

function formatDate(value: string) {
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? value : date.toLocaleString();
}

export default function DataSafetyCenter() {
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [health, setHealth] = useState<DatabaseHealth | null>(null);
  const [backups, setBackups] = useState<BackupSnapshot[]>([]);
  const [message, setMessage] = useState('');

  const refresh = useCallback(async () => {
    setBusy(true);
    setMessage('正在检查数据库与备份记录…');
    try {
      const [nextHealth, nextBackups] = await Promise.all([
        invoke<DatabaseHealth>('desktop_database_health'),
        invoke<BackupSnapshot[]>('desktop_list_backups'),
      ]);
      setHealth(nextHealth);
      setBackups(nextBackups);
      setMessage(nextHealth.status === 'ok' ? '数据库完整性检查通过' : '数据库检查发现异常，请先停止写入并备份数据目录');
    } catch (error) {
      setHealth(null);
      setMessage(`数据安全检查失败：${String(error)}`);
    } finally {
      setBusy(false);
    }
  }, []);

  useEffect(() => {
    if (open) void refresh();
  }, [open, refresh]);

  const createBackup = async () => {
    setBusy(true);
    setMessage('正在创建可验证 SQLite 快照…');
    try {
      const snapshot = await invoke<BackupSnapshot>('desktop_create_backup');
      setBackups((current) => [snapshot, ...current.filter((item) => item.id !== snapshot.id)]);
      setMessage(`备份已创建：${snapshot.path}`);
      await refresh();
    } catch (error) {
      setMessage(`创建备份失败：${String(error)}`);
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      <style>{`
        .ll-safety-launcher{position:fixed;right:18px;bottom:42px;z-index:80;border:1px solid rgba(127,127,127,.28);border-radius:999px;padding:9px 14px;background:rgba(30,34,43,.92);color:#fff;box-shadow:0 10px 30px rgba(0,0,0,.24);font:600 13px/1.2 system-ui;cursor:pointer;backdrop-filter:blur(16px)}
        html[data-theme="locallens-light"] .ll-safety-launcher{background:rgba(255,255,255,.94);color:#18202c}
        .ll-safety-overlay{position:fixed;inset:0;z-index:200;display:grid;place-items:center;padding:28px;background:rgba(5,8,14,.62);backdrop-filter:blur(8px)}
        .ll-safety-dialog{width:min(760px,100%);max-height:min(760px,calc(100vh - 56px));overflow:auto;border:1px solid rgba(127,127,127,.28);border-radius:20px;background:#151a22;color:#edf2f7;box-shadow:0 26px 80px rgba(0,0,0,.46);font-family:system-ui,-apple-system,"Microsoft YaHei UI",sans-serif}
        html[data-theme="locallens-light"] .ll-safety-dialog{background:#fff;color:#18202c}
        .ll-safety-head,.ll-safety-actions,.ll-safety-status,.ll-safety-backup{display:flex;align-items:center;gap:12px}.ll-safety-head{justify-content:space-between;padding:20px 22px;border-bottom:1px solid rgba(127,127,127,.2)}
        .ll-safety-head h2{margin:0;font-size:20px}.ll-safety-head p{margin:4px 0 0;color:#99a4b2;font-size:13px}.ll-safety-body{display:grid;gap:18px;padding:20px 22px}.ll-safety-actions{flex-wrap:wrap}.ll-safety-button{border:1px solid rgba(127,127,127,.3);border-radius:10px;padding:9px 13px;background:transparent;color:inherit;font-weight:600;cursor:pointer}.ll-safety-button.primary{border-color:#4f8cff;background:#3778f6;color:#fff}.ll-safety-button:disabled{opacity:.5;cursor:not-allowed}.ll-safety-close{border:0;background:transparent;color:inherit;font-size:24px;cursor:pointer}
        .ll-safety-grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px}.ll-safety-metric{padding:14px;border:1px solid rgba(127,127,127,.22);border-radius:14px;background:rgba(127,127,127,.07)}.ll-safety-metric span{display:block;color:#99a4b2;font-size:12px}.ll-safety-metric strong{display:block;margin-top:7px;font-size:17px;overflow-wrap:anywhere}.ll-safety-status{justify-content:space-between;padding:12px 14px;border-radius:12px;background:rgba(55,120,246,.12);font-size:13px}.ll-safety-status.warning{background:rgba(235,165,44,.14)}
        .ll-safety-section h3{margin:0 0 10px;font-size:15px}.ll-safety-list{display:grid;gap:9px}.ll-safety-backup{align-items:flex-start;padding:12px 14px;border:1px solid rgba(127,127,127,.2);border-radius:12px}.ll-safety-backup>div{min-width:0;flex:1}.ll-safety-backup strong,.ll-safety-backup span,.ll-safety-backup small{display:block}.ll-safety-backup span{margin-top:3px;color:#99a4b2;font-size:12px;overflow-wrap:anywhere}.ll-safety-backup small{margin-top:5px;color:#7f8a98}.ll-safety-badge{flex:0 0 auto;border-radius:999px;padding:4px 8px;background:rgba(61,190,118,.15);color:#55d58b;font-size:11px;font-weight:700}.ll-safety-empty{padding:24px;text-align:center;color:#99a4b2;border:1px dashed rgba(127,127,127,.3);border-radius:12px}
        @media(max-width:620px){.ll-safety-grid{grid-template-columns:1fr}.ll-safety-overlay{padding:12px}.ll-safety-dialog{max-height:calc(100vh - 24px)}}
      `}</style>
      <button className="ll-safety-launcher" onClick={() => setOpen(true)} title="数据库自检与备份">数据安全</button>
      {open && (
        <div className="ll-safety-overlay" onMouseDown={(event) => { if (event.target === event.currentTarget) setOpen(false); }}>
          <section aria-modal="true" className="ll-safety-dialog" role="dialog">
            <header className="ll-safety-head">
              <div><h2>数据安全中心</h2><p>检查 SQLite 完整性并创建带校验值的本地快照。</p></div>
              <button aria-label="关闭" className="ll-safety-close" onClick={() => setOpen(false)}>×</button>
            </header>
            <div className="ll-safety-body">
              <div className="ll-safety-actions">
                <button className="ll-safety-button" disabled={busy} onClick={() => void refresh()}>重新检查</button>
                <button className="ll-safety-button primary" disabled={busy} onClick={() => void createBackup()}>创建备份</button>
              </div>

              {health ? (
                <>
                  <div className={health.status === 'ok' ? 'll-safety-status' : 'll-safety-status warning'}>
                    <strong>{health.status === 'ok' ? '完整性正常' : '需要处理'}</strong>
                    <span>检查时间：{formatDate(health.checkedAt)}</span>
                  </div>
                  <div className="ll-safety-grid">
                    <article className="ll-safety-metric"><span>SQLite quick_check</span><strong>{health.quickCheck}</strong></article>
                    <article className="ll-safety-metric"><span>外键异常</span><strong>{health.foreignKeyViolations}</strong></article>
                    <article className="ll-safety-metric"><span>数据库 / WAL</span><strong>{formatBytes(health.databaseSizeBytes)} / {formatBytes(health.walSizeBytes)}</strong></article>
                  </div>
                  <div className="ll-safety-status"><span>数据库位置</span><strong>{health.databasePath}</strong></div>
                </>
              ) : <div className="ll-safety-empty">服务未启动，或数据库暂时无法检查。</div>}

              <section className="ll-safety-section">
                <h3>最近备份</h3>
                <div className="ll-safety-list">
                  {backups.length === 0 && <div className="ll-safety-empty">尚未创建可验证备份。</div>}
                  {backups.slice(0, 8).map((backup) => (
                    <article className="ll-safety-backup" key={backup.id}>
                      <div>
                        <strong>{formatDate(backup.createdAt)}</strong>
                        <span>{backup.path}</span>
                        <small>{formatBytes(backup.databaseSizeBytes)} · SHA-256 {backup.databaseSha256.slice(0, 16)}…</small>
                      </div>
                      <span className="ll-safety-badge">{backup.verified ? '已验证' : '未验证'}</span>
                    </article>
                  ))}
                </div>
              </section>
              {message && <div className="ll-safety-status"><span>{message}</span></div>}
            </div>
          </section>
        </div>
      )}
    </>
  );
}
