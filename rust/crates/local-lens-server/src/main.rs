use std::path::PathBuf;

use anyhow::Result;
use local_lens_core::AppConfig;
use tokio::sync::oneshot;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info,tower_http=info")))
        .init();

    let config_path = std::env::args()
        .skip_while(|arg| arg != "--config" && arg != "-config")
        .nth(1)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("config.json"));
    let config = AppConfig::load(config_path)?;
    let (shutdown_tx, shutdown_rx) = oneshot::channel();
    tokio::spawn(async move {
        let _ = tokio::signal::ctrl_c().await;
        let _ = shutdown_tx.send(());
    });
    local_lens_server::serve(config, shutdown_rx).await
}
