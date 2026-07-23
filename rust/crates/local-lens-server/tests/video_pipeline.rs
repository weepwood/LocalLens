use std::{path::PathBuf, process::Command, time::Duration};

use anyhow::{Context, Result};
use axum::{
    body::Body,
    http::{header, Request, StatusCode},
    Router,
};
use http_body_util::BodyExt;
use local_lens_core::{AppConfig, LibraryConfig};
use local_lens_server::{router, AppState};
use serde_json::{json, Value};
use tokio::time::sleep;
use tower::ServiceExt;

const ADMIN_TOKEN: &str = "video-administrator-token-123456";

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn real_video_metadata_range_subtitle_and_hls_pipeline() -> Result<()> {
    let ffmpeg = executable("FFMPEG_PATH", "/usr/bin/ffmpeg");
    let ffprobe = executable("FFPROBE_PATH", "/usr/bin/ffprobe");
    if !ffmpeg.is_file() || !ffprobe.is_file() {
        eprintln!("skip video pipeline: ffmpeg/ffprobe unavailable");
        return Ok(());
    }

    let root = tempfile::tempdir()?;
    let library = root.path().join("library");
    std::fs::create_dir_all(&library)?;
    let video = library.join("sample.mp4");
    let generated = Command::new(&ffmpeg)
        .args([
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-f",
            "lavfi",
            "-i",
            "testsrc=size=160x90:rate=10",
            "-t",
            "1",
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
            "-movflags",
            "+faststart",
        ])
        .arg(&video)
        .status()?;
    anyhow::ensure!(generated.success(), "failed to generate video fixture");
    std::fs::write(
        library.join("sample.zh.srt"),
        "1\n00:00:00,000 --> 00:00:00,800\nLocalLens 视频回归测试\n",
    )?;

    let config = AppConfig {
        listen_address: "127.0.0.1:0".into(),
        public_url: "http://127.0.0.1:9527".into(),
        server_name: "LocalLens Video Test".into(),
        data_dir: root.path().join("data"),
        api_token: ADMIN_TOKEN.into(),
        ffmpeg_path: ffmpeg,
        ffprobe_path: ffprobe,
        auto_scan: false,
        watch_files: false,
        thumbnail_workers: 1,
        metadata_workers: 1,
        transcode_workers: 1,
        transcode_cache_gb: 1,
        transcode_hardware: "software".into(),
        pairing_ttl_minutes: 5,
        libraries: vec![LibraryConfig {
            id: "video".into(),
            name: "视频回归媒体库".into(),
            path: library,
            recursive: true,
            enabled: true,
        }],
    };
    let state = AppState::new(config).await?;
    state.start_background().await?;
    let app = router(state.clone());

    let scan = call_json(&app, "POST", "/api/v1/scan", None).await?;
    assert_eq!(scan.0, StatusCode::OK);
    wait_for_scan(&state).await?;

    let media = wait_for_video_metadata(&app).await?;
    let media_id = media["id"].as_str().context("media id missing")?;
    assert_eq!(media["type"], "video");
    assert_eq!(media["mimeType"], "video/mp4");
    assert_eq!(media["width"], 160);
    assert_eq!(media["height"], 90);
    assert_eq!(media["codec"], "h264");
    assert!(media["durationMs"].as_i64().unwrap_or_default() >= 900);

    let range = call_raw_with_headers(
        &app,
        "GET",
        &format!("/api/v1/media/{media_id}/stream"),
        None,
        &[(header::RANGE, "bytes=0-99")],
    )
    .await?;
    assert_eq!(range.status(), StatusCode::PARTIAL_CONTENT);
    assert!(range.headers().contains_key(header::CONTENT_RANGE));
    assert_eq!(range.into_body().collect().await?.to_bytes().len(), 100);

    let direct = call_json(
        &app,
        "POST",
        &format!("/api/v1/media/{media_id}/playback-manifest"),
        Some(json!({
            "platform": "android",
            "videoCodecs": ["h264"],
            "containers": ["mp4"],
            "supportsHls": true,
            "maxWidth": 1920,
            "maxHeight": 1080
        })),
    )
    .await?;
    assert_eq!(direct.0, StatusCode::OK);
    assert_eq!(direct.1["mode"], "direct");
    assert_eq!(direct.1["status"], "ready");
    assert_eq!(direct.1["subtitles"][0]["language"], "zh");
    let subtitle_url = direct.1["subtitles"][0]["url"]
        .as_str()
        .context("subtitle url missing")?;
    let subtitle = call_raw_with_headers(&app, "GET", subtitle_url, None, &[]).await?;
    assert_eq!(subtitle.status(), StatusCode::OK);
    let subtitle_text = String::from_utf8(subtitle.into_body().collect().await?.to_bytes().to_vec())?;
    assert!(subtitle_text.contains("LocalLens 视频回归测试"));

    let hls = wait_for_hls(&app, media_id).await?;
    assert_eq!(hls["mode"], "transcode");
    assert_eq!(hls["status"], "ready");
    let playlist_url = hls["url"].as_str().context("playlist url missing")?;
    let playlist = call_raw_with_headers(&app, "GET", playlist_url, None, &[]).await?;
    assert_eq!(playlist.status(), StatusCode::OK);
    let playlist_text = String::from_utf8(playlist.into_body().collect().await?.to_bytes().to_vec())?;
    assert!(playlist_text.contains("#EXTM3U"));
    assert!(playlist_text.contains("segment-"));

    let diagnostics = call_json(&app, "GET", "/api/v1/transcodes/diagnostics", None).await?;
    assert_eq!(diagnostics.0, StatusCode::OK);
    assert_eq!(diagnostics.1["ffmpegAvailable"], true);
    assert_eq!(diagnostics.1["failed"], 0);

    state.runtime.stop().await;
    Ok(())
}

fn executable(environment: &str, fallback: &str) -> PathBuf {
    std::env::var_os(environment)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(fallback))
}

async fn wait_for_scan(state: &AppState) -> Result<()> {
    for _ in 0..200 {
        if !state
            .runtime
            .scanning
            .load(std::sync::atomic::Ordering::SeqCst)
        {
            let status = state.runtime.scan_status.read().await.clone();
            anyhow::ensure!(status.error_message.is_empty(), status.error_message);
            return Ok(());
        }
        sleep(Duration::from_millis(25)).await;
    }
    anyhow::bail!("scan timeout")
}

async fn wait_for_video_metadata(app: &Router) -> Result<Value> {
    for _ in 0..120 {
        let response = call_json(app, "GET", "/api/v1/media?type=video", None).await?;
        if response.0 == StatusCode::OK
            && response.1["total"] == 1
            && response.1["items"][0]["metadataStatus"] == "done"
        {
            return Ok(response.1["items"][0].clone());
        }
        sleep(Duration::from_millis(100)).await;
    }
    anyhow::bail!("video metadata timeout")
}

async fn wait_for_hls(app: &Router, media_id: &str) -> Result<Value> {
    for _ in 0..120 {
        let response = call_json(
            app,
            "POST",
            &format!("/api/v1/media/{media_id}/playback-manifest"),
            Some(json!({
                "platform": "android",
                "videoCodecs": ["h264"],
                "containers": ["mp4"],
                "supportsHls": true,
                "preferredHeight": 360,
                "forceTranscode": true
            })),
        )
        .await?;
        if response.0 == StatusCode::OK && response.1["status"] == "ready" {
            return Ok(response.1);
        }
        if response.0 != StatusCode::ACCEPTED {
            anyhow::bail!("unexpected HLS response: {} {}", response.0, response.1);
        }
        sleep(Duration::from_millis(250)).await;
    }
    anyhow::bail!("HLS transcode timeout")
}

async fn call_json(
    app: &Router,
    method: &str,
    uri: &str,
    body: Option<Value>,
) -> Result<(StatusCode, Value)> {
    let response = call_raw_with_headers(app, method, uri, body, &[]).await?;
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

async fn call_raw_with_headers(
    app: &Router,
    method: &str,
    uri: &str,
    body: Option<Value>,
    headers: &[(header::HeaderName, &str)],
) -> Result<axum::response::Response> {
    let mut builder = Request::builder()
        .method(method)
        .uri(uri)
        .header(header::AUTHORIZATION, format!("Bearer {ADMIN_TOKEN}"));
    for (name, value) in headers {
        builder = builder.header(name, *value);
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
