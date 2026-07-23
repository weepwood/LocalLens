use std::{
    cmp::Reverse,
    fs,
    path::{Component, Path, PathBuf},
    sync::atomic::Ordering,
};

use anyhow::{Context, Result};
use axum::http::StatusCode;
use local_lens_core::{
    MediaItem, PlaybackManifest, PlaybackRequest, SubtitleManifest, TranscodeJob,
};
use serde_json::{Value, json};
use tokio::{
    process::Command,
    time::{Duration, sleep},
};

use crate::runtime::AppState;

const TRANSCODE_IDLE: Duration = Duration::from_secs(2);

pub fn start_transcode_workers(state: AppState) {
    for number in 0..state.config.transcode_workers {
        let worker_state = state.clone();
        let runtime = state.runtime.clone();
        let mut shutdown = state.runtime.shutdown.subscribe();
        let handle = tokio::spawn(async move {
            loop {
                if *shutdown.borrow() {
                    break;
                }
                if worker_state.runtime.scanning.load(Ordering::SeqCst) {
                    tokio::select! {
                        _ = shutdown.changed() => {},
                        _ = sleep(Duration::from_millis(500)) => {},
                    }
                    continue;
                }
                match worker_state.store.claim_transcode_job().await {
                    Ok(Some(job)) => process_transcode_job(&worker_state, job, number + 1).await,
                    Ok(None) => {
                        tokio::select! {
                            _ = shutdown.changed() => {},
                            _ = worker_state.runtime.transcode_notify.notified() => {},
                            _ = sleep(TRANSCODE_IDLE) => {},
                        }
                    }
                    Err(error) => {
                        tracing::warn!(worker = number + 1, %error, "领取转码任务失败");
                        sleep(Duration::from_millis(500)).await;
                    }
                }
            }
        });
        runtime.track(handle);
    }
}

async fn process_transcode_job(state: &AppState, job: TranscodeJob, worker: usize) {
    let result = async {
        let media = state
            .store
            .media_by_id(&job.media_id)
            .await?
            .context("媒体不存在或已删除")?;
        if media.media_type != "video" {
            anyhow::bail!("媒体不是视频");
        }
        if media.modified_at != job.source_modified_at {
            anyhow::bail!("媒体在任务排队后发生变化");
        }
        generate_hls(state, &media, &job.profile).await
    }
    .await;
    match result {
        Ok(()) => {
            if let Err(error) = state
                .store
                .finish_transcode_job(&job, "done", 1.0, "")
                .await
            {
                tracing::warn!(worker, %error, "完成转码任务状态失败");
            }
        }
        Err(error) => {
            let message = truncate_error(&error);
            let retryable = job.attempts < 2
                && !message.to_ascii_lowercase().contains("not configured")
                && !message.to_ascii_lowercase().contains("unavailable");
            let status = if retryable { "pending" } else { "failed" };
            if let Err(store_error) = state
                .store
                .finish_transcode_job(&job, status, 0.0, &message)
                .await
            {
                tracing::warn!(worker, %store_error, "记录转码失败状态失败");
            }
            if retryable {
                state.runtime.transcode_notify.notify_one();
            } else {
                tracing::warn!(worker, media = %job.media_id, profile = %job.profile, %error, "转码任务失败");
            }
        }
    }
}

pub async fn playback_manifest(
    state: &AppState,
    media: &MediaItem,
    request: PlaybackRequest,
) -> Result<(StatusCode, PlaybackManifest)> {
    let subtitles = discover_subtitles(state, media);
    if !request.force_transcode && supports_direct_playback(media, &request) {
        return Ok((
            StatusCode::OK,
            PlaybackManifest {
                mode: "direct".into(),
                status: "ready".into(),
                url: format!("/api/v1/media/{}/stream", media.id),
                mime_type: media.mime_type.clone(),
                profile: String::new(),
                codec: media.codec.clone(),
                width: media.width,
                height: media.height,
                progress: 0.0,
                retry_after: 0,
                error: String::new(),
                subtitles,
            },
        ));
    }
    if !request.supports_hls {
        return Ok((
            StatusCode::UNPROCESSABLE_ENTITY,
            failed_manifest(media, subtitles, "客户端不支持 HLS，且原始视频无法直接播放"),
        ));
    }
    if let Err(error) = ensure_ffmpeg(state) {
        return Ok((
            StatusCode::SERVICE_UNAVAILABLE,
            failed_manifest(media, subtitles, &error.to_string()),
        ));
    }
    let height =
        select_transcode_height(media.height, request.preferred_height, request.max_height);
    let profile = format!("h264-{height}p");
    let mut transcode = state.store.transcode_state(&media.id, &profile).await?;
    let playlist = transcode_profile_dir(state, &media.id, &profile).join("index.m3u8");
    if transcode.status == "done" && playlist.is_file() {
        return Ok((
            StatusCode::OK,
            PlaybackManifest {
                mode: "transcode".into(),
                status: "ready".into(),
                url: format!("/api/v1/transcodes/{}/{}/index.m3u8", media.id, profile),
                mime_type: "application/vnd.apple.mpegurl".into(),
                profile,
                codec: "h264".into(),
                width: media.width,
                height,
                progress: 1.0,
                retry_after: 0,
                error: String::new(),
                subtitles,
            },
        ));
    }
    if transcode.status == "failed" {
        let mut manifest = failed_manifest(media, subtitles, &transcode.error);
        manifest.profile = profile;
        manifest.codec = "h264".into();
        manifest.height = height;
        return Ok((StatusCode::UNPROCESSABLE_ENTITY, manifest));
    }
    state.store.enqueue_transcode(media, &profile).await?;
    state.runtime.transcode_notify.notify_one();
    transcode = state.store.transcode_state(&media.id, &profile).await?;
    Ok((
        StatusCode::ACCEPTED,
        PlaybackManifest {
            mode: "transcode".into(),
            status: "preparing".into(),
            url: String::new(),
            mime_type: String::new(),
            profile,
            codec: "h264".into(),
            width: media.width,
            height,
            progress: transcode.progress,
            retry_after: 2,
            error: String::new(),
            subtitles,
        },
    ))
}

pub fn subtitle_file(state: &AppState, media: &MediaItem, name: &str) -> Option<PathBuf> {
    if !is_safe_file_name(name) || !is_subtitle_extension(Path::new(name)) {
        return None;
    }
    let source = state.media_path(media)?;
    let path = source.parent()?.join(name);
    if path.is_file() { Some(path) } else { None }
}

pub fn transcode_file(
    state: &AppState,
    media_id: &str,
    profile: &str,
    file: &str,
) -> Option<PathBuf> {
    if !profile
        .chars()
        .all(|value| value.is_ascii_alphanumeric() || value == '-' || value == '_')
        || !is_safe_file_name(file)
    {
        return None;
    }
    let path = transcode_profile_dir(state, media_id, profile).join(file);
    if path.is_file() { Some(path) } else { None }
}

pub async fn diagnostics(state: &AppState) -> Result<Value> {
    let pending =
        sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM transcode_jobs WHERE status='pending'")
            .fetch_one(state.store.pool())
            .await?;
    let running =
        sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM transcode_jobs WHERE status='running'")
            .fetch_one(state.store.pool())
            .await?;
    let failed =
        sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM transcode_jobs WHERE status='failed'")
            .fetch_one(state.store.pool())
            .await?;
    Ok(json!({
        "ffmpegPath": state.config.ffmpeg_path,
        "ffmpegAvailable": state.config.ffmpeg_path.is_file(),
        "hardware": state.config.transcode_hardware,
        "workers": state.config.transcode_workers,
        "cacheGb": state.config.transcode_cache_gb,
        "pending": pending,
        "running": running,
        "failed": failed
    }))
}

pub async fn retry_failed(state: &AppState) -> Result<u64> {
    let count = state.store.retry_failed_transcodes().await?;
    if count > 0 {
        state.runtime.transcode_notify.notify_waiters();
    }
    Ok(count)
}

async fn generate_hls(state: &AppState, media: &MediaItem, profile: &str) -> Result<()> {
    ensure_ffmpeg(state)?;
    let source = state.media_path(media).context("媒体路径不安全")?;
    let height = profile_height(profile).context("无效转码配置")?;
    let output_dir = transcode_profile_dir(state, &media.id, profile);
    if output_dir.exists() {
        tokio::fs::remove_dir_all(&output_dir).await?;
    }
    tokio::fs::create_dir_all(&output_dir).await?;
    state
        .store
        .update_transcode_progress(&media.id, profile, 0.05)
        .await?;
    let segment_pattern = output_dir.join("segment-%05d.ts");
    let playlist = output_dir.join("index.m3u8");
    let scale = format!("scale=-2:{height}");
    let encoder = match state.config.transcode_hardware.as_str() {
        "nvenc" => "h264_nvenc",
        "qsv" => "h264_qsv",
        "amf" => "h264_amf",
        _ => "libx264",
    };
    let output = Command::new(&state.config.ffmpeg_path)
        .args(["-hide_banner", "-loglevel", "error", "-y", "-i"])
        .arg(&source)
        .args(["-map", "0:v:0", "-map", "0:a?", "-vf"])
        .arg(scale)
        .args([
            "-c:v", encoder, "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "160k",
        ])
        .args([
            "-f",
            "hls",
            "-hls_time",
            "6",
            "-hls_playlist_type",
            "vod",
            "-hls_segment_filename",
        ])
        .arg(&segment_pattern)
        .arg(&playlist)
        .output()
        .await?;
    if !output.status.success() {
        let _ = tokio::fs::remove_dir_all(&output_dir).await;
        anyhow::bail!(
            "ffmpeg 转码失败：{}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    state
        .store
        .update_transcode_progress(&media.id, profile, 1.0)
        .await?;
    let cache_root = state.config.data_dir.join("transcodes");
    let limit = state
        .config
        .transcode_cache_gb
        .saturating_mul(1024 * 1024 * 1024);
    tokio::task::spawn_blocking(move || prune_cache(&cache_root, limit)).await??;
    Ok(())
}

fn ensure_ffmpeg(state: &AppState) -> Result<()> {
    if state.config.ffmpeg_path.as_os_str().is_empty() {
        anyhow::bail!("ffmpeg is not configured");
    }
    if !state.config.ffmpeg_path.is_file() {
        anyhow::bail!("ffmpeg unavailable: {}", state.config.ffmpeg_path.display());
    }
    Ok(())
}

fn failed_manifest(
    media: &MediaItem,
    subtitles: Vec<SubtitleManifest>,
    error: &str,
) -> PlaybackManifest {
    PlaybackManifest {
        mode: "transcode".into(),
        status: "failed".into(),
        url: String::new(),
        mime_type: String::new(),
        profile: String::new(),
        codec: media.codec.clone(),
        width: media.width,
        height: media.height,
        progress: 0.0,
        retry_after: 0,
        error: error.into(),
        subtitles,
    }
}

fn supports_direct_playback(media: &MediaItem, request: &PlaybackRequest) -> bool {
    let codec = normalize_codec(&media.codec);
    if !codec.is_empty()
        && !request.video_codecs.is_empty()
        && !request
            .video_codecs
            .iter()
            .any(|value| normalize_codec(value) == codec)
    {
        return false;
    }
    let container = container_name(&media.mime_type);
    if !container.is_empty()
        && !request.containers.is_empty()
        && !request
            .containers
            .iter()
            .any(|value| value.trim().eq_ignore_ascii_case(container))
    {
        return false;
    }
    if request.max_width > 0 && media.width > request.max_width {
        return false;
    }
    if request.max_height > 0 && media.height > request.max_height {
        return false;
    }
    true
}

fn normalize_codec(value: &str) -> String {
    match value.trim().to_ascii_lowercase().as_str() {
        "avc" | "avc1" | "h.264" => "h264".into(),
        "h265" | "h.265" | "hev1" | "hvc1" => "hevc".into(),
        "vp09" => "vp9".into(),
        "av01" => "av1".into(),
        value => value.into(),
    }
}

fn container_name(mime: &str) -> &'static str {
    match mime.trim().to_ascii_lowercase().as_str() {
        "video/mp4" | "video/x-m4v" | "video/quicktime" => "mp4",
        "video/x-matroska" => "mkv",
        "video/webm" => "webm",
        "video/x-msvideo" => "avi",
        "video/x-ms-wmv" => "wmv",
        _ => "",
    }
}

fn select_transcode_height(source: i64, preferred: i64, maximum: i64) -> i64 {
    let mut target = if preferred > 0 { preferred } else { 1080 };
    if maximum > 0 {
        target = target.min(maximum);
    }
    if source > 0 {
        target = target.min(source);
    }
    [2160_i64, 1440, 1080, 720, 480, 360]
        .into_iter()
        .find(|height| *height <= target)
        .unwrap_or(360)
}

fn profile_height(profile: &str) -> Option<i64> {
    profile
        .strip_prefix("h264-")?
        .strip_suffix('p')?
        .parse()
        .ok()
}

fn transcode_profile_dir(state: &AppState, media_id: &str, profile: &str) -> PathBuf {
    state
        .config
        .data_dir
        .join("transcodes")
        .join(media_id)
        .join(profile)
}

fn discover_subtitles(state: &AppState, media: &MediaItem) -> Vec<SubtitleManifest> {
    let Some(source) = state.media_path(media) else {
        return Vec::new();
    };
    let Some(parent) = source.parent() else {
        return Vec::new();
    };
    let stem = source
        .file_stem()
        .map(|value| value.to_string_lossy().to_string())
        .unwrap_or_default();
    let Ok(entries) = fs::read_dir(parent) else {
        return Vec::new();
    };
    let mut subtitles = entries
        .flatten()
        .filter_map(|entry| {
            let path = entry.path();
            if !path.is_file() || !is_subtitle_extension(&path) {
                return None;
            }
            let file_stem = path.file_stem()?.to_string_lossy();
            if file_stem != stem && !file_stem.starts_with(&format!("{stem}.")) {
                return None;
            }
            let name = path.file_name()?.to_string_lossy().to_string();
            let language = file_stem
                .strip_prefix(&format!("{stem}."))
                .unwrap_or("und")
                .to_string();
            let format = path.extension()?.to_string_lossy().to_ascii_lowercase();
            Some(SubtitleManifest {
                id: name.clone(),
                name: name.clone(),
                language,
                format,
                url: format!(
                    "/api/v1/media/{}/subtitle/{}",
                    media.id,
                    urlencoding::encode(&name)
                ),
            })
        })
        .collect::<Vec<_>>();
    subtitles.sort_by(|left, right| left.name.cmp(&right.name));
    subtitles
}

fn is_subtitle_extension(path: &Path) -> bool {
    matches!(
        path.extension()
            .map(|value| value.to_string_lossy().to_ascii_lowercase()),
        Some(value) if matches!(value.as_str(), "srt" | "vtt" | "ass" | "ssa")
    )
}

fn is_safe_file_name(value: &str) -> bool {
    if value.is_empty() {
        return false;
    }
    let path = Path::new(value);
    path.components().count() == 1
        && path
            .components()
            .all(|component| matches!(component, Component::Normal(_)))
}

fn prune_cache(root: &Path, limit: u64) -> Result<()> {
    if !root.is_dir() {
        return Ok(());
    }
    let mut profiles = Vec::new();
    let mut total = 0_u64;
    for media in fs::read_dir(root)?.flatten() {
        if !media.path().is_dir() {
            continue;
        }
        for profile in fs::read_dir(media.path())?.flatten() {
            let path = profile.path();
            if !path.is_dir() {
                continue;
            }
            let size = directory_size(&path);
            total = total.saturating_add(size);
            let modified = profile
                .metadata()
                .and_then(|metadata| metadata.modified())
                .ok();
            profiles.push((modified, size, path));
        }
    }
    profiles.sort_by_key(|(modified, _, _)| Reverse(*modified));
    while total > limit {
        let Some((_, size, path)) = profiles.pop() else {
            break;
        };
        if fs::remove_dir_all(path).is_ok() {
            total = total.saturating_sub(size);
        }
    }
    Ok(())
}

fn directory_size(path: &Path) -> u64 {
    walkdir::WalkDir::new(path)
        .into_iter()
        .filter_map(|entry| entry.ok())
        .filter_map(|entry| entry.metadata().ok())
        .filter(|metadata| metadata.is_file())
        .map(|metadata| metadata.len())
        .sum()
}

fn truncate_error(error: &anyhow::Error) -> String {
    let value = error.to_string();
    if value.chars().count() <= 1000 {
        value
    } else {
        value.chars().take(1000).collect()
    }
}
