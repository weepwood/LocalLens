use std::{
    net::{IpAddr, Ipv4Addr, UdpSocket},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
};

use local_lens_core::{AppConfig, LibraryConfig};
use serde::Serialize;
use tauri::{Manager, State};
use tokio::{
    sync::oneshot,
    time::{sleep, Duration},
};

#[derive(Clone)]
struct RuntimeState {
    config_path: PathBuf,
    running: Arc<AtomicBool>,
    shutdown: Arc<Mutex<Option<oneshot::Sender<()>>>>,
}

impl RuntimeState {
    async fn start(&self) -> Result<(), String> {
        if self.running.swap(true, Ordering::SeqCst) {
            return Ok(());
        }
        let config = match AppConfig::load(&self.config_path) {
            Ok(config) => config,
            Err(error) => {
                self.running.store(false, Ordering::SeqCst);
                return Err(error.to_string());
            }
        };
        let (shutdown_tx, shutdown_rx) = oneshot::channel();
        *self.shutdown.lock().map_err(|_| "服务状态锁已损坏")? = Some(shutdown_tx);
        let running = self.running.clone();
        let shutdown = self.shutdown.clone();
        tauri::async_runtime::spawn(async move {
            if let Err(error) = local_lens_server::serve(config, shutdown_rx).await {
                tracing::error!(%error, "内嵌 Rust 服务退出");
            }
            running.store(false, Ordering::SeqCst);
            if let Ok(mut sender) = shutdown.lock() {
                sender.take();
            }
        });
        Ok(())
    }

    fn stop(&self) -> Result<(), String> {
        if let Some(sender) = self
            .shutdown
            .lock()
            .map_err(|_| "服务状态锁已损坏")?
            .take()
        {
            let _ = sender.send(());
        }
        self.running.store(false, Ordering::SeqCst);
        Ok(())
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
fn stop_server(state: State<'_, RuntimeState>) -> Result<(), String> {
    state.stop()
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
async fn save_config(
    state: State<'_, RuntimeState>,
    mut config: AppConfig,
) -> Result<(), String> {
    let runtime = state.inner().clone();
    let base = runtime
        .config_path
        .parent()
        .ok_or_else(|| "配置文件目录无效".to_string())?;
    config.normalize(base).map_err(|error| error.to_string())?;
    runtime.stop()?;
    config
        .save(&runtime.config_path)
        .map_err(|error| error.to_string())?;
    sleep(Duration::from_millis(800)).await;
    runtime.start().await
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
                shutdown: Arc::new(Mutex::new(None)),
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
            stop_server
        ])
        .run(tauri::generate_context!())
        .expect("启动 LocalLens Tauri 应用失败");
}
