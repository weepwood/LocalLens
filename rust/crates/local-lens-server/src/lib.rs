use std::{collections::HashMap, path::{Component, PathBuf}, sync::Arc};

use anyhow::{Context, Result};
use axum::{
    body::Body,
    extract::{Path, Query, Request, State},
    http::{header, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{delete, get, put},
    Json, Router,
};
use chrono::Utc;
use local_lens_core::{AppConfig, HealthResponse, MediaItem, MediaQuery, ServerInfo, Store};
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use sqlx::Row;
use tokio::sync::oneshot;
use tower::ServiceExt;
use tower_http::{cors::{Any, CorsLayer}, services::ServeFile, trace::TraceLayer};

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Clone)]
pub struct AppState {
    config: Arc<AppConfig>,
    store: Store,
    libraries: Arc<HashMap<String, PathBuf>>,
}

impl AppState {
    pub async fn new(config: AppConfig) -> Result<Self> {
        let store = Store::open(&config.data_dir).await?;
        store.sync_libraries(&config.libraries).await?;
        let libraries = config.libraries.iter()
            .map(|item| (item.id.clone(), item.path.clone()))
            .collect();
        Ok(Self {
            config: Arc::new(config),
            store,
            libraries: Arc::new(libraries),
        })
    }

    async fn token_is_valid(&self, token: &str) -> bool {
        if token == self.config.api_token {
            return true;
        }
        let token_hash = format!("{:x}", Sha256::digest(token.as_bytes()));
        sqlx::query("SELECT 1 FROM devices WHERE token_hash=? AND revoked_at IS NULL LIMIT 1")
            .bind(token_hash)
            .fetch_optional(self.store.pool())
            .await
            .ok()
            .flatten()
            .is_some()
    }

    fn media_path(&self, item: &MediaItem) -> Option<PathBuf> {
        let relative = PathBuf::from(&item.relative_path);
        if relative.components().any(|part| matches!(part, Component::ParentDir | Component::RootDir | Component::Prefix(_))) {
            return None;
        }
        self.libraries.get(&item.library_id).map(|root| root.join(relative))
    }
}

pub fn router(state: AppState) -> Router {
    let public = Router::new()
        .route("/api/v1/health", get(health))
        .route("/api/v1/server", get(server_info));

    let protected = Router::new()
        .route("/api/v1/libraries", get(libraries))
        .route("/api/v1/stats", get(stats))
        .route("/api/v1/media", get(media_list))
        .route("/api/v1/media/{id}", get(media_detail))
        .route("/api/v1/media/{id}/favorite", put(favorite_on).delete(favorite_off))
        .route("/api/v1/media/{id}/rating", put(rating_set).delete(rating_clear))
        .route("/api/v1/media/{id}/original", get(media_file))
        .route("/api/v1/media/{id}/stream", get(media_file))
        .route("/api/v1/media/{id}/thumbnail", get(thumbnail_file))
        .route_layer(middleware::from_fn_with_state(state.clone(), authorize));

    Router::new()
        .merge(public)
        .merge(protected)
        .with_state(state)
        .layer(CorsLayer::new().allow_origin(Any).allow_headers(Any).allow_methods(Any))
        .layer(TraceLayer::new_for_http())
}

pub async fn serve(config: AppConfig, shutdown: oneshot::Receiver<()>) -> Result<()> {
    let address = config.listen_address.clone();
    let state = AppState::new(config).await?;
    let listener = tokio::net::TcpListener::bind(&address)
        .await
        .with_context(|| format!("无法监听 {address}"))?;
    tracing::info!(%address, "LocalLens Rust 服务已启动");
    axum::serve(listener, router(state))
        .with_graceful_shutdown(async move { let _ = shutdown.await; })
        .await?;
    Ok(())
}

async fn authorize(State(state): State<AppState>, request: Request, next: Next) -> Response {
    let token = request.headers()
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .unwrap_or_default();
    if !state.token_is_valid(token).await {
        return ApiError::unauthorized().into_response();
    }
    next.run(request).await
}

async fn health() -> Json<HealthResponse> {
    Json(HealthResponse { status: "ok", timestamp: Utc::now() })
}

async fn server_info(State(state): State<AppState>) -> Json<ServerInfo> {
    Json(ServerInfo {
        name: state.config.server_name.clone(),
        version: VERSION.into(),
        api_version: "v1".into(),
        capabilities: vec!["timeline", "folders", "favorites", "ratings", "albums", "tags", "playback", "pairing", "rust-backend"],
    })
}

async fn libraries(State(state): State<AppState>) -> Result<Json<Value>, ApiError> {
    Ok(Json(json!({ "items": state.store.libraries().await? })))
}

async fn stats(State(state): State<AppState>) -> Result<Json<Value>, ApiError> {
    Ok(Json(serde_json::to_value(state.store.stats().await?)?))
}

async fn media_list(State(state): State<AppState>, Query(query): Query<MediaQuery>) -> Result<Json<Value>, ApiError> {
    Ok(Json(serde_json::to_value(state.store.media_page(&query).await?)?))
}

async fn media_detail(State(state): State<AppState>, Path(id): Path<String>) -> Result<Json<MediaItem>, ApiError> {
    state.store.media_by_id(&id).await?
        .map(Json)
        .ok_or_else(ApiError::not_found)
}

async fn favorite_on(State(state): State<AppState>, Path(id): Path<String>) -> Result<Json<MediaItem>, ApiError> {
    update_favorite(state, id, true).await
}

async fn favorite_off(State(state): State<AppState>, Path(id): Path<String>) -> Result<Json<MediaItem>, ApiError> {
    update_favorite(state, id, false).await
}

async fn update_favorite(state: AppState, id: String, favorite: bool) -> Result<Json<MediaItem>, ApiError> {
    state.store.set_favorite(&id, favorite).await?
        .map(Json)
        .ok_or_else(ApiError::not_found)
}

#[derive(Deserialize)]
struct RatingBody { rating: i64 }

async fn rating_set(State(state): State<AppState>, Path(id): Path<String>, Json(body): Json<RatingBody>) -> Result<Json<MediaItem>, ApiError> {
    update_rating(state, id, body.rating).await
}

async fn rating_clear(State(state): State<AppState>, Path(id): Path<String>) -> Result<Json<MediaItem>, ApiError> {
    update_rating(state, id, 0).await
}

async fn update_rating(state: AppState, id: String, rating: i64) -> Result<Json<MediaItem>, ApiError> {
    state.store.set_rating(&id, rating).await?
        .map(Json)
        .ok_or_else(ApiError::not_found)
}

async fn media_file(State(state): State<AppState>, Path(id): Path<String>, request: Request<Body>) -> Result<Response, ApiError> {
    let item = state.store.media_by_id(&id).await?.ok_or_else(ApiError::not_found)?;
    let path = state.media_path(&item).ok_or_else(ApiError::not_found)?;
    if !path.is_file() {
        return Err(ApiError::gone("原始文件当前不可用"));
    }
    ServeFile::new(path).oneshot(request).await
        .map(IntoResponse::into_response)
        .map_err(|error| ApiError::internal(error.to_string()))
}

async fn thumbnail_file(State(state): State<AppState>, Path(id): Path<String>, Query(params): Query<HashMap<String, String>>, request: Request<Body>) -> Result<Response, ApiError> {
    let item = state.store.media_by_id(&id).await?.ok_or_else(ApiError::not_found)?;
    let width = params.get("width").and_then(|value| value.parse::<u32>().ok()).unwrap_or(480).clamp(64, 2048);
    let cached = state.config.data_dir.join("thumbnails").join(format!("{id}-{width}.jpg"));
    let path = if cached.is_file() {
        cached
    } else if item.media_type == "image" {
        state.media_path(&item).ok_or_else(ApiError::not_found)?
    } else {
        return Ok((StatusCode::ACCEPTED, Json(json!({ "status": "queued" }))).into_response());
    };
    ServeFile::new(path).oneshot(request).await
        .map(IntoResponse::into_response)
        .map_err(|error| ApiError::internal(error.to_string()))
}

#[derive(Debug)]
pub struct ApiError {
    status: StatusCode,
    message: String,
}

impl ApiError {
    fn unauthorized() -> Self { Self { status: StatusCode::UNAUTHORIZED, message: "Token 无效或已撤销".into() } }
    fn not_found() -> Self { Self { status: StatusCode::NOT_FOUND, message: "资源不存在".into() } }
    fn gone(message: impl Into<String>) -> Self { Self { status: StatusCode::GONE, message: message.into() } }
    fn internal(message: impl Into<String>) -> Self { Self { status: StatusCode::INTERNAL_SERVER_ERROR, message: message.into() } }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.status, Json(json!({ "error": self.message }))).into_response()
    }
}

impl From<anyhow::Error> for ApiError {
    fn from(value: anyhow::Error) -> Self { Self::internal(value.to_string()) }
}
impl From<sqlx::Error> for ApiError {
    fn from(value: sqlx::Error) -> Self { Self::internal(value.to_string()) }
}
impl From<serde_json::Error> for ApiError {
    fn from(value: serde_json::Error) -> Self { Self::internal(value.to_string()) }
}
