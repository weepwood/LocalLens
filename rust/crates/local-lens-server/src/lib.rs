mod api;
mod jobs;
mod metadata;
mod pairing;
mod playback;
mod runtime;
mod scanner;

use anyhow::{Context, Result};
use local_lens_core::AppConfig;
use tokio::{net::TcpListener, sync::oneshot};

pub use api::router;
pub use jobs::generate_thumbnail;
pub use pairing::PairingSessionResponse;
pub use runtime::AppState;
pub use scanner::start_scan;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

pub async fn serve(config: AppConfig, shutdown: oneshot::Receiver<()>) -> Result<()> {
    let address = config.listen_address.clone();
    let state = AppState::new(config).await?;
    let listener = TcpListener::bind(&address)
        .await
        .with_context(|| format!("无法监听 {address}"))?;
    state.start_background().await?;
    serve_on_listener(state, listener, shutdown).await
}

pub async fn serve_on_listener(
    state: AppState,
    listener: TcpListener,
    shutdown: oneshot::Receiver<()>,
) -> Result<()> {
    let address = listener
        .local_addr()
        .map(|value| value.to_string())
        .unwrap_or_else(|_| state.config.listen_address.clone());
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
