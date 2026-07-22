mod api;
mod jobs;
mod metadata;
mod pairing;
mod playback;
mod runtime;
mod scanner;

use anyhow::{Context, Result};
use local_lens_core::AppConfig;
use tokio::sync::oneshot;

pub use api::router;
pub use runtime::AppState;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

pub async fn serve(config: AppConfig, shutdown: oneshot::Receiver<()>) -> Result<()> {
    let address = config.listen_address.clone();
    let state = AppState::new(config).await?;
    state.start_background().await?;
    let listener = tokio::net::TcpListener::bind(&address)
        .await
        .with_context(|| format!("无法监听 {address}"))?;
    tracing::info!(%address, "LocalLens Rust 服务已启动");
    let result = axum::serve(listener, router(state.clone()))
        .with_graceful_shutdown(async move {
            let _ = shutdown.await;
        })
        .await;
    state.runtime.stop().await;
    result?;
    Ok(())
}
