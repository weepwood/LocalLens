use std::{collections::HashMap, path::PathBuf};

use axum::{
    Json, Router,
    body::Body,
    extract::{Extension, Path, Query, Request, State},
    http::{HeaderMap, HeaderValue, StatusCode, header},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, post, put},
};
use chrono::Utc;
use local_lens_core::{
    AuthIdentity, HealthResponse, MediaItem, MediaQuery, PlaybackProgress, PlaybackRequest,
    ServerInfo,
};
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::time::{Duration, sleep};
use tower::ServiceExt;
use tower_http::{
    cors::{Any, CorsLayer},
    services::ServeFile,
    trace::TraceLayer,
};

use crate::{VERSION, jobs, pairing::PairingClaim, playback, runtime::AppState, scanner};

pub fn router(state: AppState) -> Router {
    let public = Router::new()
        .route("/api/v1/health", get(health))
        .route("/api/v1/server", get(server_info))
        .route("/api/v1/pairing/claim", post(pairing_claim));

    let protected = Router::new()
        .route("/api/v1/libraries", get(libraries))
        .route("/api/v1/stats", get(stats))
        .route("/api/v1/folders", get(folders))
        .route("/api/v1/media", get(media_list))
        .route("/api/v1/media/{id}", get(media_detail))
        .route(
            "/api/v1/media/{id}/favorite",
            put(favorite_on).delete(favorite_off),
        )
        .route(
            "/api/v1/media/{id}/rating",
            put(rating_set).delete(rating_clear),
        )
        .route("/api/v1/media/{id}/collections", get(media_collections))
        .route(
            "/api/v1/media/{id}/progress",
            get(progress_get).put(progress_put),
        )
        .route("/api/v1/media/{id}/metadata", post(retry_metadata))
        .route("/api/v1/media/{id}/thumbnail", get(thumbnail_file))
        .route("/api/v1/media/{id}/original", get(media_file))
        .route("/api/v1/media/{id}/stream", get(media_file))
        .route(
            "/api/v1/media/{id}/playback-manifest",
            post(playback_manifest),
        )
        .route("/api/v1/media/{id}/subtitle/{name}", get(subtitle_file))
        .route("/api/v1/albums", get(albums).post(album_create))
        .route("/api/v1/albums/{id}", axum::routing::delete(album_delete))
        .route(
            "/api/v1/albums/{id}/items/{media_id}",
            put(album_item_add).delete(album_item_remove),
        )
        .route("/api/v1/tags", get(tags).post(tag_create))
        .route("/api/v1/tags/{id}", axum::routing::delete(tag_delete))
        .route(
            "/api/v1/media/{id}/tags/{tag_id}",
            put(media_tag_add).delete(media_tag_remove),
        )
        .route("/api/v1/scan", get(scan_state).post(scan_start))
        .route("/api/v1/pairing/session", post(pairing_start))
        .route("/api/v1/pairing/session/{id}/qr", get(pairing_qr))
        .route("/api/v1/devices", get(devices))
        .route("/api/v1/devices/{id}", axum::routing::delete(device_revoke))
        .route(
            "/api/v1/transcodes/{media_id}/{profile}/{file}",
            get(transcode_file),
        )
        .route("/api/v1/transcodes/diagnostics", get(transcode_diagnostics))
        .route("/api/v1/transcodes/retry", post(transcode_retry))
        .route_layer(middleware::from_fn_with_state(state.clone(), authorize));

    Router::new()
        .merge(public)
        .merge(protected)
        .with_state(state)
        .layer(
            CorsLayer::new()
                .allow_origin(Any)
                .allow_headers(Any)
                .allow_methods(Any)
                .expose_headers([
                    header::ACCEPT_RANGES,
                    header::CONTENT_LENGTH,
                    header::CONTENT_RANGE,
                    header::RETRY_AFTER,
                ]),
        )
        .layer(TraceLayer::new_for_http())
}

async fn authorize(State(state): State<AppState>, mut request: Request, next: Next) -> Response {
    let token = request
        .headers()
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .map(str::trim)
        .unwrap_or_default();
    match state.store.authenticate_token(token, &state.config).await {
        Ok(identity) => {
            request.extensions_mut().insert(identity);
            next.run(request).await
        }
        Err(_) => ApiError::unauthorized().into_response(),
    }
}

async fn health() -> Json<HealthResponse> {
    Json(HealthResponse {
        status: "ok",
        timestamp: Utc::now(),
    })
}

async fn server_info(State(state): State<AppState>) -> Json<ServerInfo> {
    Json(ServerInfo {
        name: state.config.server_name.clone(),
        version: VERSION.into(),
        api_version: "v1".into(),
        capabilities: vec![
            "timeline",
            "folders",
            "favorites",
            "ratings",
            "albums",
            "tags",
            "playback",
            "pairing",
            "scan",
            "watch",
            "metadata",
            "thumbnails",
            "hls",
            "rust-backend",
        ],
    })
}

async fn libraries(State(state): State<AppState>) -> Result<Json<Value>, ApiError> {
    Ok(Json(json!({ "items": state.store.libraries().await? })))
}

async fn stats(State(state): State<AppState>) -> Result<Json<Value>, ApiError> {
    Ok(Json(serde_json::to_value(state.store.stats().await?)?))
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct FolderQuery {
    library_id: String,
    #[serde(default)]
    parent: String,
}

async fn folders(
    State(state): State<AppState>,
    Query(query): Query<FolderQuery>,
) -> Result<Json<Value>, ApiError> {
    if query.library_id.trim().is_empty() {
        return Err(ApiError::bad_request("libraryId is required"));
    }
    let parent = query.parent.trim_matches('/');
    Ok(Json(json!({
        "items": state.store.folders(query.library_id.trim(), parent).await?
    })))
}

async fn media_list(
    State(state): State<AppState>,
    Query(query): Query<MediaQuery>,
) -> Result<Json<Value>, ApiError> {
    Ok(Json(serde_json::to_value(
        state.store.media_page(&query).await?,
    )?))
}

async fn media_detail(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<MediaItem>, ApiError> {
    media_by_id(&state, &id).await.map(Json)
}

async fn favorite_on(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<MediaItem>, ApiError> {
    update_favorite(&state, &id, true).await
}

async fn favorite_off(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<MediaItem>, ApiError> {
    update_favorite(&state, &id, false).await
}

async fn update_favorite(
    state: &AppState,
    id: &str,
    favorite: bool,
) -> Result<Json<MediaItem>, ApiError> {
    state
        .store
        .set_favorite(id, favorite)
        .await?
        .map(Json)
        .ok_or_else(ApiError::not_found)
}

#[derive(Debug, Deserialize)]
struct RatingBody {
    rating: i64,
}

async fn rating_set(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(body): Json<RatingBody>,
) -> Result<Json<MediaItem>, ApiError> {
    update_rating(&state, &id, body.rating).await
}

async fn rating_clear(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<MediaItem>, ApiError> {
    update_rating(&state, &id, 0).await
}

async fn update_rating(
    state: &AppState,
    id: &str,
    rating: i64,
) -> Result<Json<MediaItem>, ApiError> {
    state
        .store
        .set_rating(id, rating)
        .await
        .map_err(ApiError::bad_request_error)?
        .map(Json)
        .ok_or_else(ApiError::not_found)
}

async fn media_collections(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let (album_ids, tag_ids) = state.store.media_collections(&id).await?;
    Ok(Json(json!({ "albumIds": album_ids, "tagIds": tag_ids })))
}

async fn progress_get(
    State(state): State<AppState>,
    Extension(identity): Extension<AuthIdentity>,
    Path(id): Path<String>,
) -> Result<Json<PlaybackProgress>, ApiError> {
    Ok(Json(
        state
            .store
            .playback_progress(identity.playback_profile(), &id)
            .await?,
    ))
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProgressBody {
    position_ms: i64,
    duration_ms: i64,
    #[serde(default)]
    completed: bool,
}

async fn progress_put(
    State(state): State<AppState>,
    Extension(identity): Extension<AuthIdentity>,
    Path(id): Path<String>,
    Json(body): Json<ProgressBody>,
) -> Result<Json<PlaybackProgress>, ApiError> {
    let progress = PlaybackProgress {
        device_id: identity.playback_profile().into(),
        media_id: id,
        position_ms: body.position_ms,
        duration_ms: body.duration_ms,
        completed: body.completed,
        updated_at: None,
    };
    Ok(Json(state.store.save_playback_progress(progress).await?))
}

async fn retry_metadata(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    let media = media_by_id(&state, &id).await?;
    state
        .store
        .enqueue_metadata(&media.id, &media.modified_at)
        .await?;
    state.runtime.metadata_notify.notify_one();
    Ok((StatusCode::ACCEPTED, Json(json!({ "status": "queued" }))))
}

async fn thumbnail_file(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    request: Request<Body>,
) -> Result<Response, ApiError> {
    let media = media_by_id(&state, &id).await?;
    let width = params
        .get("width")
        .and_then(|value| value.parse::<i64>().ok())
        .unwrap_or(480)
        .clamp(64, 1920);
    let path = jobs::thumbnail_path(&state, &media, width);
    if !path.is_file() {
        state
            .store
            .enqueue_thumbnail(&media.id, width, &media.modified_at)
            .await?;
        state.runtime.thumbnail_notify.notify_one();
        for _ in 0..45 {
            if path.is_file() {
                break;
            }
            sleep(Duration::from_millis(180)).await;
        }
    }
    if !path.is_file() {
        let mut response =
            (StatusCode::ACCEPTED, Json(json!({ "status": "queued" }))).into_response();
        response
            .headers_mut()
            .insert(header::RETRY_AFTER, HeaderValue::from_static("3"));
        return Ok(response);
    }
    serve_path(path, request).await
}

async fn media_file(
    State(state): State<AppState>,
    Path(id): Path<String>,
    request: Request<Body>,
) -> Result<Response, ApiError> {
    let media = media_by_id(&state, &id).await?;
    let path = state
        .media_path(&media)
        .ok_or_else(|| ApiError::forbidden("媒体路径不安全"))?;
    if !path.is_file() {
        return Err(ApiError::gone("原始文件当前不可用"));
    }
    serve_path(path, request).await
}

async fn playback_manifest(
    State(state): State<AppState>,
    Path(id): Path<String>,
    request: Option<Json<PlaybackRequest>>,
) -> Result<(StatusCode, Json<local_lens_core::PlaybackManifest>), ApiError> {
    let media = media_by_id(&state, &id).await?;
    if media.media_type != "video" {
        return Err(ApiError::bad_request("media is not a video"));
    }
    let request = request.map(|Json(value)| value).unwrap_or_default();
    let (status, manifest) = playback::playback_manifest(&state, &media, request).await?;
    Ok((status, Json(manifest)))
}

async fn subtitle_file(
    State(state): State<AppState>,
    Path((id, name)): Path<(String, String)>,
    request: Request<Body>,
) -> Result<Response, ApiError> {
    let media = media_by_id(&state, &id).await?;
    let path = playback::subtitle_file(&state, &media, &name).ok_or_else(ApiError::not_found)?;
    serve_path(path, request).await
}

#[derive(Debug, Deserialize)]
struct AlbumBody {
    name: String,
    #[serde(default)]
    description: String,
}

async fn albums(State(state): State<AppState>) -> Result<Json<Value>, ApiError> {
    Ok(Json(json!({ "items": state.store.albums().await? })))
}

async fn album_create(
    State(state): State<AppState>,
    Json(body): Json<AlbumBody>,
) -> Result<(StatusCode, Json<local_lens_core::Album>), ApiError> {
    let album = state
        .store
        .create_album(&body.name, &body.description)
        .await
        .map_err(ApiError::bad_request_error)?;
    Ok((StatusCode::CREATED, Json(album)))
}

async fn album_delete(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiError> {
    if state.store.delete_album(&id).await? {
        Ok(StatusCode::NO_CONTENT)
    } else {
        Err(ApiError::not_found())
    }
}

async fn album_item_add(
    State(state): State<AppState>,
    Path((id, media_id)): Path<(String, String)>,
) -> Result<StatusCode, ApiError> {
    state.store.set_album_item(&id, &media_id, true).await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn album_item_remove(
    State(state): State<AppState>,
    Path((id, media_id)): Path<(String, String)>,
) -> Result<StatusCode, ApiError> {
    state.store.set_album_item(&id, &media_id, false).await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Debug, Deserialize)]
struct TagBody {
    name: String,
    #[serde(default)]
    color: String,
}

async fn tags(State(state): State<AppState>) -> Result<Json<Value>, ApiError> {
    Ok(Json(json!({ "items": state.store.tags().await? })))
}

async fn tag_create(
    State(state): State<AppState>,
    Json(body): Json<TagBody>,
) -> Result<(StatusCode, Json<local_lens_core::Tag>), ApiError> {
    let tag = state
        .store
        .create_tag(&body.name, &body.color)
        .await
        .map_err(ApiError::bad_request_error)?;
    Ok((StatusCode::CREATED, Json(tag)))
}

async fn tag_delete(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiError> {
    if state.store.delete_tag(&id).await? {
        Ok(StatusCode::NO_CONTENT)
    } else {
        Err(ApiError::not_found())
    }
}

async fn media_tag_add(
    State(state): State<AppState>,
    Path((id, tag_id)): Path<(String, String)>,
) -> Result<StatusCode, ApiError> {
    state.store.set_media_tag(&id, &tag_id, true).await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn media_tag_remove(
    State(state): State<AppState>,
    Path((id, tag_id)): Path<(String, String)>,
) -> Result<StatusCode, ApiError> {
    state.store.set_media_tag(&id, &tag_id, false).await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn scan_start(
    State(state): State<AppState>,
    Extension(identity): Extension<AuthIdentity>,
) -> Result<Json<local_lens_core::ScanStatus>, ApiError> {
    require_admin(&identity)?;
    if !scanner::start_scan(state.clone()).await {
        return Err(ApiError::conflict("scan already running"));
    }
    Ok(Json(scanner::scan_status(&state).await))
}

async fn scan_state(State(state): State<AppState>) -> Json<local_lens_core::ScanStatus> {
    Json(scanner::scan_status(&state).await)
}

async fn pairing_start(
    State(state): State<AppState>,
    Extension(identity): Extension<AuthIdentity>,
    headers: HeaderMap,
) -> Result<(StatusCode, Json<crate::pairing::PairingSessionResponse>), ApiError> {
    require_admin(&identity)?;
    let base_url = request_base_url(&state, &headers);
    let session = state.runtime.pairing.create(&state, &base_url).await?;
    Ok((StatusCode::CREATED, Json(session)))
}

async fn pairing_qr(
    State(state): State<AppState>,
    Extension(identity): Extension<AuthIdentity>,
    Path(id): Path<String>,
) -> Result<Response, ApiError> {
    require_admin(&identity)?;
    let png = state
        .runtime
        .pairing
        .qr_png(&id)
        .await
        .map_err(|_| ApiError::not_found())?;
    let mut response = (StatusCode::OK, png).into_response();
    response
        .headers_mut()
        .insert(header::CONTENT_TYPE, HeaderValue::from_static("image/png"));
    response
        .headers_mut()
        .insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    Ok(response)
}

async fn pairing_claim(
    State(state): State<AppState>,
    Json(claim): Json<PairingClaim>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    let (device, token) = state
        .runtime
        .pairing
        .claim(&state, claim)
        .await
        .map_err(ApiError::unauthorized_error)?;
    Ok((
        StatusCode::CREATED,
        Json(json!({ "device": device, "token": token })),
    ))
}

async fn devices(
    State(state): State<AppState>,
    Extension(identity): Extension<AuthIdentity>,
) -> Result<Json<Value>, ApiError> {
    require_admin(&identity)?;
    Ok(Json(json!({ "items": state.store.devices().await? })))
}

async fn device_revoke(
    State(state): State<AppState>,
    Extension(identity): Extension<AuthIdentity>,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiError> {
    require_admin(&identity)?;
    if state.store.revoke_device(&id).await? {
        Ok(StatusCode::NO_CONTENT)
    } else {
        Err(ApiError::not_found())
    }
}

async fn transcode_file(
    State(state): State<AppState>,
    Path((media_id, profile, file)): Path<(String, String, String)>,
    request: Request<Body>,
) -> Result<Response, ApiError> {
    let path = playback::transcode_file(&state, &media_id, &profile, &file)
        .ok_or_else(ApiError::not_found)?;
    serve_path(path, request).await
}

async fn transcode_diagnostics(State(state): State<AppState>) -> Result<Json<Value>, ApiError> {
    Ok(Json(playback::diagnostics(&state).await?))
}

async fn transcode_retry(
    State(state): State<AppState>,
    Extension(identity): Extension<AuthIdentity>,
) -> Result<Json<Value>, ApiError> {
    require_admin(&identity)?;
    Ok(Json(
        json!({ "retried": playback::retry_failed(&state).await? }),
    ))
}

async fn media_by_id(state: &AppState, id: &str) -> Result<MediaItem, ApiError> {
    state
        .store
        .media_by_id(id)
        .await?
        .ok_or_else(ApiError::not_found)
}

async fn serve_path(path: PathBuf, request: Request<Body>) -> Result<Response, ApiError> {
    ServeFile::new(path)
        .oneshot(request)
        .await
        .map(IntoResponse::into_response)
        .map_err(|error| ApiError::internal(error.to_string()))
}

fn request_base_url(state: &AppState, headers: &HeaderMap) -> String {
    if !state.config.public_url.trim().is_empty() {
        return state.config.public_url.trim_end_matches('/').into();
    }
    let scheme = headers
        .get("x-forwarded-proto")
        .and_then(|value| value.to_str().ok())
        .filter(|value| !value.trim().is_empty())
        .unwrap_or("http");
    let host = headers
        .get(header::HOST)
        .and_then(|value| value.to_str().ok())
        .unwrap_or("127.0.0.1:9527");
    format!("{scheme}://{host}")
}

fn require_admin(identity: &AuthIdentity) -> Result<(), ApiError> {
    if identity.admin {
        Ok(())
    } else {
        Err(ApiError::forbidden("administrator token required"))
    }
}

#[derive(Debug)]
pub struct ApiError {
    status: StatusCode,
    message: String,
}

impl ApiError {
    fn new(status: StatusCode, message: impl Into<String>) -> Self {
        Self {
            status,
            message: message.into(),
        }
    }

    fn bad_request(message: impl Into<String>) -> Self {
        Self::new(StatusCode::BAD_REQUEST, message)
    }

    fn bad_request_error(error: anyhow::Error) -> Self {
        Self::bad_request(error.to_string())
    }

    fn unauthorized() -> Self {
        Self::new(StatusCode::UNAUTHORIZED, "unauthorized")
    }

    fn unauthorized_error(error: anyhow::Error) -> Self {
        Self::new(StatusCode::UNAUTHORIZED, error.to_string())
    }

    fn forbidden(message: impl Into<String>) -> Self {
        Self::new(StatusCode::FORBIDDEN, message)
    }

    fn not_found() -> Self {
        Self::new(StatusCode::NOT_FOUND, "not found")
    }

    fn conflict(message: impl Into<String>) -> Self {
        Self::new(StatusCode::CONFLICT, message)
    }

    fn gone(message: impl Into<String>) -> Self {
        Self::new(StatusCode::GONE, message)
    }

    fn internal(message: impl Into<String>) -> Self {
        Self::new(StatusCode::INTERNAL_SERVER_ERROR, message)
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.status, Json(json!({ "error": self.message }))).into_response()
    }
}

impl From<anyhow::Error> for ApiError {
    fn from(error: anyhow::Error) -> Self {
        let message = error.to_string();
        if message.to_ascii_lowercase().contains("constraint")
            || message.to_ascii_lowercase().contains("unique")
        {
            Self::conflict(message)
        } else {
            Self::internal(message)
        }
    }
}

impl From<sqlx::Error> for ApiError {
    fn from(error: sqlx::Error) -> Self {
        let message = error.to_string();
        if message.to_ascii_lowercase().contains("constraint")
            || message.to_ascii_lowercase().contains("unique")
        {
            Self::conflict(message)
        } else {
            Self::internal(message)
        }
    }
}

impl From<serde_json::Error> for ApiError {
    fn from(error: serde_json::Error) -> Self {
        Self::internal(error.to_string())
    }
}
