mod desktop_media;

use std::{
    net::{IpAddr, Ipv4Addr, UdpSocket},
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex as StdMutex,
        atomic::{AtomicBool, Ordering},
    },
};

use local_lens_core::{
    AppConfig, Device, LibraryConfig, LibraryInfo, MediaItem, MediaPage, MediaQuery, MediaStats,
    ScanStatus,
};
use local_lens_server::{AppState, PairingSessionResponse};
use serde::Serialize;
use tauri::{Manager, State, ipc::Response as IpcResponse};
use tokio::{
    net::TcpListener,
    sync::{Mutex, RwLock, oneshot},
    time::{Duration, sleep},
};

#[derive(Clone)]
pub(crate) struct RuntimeState {
    config_path: PathBuf,
    running: Arc<AtomicBool>,
    shutdown: Arc<StdMutex<Option<oneshot::Sender<()>>>>,
    lifecycle: Arc<Mutex<()>>,
    app_state: Arc<RwLock<Option<AppState>>>,
}

impl RuntimeState {
    async fn start(&self) -> Result<(), String> {
        let _guard = self.lifecycle.lock().await;
        if self.running.load(Ordering::SeqCst) {
            return Ok(());
        }

        let config = AppConfig::load(&self.config_path).map_err(|error| error.to_string())?;
        let listener = TcpListener::bind(&config.listen_address)
            .await
            .map_err(|error| format!("无法监听 {}：{error}", config.listen_address))?;
        let app_state = AppState::new(config)
            .await
            .map_err(|error| format!("初始化 Rust 服务失败：{error}"))?;
        app_state
            .start_background()
            .await
            .map_err(|error| format!("启动后台任务失败：{error}"))?;

        let (shutdown_tx, shutdown_rx) = oneshot::channel();
        *self.shutdown.lock().map_err(|_| "服务状态锁已损坏")? = Some(shutdown_tx);
        *self.app_state.write().await = Some(app_state.clone());
        self.running.store(true, Ordering::SeqCst);

        let running = self.running.clone();
        let shutdown = self.shutdown.clone();
        let holder = self.app_state.clone();
        tauri::async_runtime::spawn(async move {
            if let Err(error) =
                local_lens_server::serve_on_listener(app_state, listener, shutdown_rx).await
            {
                tracing::error!(%error, "内嵌 Rust 服务退出");
            }
            running.store(false, Ordering::SeqCst);
            holder.write().await.take();
            if let Ok(mut sender) = shutdown.lock() {
                sender.take();
            }
        });
        Ok(())
    }

    async fn stop(&self) -> Result<(), String> {
        let _guard = self.lifecycle.lock().await;
        if !self.running.load(Ordering::SeqCst) {
            self.app_state.write().await.take();
            return Ok(());
        }
        if let Some(sender) = self.shutdown.lock().map_err(|_| "服务状态锁已损坏")?.take() {
            let _ = sender.send(());
        }
        for _ in 0..180 {
            if !self.running.load(Ordering::SeqCst) {
                return Ok(());
            }
            sleep(Duration::from_millis(100)).await;
        }
        if let Some(current) = self.app_state.write().await.take() {
            current.runtime.stop().await;
        }
        self.running.store(false, Ordering::SeqCst);
        Err("等待 Rust 服务停止超时，请重新打开 LocalLens".into())
    }

    pub(crate) async fn current(&self) -> Result<AppState, String> {
        self.app_state
            .read()
            .await
            .clone()
            .ok_or_else(|| "Rust 服务尚未完成启动，请稍后重试".to_string())
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RuntimeStatus {
    running: bool,
    server_name: String,
    listen_address: String,
    public_url: String,
    config_path: String,
    data_dir: String,
    backend: &'static str,
}

#[tauri::command]
async fn start_server(state: State<'_, RuntimeState>) -> Result<(), String> {
    state.start().await
}

#[tauri::command]
async fn stop_server(state: State<'_, RuntimeState>) -> Result<(), String> {
    state.stop().await
}

#[tauri::command]
fn runtime_status(state: State<'_, RuntimeState>) -> Result<RuntimeStatus, String> {
    let config = AppConfig::load(&state.config_path).map_err(|error| error.to_string())?;
    Ok(RuntimeStatus {
        running: state.running.load(Ordering::SeqCst),
        server_name: config.server_name,
        listen_address: config.listen_address,
        public_url: config.public_url,
        config_path: state.config_path.to_string_lossy().to_string(),
        data_dir: config.data_dir.to_string_lossy().to_string(),
        backend: "Rust",
    })
}

#[tauri::command]
fn read_config(state: State<'_, RuntimeState>) -> Result<AppConfig, String> {
    AppConfig::load(&state.config_path).map_err(|error| error.to_string())
}

#[tauri::command]
fn suggest_public_url(state: State<'_, RuntimeState>) -> Result<String, String> {
    let config = AppConfig::load(&state.config_path).map_err(|error| error.to_string())?;
    Ok(detect_public_url(&config.listen_address))
}

#[tauri::command]
async fn save_config(state: State<'_, RuntimeState>, mut config: AppConfig) -> Result<(), String> {
    let runtime = state.inner().clone();
    let base = runtime
        .config_path
        .parent()
        .ok_or_else(|| "配置文件目录无效".to_string())?;
    config.normalize(base).map_err(|error| error.to_string())?;
    runtime.stop().await?;
    config
        .save(&runtime.config_path)
        .map_err(|error| error.to_string())?;
    runtime.start().await
}

#[tauri::command]
async fn desktop_create_pairing(
    state: State<'_, RuntimeState>,
) -> Result<PairingSessionResponse, String> {
    let current = state.current().await?;
    current
        .runtime
        .pairing
        .create(&current, &current.config.public_url)
        .await
        .map_err(|error| error.to_string())
}

#[tauri::command]
async fn desktop_pairing_qr(
    state: State<'_, RuntimeState>,
    session_id: String,
) -> Result<IpcResponse, String> {
    let current = state.current().await?;
    let bytes = current
        .runtime
        .pairing
        .qr_png(&session_id)
        .await
        .map_err(|error| error.to_string())?;
    Ok(IpcResponse::new(bytes))
}

#[tauri::command]
async fn desktop_devices(state: State<'_, RuntimeState>) -> Result<Vec<Device>, String> {
    let current = state.current().await?;
    current
        .store
        .devices()
        .await
        .map_err(|error| error.to_string())
}

#[tauri::command]
async fn desktop_revoke_device(state: State<'_, RuntimeState>, id: String) -> Result<(), String> {
    let current = state.current().await?;
    if current
        .store
        .revoke_device(&id)
        .await
        .map_err(|error| error.to_string())?
    {
        Ok(())
    } else {
        Err("设备不存在或已经撤销".into())
    }
}

#[tauri::command]
async fn desktop_libraries(state: State<'_, RuntimeState>) -> Result<Vec<LibraryInfo>, String> {
    let current = state.current().await?;
    current
        .store
        .libraries()
        .await
        .map_err(|error| error.to_string())
}

#[tauri::command]
async fn desktop_stats(state: State<'_, RuntimeState>) -> Result<MediaStats, String> {
    let current = state.current().await?;
    current
        .store
        .stats()
        .await
        .map_err(|error| error.to_string())
}

#[tauri::command]
async fn desktop_media_page(
    state: State<'_, RuntimeState>,
    query: MediaQuery,
) -> Result<MediaPage, String> {
    let current = state.current().await?;
    current
        .store
        .media_page(&query)
        .await
        .map_err(|error| error.to_string())
}

#[tauri::command]
async fn desktop_set_favorite(
    state: State<'_, RuntimeState>,
    id: String,
    favorite: bool,
) -> Result<MediaItem, String> {
    let current = state.current().await?;
    current
        .store
        .set_favorite(&id, favorite)
        .await
        .map_err(|error| error.to_string())?
        .ok_or_else(|| "媒体不存在".to_string())
}

#[tauri::command]
async fn desktop_set_rating(
    state: State<'_, RuntimeState>,
    id: String,
    rating: i64,
) -> Result<MediaItem, String> {
    let current = state.current().await?;
    current
        .store
        .set_rating(&id, rating)
        .await
        .map_err(|error| error.to_string())?
        .ok_or_else(|| "媒体不存在".to_string())
}

#[tauri::command]
async fn desktop_media_bytes(
    state: State<'_, RuntimeState>,
    id: String,
    thumbnail: bool,
    width: i64,
) -> Result<IpcResponse, String> {
    let current = state.current().await?;
    let media = current
        .store
        .media_by_id(&id)
        .await
        .map_err(|error| error.to_string())?
        .ok_or_else(|| "媒体不存在".to_string())?;
    let path = if thumbnail {
        local_lens_server::generate_thumbnail(&current, &media, width)
            .await
            .map_err(|error| error.to_string())?
    } else {
        current
            .media_path(&media)
            .ok_or_else(|| "媒体路径不安全".to_string())?
    };
    let bytes = tokio::fs::read(&path)
        .await
        .map_err(|error| format!("读取媒体失败：{error}"))?;
    Ok(IpcResponse::new(bytes))
}

#[tauri::command]
async fn desktop_start_scan(state: State<'_, RuntimeState>) -> Result<bool, String> {
    let current = state.current().await?;
    Ok(local_lens_server::start_scan(current).await)
}

#[tauri::command]
async fn desktop_scan_status(state: State<'_, RuntimeState>) -> Result<ScanStatus, String> {
    let current = state.current().await?;
    Ok(current.runtime.scan_status.read().await.clone())
}

fn detect_public_url(listen_address: &str) -> String {
    let port = listen_address
        .rsplit_once(':')
        .and_then(|(_, value)| value.parse::<u16>().ok())
        .unwrap_or(9527);
    let address = detect_lan_ipv4().unwrap_or(Ipv4Addr::LOCALHOST);
    format!("http://{address}:{port}")
}

fn detect_lan_ipv4() -> Option<Ipv4Addr> {
    let socket = UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect("8.8.8.8:80").ok()?;
    match socket.local_addr().ok()?.ip() {
        IpAddr::V4(address) if !address.is_loopback() && !address.is_unspecified() => Some(address),
        _ => None,
    }
}

fn ensure_default_config(config_path: &PathBuf, data_dir: PathBuf) -> anyhow::Result<()> {
    if config_path.is_file() {
        return Ok(());
    }
    let listen_address = "0.0.0.0:9527".to_string();
    let config = AppConfig {
        public_url: detect_public_url(&listen_address),
        listen_address,
        server_name: "LocalLens".into(),
        data_dir,
        api_token: uuid::Uuid::new_v4().simple().to_string(),
        ffmpeg_path: PathBuf::from("runtime/media-tools/ffmpeg.exe"),
        ffprobe_path: PathBuf::from("runtime/media-tools/ffprobe.exe"),
        auto_scan: true,
        watch_files: true,
        thumbnail_workers: 2,
        metadata_workers: 2,
        transcode_workers: 1,
        transcode_cache_gb: 20,
        transcode_hardware: "software".into(),
        pairing_ttl_minutes: 5,
        libraries: Vec::<LibraryConfig>::new(),
    };
    config.save(config_path)
}

fn install_bundled_media_tools(resource_dir: &Path, app_data: &Path) -> anyhow::Result<()> {
    let target_dir = app_data.join("runtime").join("media-tools");
    std::fs::create_dir_all(&target_dir)?;
    for name in ["ffmpeg.exe", "ffprobe.exe", "FFMPEG-LICENSE.txt"] {
        let target = target_dir.join(name);
        if target.is_file() {
            continue;
        }
        let candidates = [
            resource_dir.join("runtime").join("media-tools").join(name),
            resource_dir.join("media-tools").join(name),
            resource_dir.join(name),
        ];
        if let Some(source) = candidates.iter().find(|candidate| candidate.is_file()) {
            std::fs::copy(source, &target)?;
        }
    }
    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let _ = tracing_subscriber::fmt()
        .with_env_filter("info,tower_http=info")
        .try_init();

    tauri::Builder::default()
        .setup(|app| {
            let app_data = app.path().app_data_dir()?;
            let resource_dir = app.path().resource_dir()?;
            std::fs::create_dir_all(&app_data)?;
            install_bundled_media_tools(&resource_dir, &app_data)?;
            let config_path = app_data.join("config.json");
            ensure_default_config(&config_path, app_data.join("data"))?;
            let state = RuntimeState {
                config_path,
                running: Arc::new(AtomicBool::new(false)),
                shutdown: Arc::new(StdMutex::new(None)),
                lifecycle: Arc::new(Mutex::new(())),
                app_state: Arc::new(RwLock::new(None)),
            };
            let startup_state = state.clone();
            app.manage(state);
            tauri::async_runtime::spawn(async move {
                if let Err(error) = startup_state.start().await {
                    tracing::error!(%error, "自动启动 Rust 服务失败");
                }
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            runtime_status,
            read_config,
            suggest_public_url,
            save_config,
            start_server,
            stop_server,
            desktop_create_pairing,
            desktop_pairing_qr,
            desktop_devices,
            desktop_revoke_device,
            desktop_libraries,
            desktop_stats,
            desktop_media_page,
            desktop_set_favorite,
            desktop_set_rating,
            desktop_media_bytes,
            desktop_start_scan,
            desktop_scan_status,
            desktop_media::desktop_folders,
            desktop_media::desktop_albums,
            desktop_media::desktop_create_album,
            desktop_media::desktop_delete_album,
            desktop_media::desktop_tags,
            desktop_media::desktop_create_tag,
            desktop_media::desktop_delete_tag,
            desktop_media::desktop_media_collections,
            desktop_media::desktop_set_album_item,
            desktop_media::desktop_set_media_tag,
            desktop_media::desktop_batch_update,
            desktop_media::desktop_reveal_media
        ])
        .run(tauri::generate_context!())
        .expect("启动 LocalLens Tauri 应用失败");
}
