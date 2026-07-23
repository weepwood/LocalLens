use std::path::PathBuf;

use anyhow::{Context, Result};
use axum::{
    body::Body,
    http::{header, Request, StatusCode},
    Router,
};
use http_body_util::BodyExt;
use local_lens_core::AppConfig;
use local_lens_server::{router, AppState};
use serde_json::{json, Value};
use tower::ServiceExt;

const ADMIN_TOKEN: &str = "pairing-administrator-token-123456";

#[tokio::test]
async fn pairing_qr_and_device_revoke_work_end_to_end() -> Result<()> {
    let root = tempfile::tempdir()?;
    let config = AppConfig {
        listen_address: "127.0.0.1:0".into(),
        public_url: "http://192.168.1.20:9527".into(),
        server_name: "LocalLens Pairing Test".into(),
        data_dir: root.path().join("data"),
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
        libraries: Vec::new(),
    };
    let state = AppState::new(config).await?;
    state.start_background().await?;
    let app = router(state.clone());

    let session = call_json(
        &app,
        "POST",
        "/api/v1/pairing/session",
        Some(ADMIN_TOKEN),
        None,
    )
    .await?;
    assert_eq!(session.0, StatusCode::CREATED);
    let session_id = session.1["id"].as_str().context("pairing id missing")?;
    let payload: Value = serde_json::from_str(
        session.1["payload"]
            .as_str()
            .context("pairing payload missing")?,
    )?;
    assert_eq!(payload["baseUrl"], "http://192.168.1.20:9527");

    let unauthorized_qr = call_raw(
        &app,
        "GET",
        &format!("/api/v1/pairing/session/{session_id}/qr"),
        None,
        None,
    )
    .await?;
    assert_eq!(unauthorized_qr.status(), StatusCode::UNAUTHORIZED);

    let qr = call_raw(
        &app,
        "GET",
        &format!("/api/v1/pairing/session/{session_id}/qr"),
        Some(ADMIN_TOKEN),
        None,
    )
    .await?;
    assert_eq!(qr.status(), StatusCode::OK);
    assert_eq!(
        qr.headers().get(header::CONTENT_TYPE),
        Some(&header::HeaderValue::from_static("image/png")),
    );
    let qr_bytes = qr.into_body().collect().await?.to_bytes();
    assert!(qr_bytes.starts_with(b"\x89PNG\r\n\x1a\n"));

    let claim = call_json(
        &app,
        "POST",
        "/api/v1/pairing/claim",
        None,
        Some(json!({
            "pairingId": payload["pairingId"],
            "secret": payload["secret"],
            "deviceName": "测试 Android 手机",
            "platform": "android"
        })),
    )
    .await?;
    assert_eq!(claim.0, StatusCode::CREATED);
    let device_id = claim.1["device"]["id"]
        .as_str()
        .context("device id missing")?;
    let device_token = claim.1["token"]
        .as_str()
        .context("device token missing")?;

    let devices = call_json(&app, "GET", "/api/v1/devices", Some(ADMIN_TOKEN), None).await?;
    assert_eq!(devices.0, StatusCode::OK);
    assert_eq!(devices.1["items"].as_array().map(Vec::len), Some(1));
    assert_eq!(devices.1["items"][0]["id"], device_id);

    let device_access = call_json(&app, "GET", "/api/v1/media", Some(device_token), None).await?;
    assert_eq!(device_access.0, StatusCode::OK);

    let revoke = call_raw(
        &app,
        "DELETE",
        &format!("/api/v1/devices/{device_id}"),
        Some(ADMIN_TOKEN),
        None,
    )
    .await?;
    assert_eq!(revoke.status(), StatusCode::NO_CONTENT);

    let revoked_access = call_json(&app, "GET", "/api/v1/media", Some(device_token), None).await?;
    assert_eq!(revoked_access.0, StatusCode::UNAUTHORIZED);

    let second_revoke = call_raw(
        &app,
        "DELETE",
        &format!("/api/v1/devices/{device_id}"),
        Some(ADMIN_TOKEN),
        None,
    )
    .await?;
    assert_eq!(second_revoke.status(), StatusCode::NOT_FOUND);

    state.runtime.stop().await;
    Ok(())
}

async fn call_json(
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
        serde_json::from_slice(&bytes).unwrap_or_else(|_| {
            Value::String(String::from_utf8_lossy(&bytes).to_string())
        })
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
