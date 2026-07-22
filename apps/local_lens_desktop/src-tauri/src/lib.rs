use std::{
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
};

use local_lens_core::{AppConfig, LibraryConfig};
use serde::Serialize;
use tauri::{Manager, State};
use tokio::sync::oneshot;

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

fn ensure_default_config(config_path: &PathBuf, data_dir: PathBuf) -> anyhow::Result<()> {
    if config_path.is_file() {
        return Ok(());
    }
    let config = AppConfig {
        listen_address: "0.0.0.0:9527".into(),
        public_url: "http://127.0.0.1:9527".into(),
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

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let _ = tracing_subscriber::fmt()
        .with_env_filter("info,tower_http=info")
        .try_init();

    tauri::Builder::default()
        .setup(|app| {
            let app_data = app.path().app_data_dir()?;
            std::fs::create_dir_all(&app_data)?;
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
            start_server,
            stop_server
        ])
        .run(tauri::generate_context!())
        .expect("启动 LocalLens Tauri 应用失败");
}
