use std::{path::PathBuf, time::Duration};

use anyhow::{Context, Result};
use axum::{
    Router,
    body::Body,
    http::{Request, StatusCode, header},
};
use http_body_util::BodyExt;
use image::{Rgb, RgbImage};
use local_lens_core::{AppConfig, LibraryConfig};
use local_lens_server::{AppState, router};
use serde_json::{Value, json};
use tempfile::TempDir;
use tokio::time::sleep;
use tower::ServiceExt;

const ADMIN_TOKEN: &str = "test-administrator-token-123456";

#[tokio::test]
async fn rust_backend_matches_core_go_workflow() -> Result<()> {
    let fixture = Fixture::new().await?;
    let app = router(fixture.state.clone());

    let scan = call(&app, "POST", "/api/v1/scan", Some(ADMIN_TOKEN), None).await?;
    assert_eq!(scan.0, StatusCode::OK);
    wait_for_scan(&fixture.state).await?;

    let media = call(&app, "GET", "/api/v1/media", Some(ADMIN_TOKEN), None).await?;
    assert_eq!(media.0, StatusCode::OK);
    assert_eq!(media.1["total"], 1);
    let media_id = media.1["items"][0]["id"]
        .as_str()
        .context("media id missing")?
        .to_string();

    let favorite = call(
        &app,
        "PUT",
        &format!("/api/v1/media/{media_id}/favorite"),
        Some(ADMIN_TOKEN),
        None,
    )
    .await?;
    assert_eq!(favorite.0, StatusCode::OK);
    assert_eq!(favorite.1["favorite"], true);

    let rating = call(
        &app,
        "PUT",
        &format!("/api/v1/media/{media_id}/rating"),
        Some(ADMIN_TOKEN),
        Some(json!({ "rating": 5 })),
    )
    .await?;
    assert_eq!(rating.0, StatusCode::OK);
    assert_eq!(rating.1["rating"], 5);

    let album = call(
        &app,
        "POST",
        "/api/v1/albums",
        Some(ADMIN_TOKEN),
        Some(json!({ "name": "测试相册", "description": "Rust parity" })),
    )
    .await?;
    assert_eq!(album.0, StatusCode::CREATED);
    let album_id = album.1["id"].as_str().context("album id missing")?;
    let album_item = call(
        &app,
        "PUT",
        &format!("/api/v1/albums/{album_id}/items/{media_id}"),
        Some(ADMIN_TOKEN),
        None,
    )
    .await?;
    assert_eq!(album_item.0, StatusCode::NO_CONTENT);

    let tag = call(
        &app,
        "POST",
        "/api/v1/tags",
        Some(ADMIN_TOKEN),
        Some(json!({ "name": "测试标签", "color": "#336699" })),
    )
    .await?;
    assert_eq!(tag.0, StatusCode::CREATED);
    let tag_id = tag.1["id"].as_str().context("tag id missing")?;
    let tag_item = call(
        &app,
        "PUT",
        &format!("/api/v1/media/{media_id}/tags/{tag_id}"),
        Some(ADMIN_TOKEN),
        None,
    )
    .await?;
    assert_eq!(tag_item.0, StatusCode::NO_CONTENT);

    let collections = call(
        &app,
        "GET",
        &format!("/api/v1/media/{media_id}/collections"),
        Some(ADMIN_TOKEN),
        None,
    )
    .await?;
    assert_eq!(collections.1["albumIds"][0], album_id);
    assert_eq!(collections.1["tagIds"][0], tag_id);

    let progress = call(
        &app,
        "PUT",
        &format!("/api/v1/media/{media_id}/progress"),
        Some(ADMIN_TOKEN),
        Some(json!({
            "positionMs": 1250,
            "durationMs": 5000,
            "completed": false
        })),
    )
    .await?;
    assert_eq!(progress.0, StatusCode::OK);
    assert_eq!(progress.1["positionMs"], 1250);

    let thumbnail = wait_for_thumbnail(&app, &media_id).await?;
    assert_eq!(thumbnail, StatusCode::OK);

    let session = call(
        &app,
        "POST",
        "/api/v1/pairing/session",
        Some(ADMIN_TOKEN),
        None,
    )
    .await?;
    assert_eq!(session.0, StatusCode::CREATED);
    let payload: Value = serde_json::from_str(
        session.1["payload"]
            .as_str()
            .context("pairing payload missing")?,
    )?;
    let pairing_id = payload["pairingId"]
        .as_str()
        .context("pairing id missing")?;
    let secret = payload["secret"].as_str().context("secret missing")?;

    let claim_body = json!({
        "pairingId": pairing_id,
        "secret": secret,
        "deviceName": "Android 测试设备",
        "platform": "android"
    });
    let claim = call(
        &app,
        "POST",
        "/api/v1/pairing/claim",
        None,
        Some(claim_body.clone()),
    )
    .await?;
    assert_eq!(claim.0, StatusCode::CREATED);
    let device_token = claim.1["token"].as_str().context("device token missing")?;

    let device_media = call(&app, "GET", "/api/v1/media", Some(device_token), None).await?;
    assert_eq!(device_media.0, StatusCode::OK);
    assert_eq!(device_media.1["total"], 1);

    let second_claim = call(
        &app,
        "POST",
        "/api/v1/pairing/claim",
        None,
        Some(claim_body),
    )
    .await?;
    assert_eq!(second_claim.0, StatusCode::UNAUTHORIZED);

    fixture.state.runtime.stop().await;
    Ok(())
}

#[tokio::test]
async fn path_traversal_is_rejected() -> Result<()> {
    let fixture = Fixture::new().await?;
    sqlx::query(
        r#"INSERT INTO media_items(
 id,library_id,relative_path,folder_path,file_name,media_type,mime_type,
 size_bytes,modified_at,captured_at,captured_at_source,missing,last_seen_scan,
 metadata_status,metadata_error)
VALUES('unsafe','main','../outside.jpg','','outside.jpg','image','image/jpeg',1,
 '2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','modified',0,'test','done','')"#,
    )
    .execute(fixture.state.store.pool())
    .await?;
    let response = call(
        &router(fixture.state.clone()),
        "GET",
        "/api/v1/media/unsafe/original",
        Some(ADMIN_TOKEN),
        None,
    )
    .await?;
    assert_eq!(response.0, StatusCode::FORBIDDEN);
    fixture.state.runtime.stop().await;
    Ok(())
}

struct Fixture {
    _root: TempDir,
    state: AppState,
}

impl Fixture {
    async fn new() -> Result<Self> {
        let root = tempfile::tempdir()?;
        let library = root.path().join("library");
        let data = root.path().join("data");
        std::fs::create_dir_all(&library)?;
        RgbImage::from_pixel(64, 48, Rgb([32, 96, 160])).save(library.join("sample.png"))?;
        let config = AppConfig {
            listen_address: "127.0.0.1:0".into(),
            public_url: "http://127.0.0.1:9527".into(),
            server_name: "LocalLens Test".into(),
            data_dir: data,
            api_token: ADMIN_TOKEN.into(),
            ffmpeg_path: PathBuf::new(),
            ffprobe_path: PathBuf::new(),
            auto_scan: false,
            watch_files: false,
            thumbnail_workers: 1,
            metadata_workers: 1,
            transcode_workers: 1,
            transcode_cache_gb: 1,
            transcode_hardware: "software".into(),
            pairing_ttl_minutes: 5,
            libraries: vec![LibraryConfig {
                id: "main".into(),
                name: "测试媒体库".into(),
                path: library,
                recursive: true,
                enabled: true,
            }],
        };
        let state = AppState::new(config).await?;
        state.start_background().await?;
        Ok(Self { _root: root, state })
    }
}

async fn wait_for_scan(state: &AppState) -> Result<()> {
    for _ in 0..200 {
        if !state
            .runtime
            .scanning
            .load(std::sync::atomic::Ordering::SeqCst)
        {
            let status = state.runtime.scan_status.read().await.clone();
            if !status.error_message.is_empty() {
                anyhow::bail!(status.error_message);
            }
            return Ok(());
        }
        sleep(Duration::from_millis(25)).await;
    }
    anyhow::bail!("scan timeout")
}

async fn wait_for_thumbnail(app: &Router, media_id: &str) -> Result<StatusCode> {
    for _ in 0..20 {
        let response = call_raw(
            app,
            "GET",
            &format!("/api/v1/media/{media_id}/thumbnail?width=320"),
            Some(ADMIN_TOKEN),
            None,
        )
        .await?;
        if response.status() == StatusCode::OK {
            return Ok(StatusCode::OK);
        }
        sleep(Duration::from_millis(100)).await;
    }
    anyhow::bail!("thumbnail timeout")
}

async fn call(
    app: &Router,
    method: &str,
    uri: &str,
    token: Option<&str>,
    body: Option<Value>,
) -> Result<(StatusCode, Value)> {
    let response = call_raw(app, method, uri, token, body).await?;
    let status = response.status();
    let bytes = response.into_body().collect().await?.to_bytes();
    let value = if bytes.is_empty() {
        Value::Null
    } else {
        serde_json::from_slice(&bytes)
            .unwrap_or_else(|_| Value::String(String::from_utf8_lossy(&bytes).to_string()))
    };
    Ok((status, value))
}

async fn call_raw(
    app: &Router,
    method: &str,
    uri: &str,
    token: Option<&str>,
    body: Option<Value>,
) -> Result<axum::response::Response> {
    let mut builder = Request::builder().method(method).uri(uri);
    if let Some(token) = token {
        builder = builder.header(header::AUTHORIZATION, format!("Bearer {token}"));
    }
    let body = match body {
        Some(value) => {
            builder = builder.header(header::CONTENT_TYPE, "application/json");
            Body::from(serde_json::to_vec(&value)?)
        }
        None => Body::empty(),
    };
    Ok(app.clone().oneshot(builder.body(body)?).await?)
}
