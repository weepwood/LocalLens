use std::{fs::File, io::BufWriter, path::{Path, PathBuf}};

use anyhow::{Context, Result};
use chrono::DateTime;
use image::codecs::jpeg::JpegEncoder;
use local_lens_core::{random_id, MediaItem, MetadataJob, ThumbnailJob};
use tokio::{process::Command, time::{sleep, Duration}};

use crate::{metadata, playback, runtime::AppState};

const IDLE_INTERVAL: Duration = Duration::from_secs(5);

pub fn start_workers(state: AppState) {
    for number in 0..state.config.thumbnail_workers {
        spawn_thumbnail_worker(state.clone(), number + 1);
    }
    for number in 0..state.config.metadata_workers {
        spawn_metadata_worker(state.clone(), number + 1);
    }
    playback::start_transcode_workers(state.clone());
    state.runtime.thumbnail_notify.notify_waiters();
    state.runtime.metadata_notify.notify_waiters();
    state.runtime.transcode_notify.notify_waiters();
}

fn spawn_thumbnail_worker(state: AppState, number: usize) {
    let runtime = state.runtime.clone();
    let mut shutdown = state.runtime.shutdown.subscribe();
    let handle = tokio::spawn(async move {
        loop {
            if *shutdown.borrow() { break; }
            if state.runtime.scanning.load(std::sync::atomic::Ordering::SeqCst) {
                tokio::select! {
                    _ = shutdown.changed() => {},
                    _ = sleep(Duration::from_millis(500)) => {},
                }
                continue;
            }
            match state.store.claim_thumbnail_job().await {
                Ok(Some(job)) => process_thumbnail_job(&state, job, number).await,
                Ok(None) => {
                    tokio::select! {
                        _ = shutdown.changed() => {},
                        _ = state.runtime.thumbnail_notify.notified() => {},
                        _ = sleep(IDLE_INTERVAL) => {},
                    }
                }
                Err(error) => {
                    tracing::warn!(worker = number, %error, "领取缩略图任务失败");
                    sleep(Duration::from_millis(500)).await;
                }
            }
        }
    });
    runtime.track(handle);
}

fn spawn_metadata_worker(state: AppState, number: usize) {
    let runtime = state.runtime.clone();
    let mut shutdown = state.runtime.shutdown.subscribe();
    let handle = tokio::spawn(async move {
        loop {
            if *shutdown.borrow() { break; }
            if state.runtime.scanning.load(std::sync::atomic::Ordering::SeqCst) {
                tokio::select! {
                    _ = shutdown.changed() => {},
                    _ = sleep(Duration::from_millis(500)) => {},
                }
                continue;
            }
            match state.store.claim_metadata_job().await {
                Ok(Some(job)) => process_metadata_job(&state, job, number).await,
                Ok(None) => {
                    tokio::select! {
                        _ = shutdown.changed() => {},
                        _ = state.runtime.metadata_notify.notified() => {},
                        _ = sleep(IDLE_INTERVAL) => {},
                    }
                }
                Err(error) => {
                    tracing::warn!(worker = number, %error, "领取元数据任务失败");
                    sleep(Duration::from_millis(500)).await;
                }
            }
        }
    });
    runtime.track(handle);
}

async fn process_thumbnail_job(state: &AppState, job: ThumbnailJob, number: usize) {
    let result = async {
        let media = state.store.media_by_id(&job.media_id).await?.context("媒体不存在或已被删除")?;
        if media.modified_at != job.source_modified_at { anyhow::bail!("媒体在任务排队后发生变化"); }
        generate_thumbnail(state, &media, job.width).await
    }.await;
    match result {
        Ok(_) => {
            if let Err(error) = state.store.finish_thumbnail_job(&job, "done", "").await {
                tracing::warn!(worker = number, %error, "完成缩略图任务状态失败");
            }
        }
        Err(error) => {
            let message = truncate_error(&error);
            let status = if job.attempts < 3 { "pending" } else { "failed" };
            if let Err(store_error) = state.store.finish_thumbnail_job(&job, status, &message).await {
                tracing::warn!(worker = number, %store_error, "记录缩略图失败状态失败");
            }
            if status == "pending" { state.runtime.thumbnail_notify.notify_one(); }
            else { tracing::warn!(worker = number, media = %job.media_id, %error, "缩略图任务失败"); }
        }
    }
}

async fn process_metadata_job(state: &AppState, job: MetadataJob, number: usize) {
    let result = async {
        let media = state.store.media_by_id(&job.media_id).await?.context("媒体不存在或已被删除")?;
        if media.modified_at != job.source_modified_at { anyhow::bail!("媒体在任务排队后发生变化"); }
        metadata::extract_and_store(state, &media).await
    }.await;
    match result {
        Ok(()) => {
            if let Err(error) = state.store.finish_metadata_job(&job, "done", "").await {
                tracing::warn!(worker = number, %error, "完成元数据任务状态失败");
            }
        }
        Err(error) => {
            let message = truncate_error(&error);
            let status = if job.attempts < 3 { "pending" } else { "failed" };
            if let Err(store_error) = state.store.finish_metadata_job(&job, status, &message).await {
                tracing::warn!(worker = number, %store_error, "记录元数据失败状态失败");
            }
            if status == "pending" { state.runtime.metadata_notify.notify_one(); }
            else { tracing::warn!(worker = number, media = %job.media_id, %error, "元数据任务失败"); }
        }
    }
}

pub async fn generate_thumbnail(state: &AppState, media: &MediaItem, width: i64) -> Result<PathBuf> {
    let target = thumbnail_path(state, media, width);
    if target.is_file() { return Ok(target); }
    let source = state.media_path(media).context("媒体文件路径不安全")?;
    if media.media_type == "image" {
        let native_source = source.clone();
        let native_target = target.clone();
        let native_result = tokio::task::spawn_blocking(move || generate_native_image_thumbnail(&native_source, &native_target, width))
            .await.context("图片缩略图线程异常退出")?;
        if native_result.is_ok() { return Ok(target); }
        tracing::debug!(media = %media.id, error = %native_result.unwrap_err(), "原生图片解码失败，回退 FFmpeg");
    }
    generate_ffmpeg_thumbnail(state, media, &source, &target, width).await?;
    Ok(target)
}

pub fn thumbnail_path(state: &AppState, media: &MediaItem, width: i64) -> PathBuf {
    let timestamp = DateTime::parse_from_rfc3339(&media.modified_at).map(|value| value.timestamp()).unwrap_or_default();
    let prefix = media.id.get(..2).unwrap_or("00");
    state.config.data_dir.join("thumbnails").join(prefix).join(format!("{}-{}-{}.jpg", media.id, timestamp, width.clamp(64, 1920)))
}

fn generate_native_image_thumbnail(source: &Path, target: &Path, width: i64) -> Result<()> {
    let image = image::open(source).with_context(|| format!("无法解码图片：{}", source.display()))?;
    let width = u32::try_from(width.clamp(64, 1920)).unwrap_or(480);
    let source_width = image.width().max(1);
    let source_height = image.height().max(1);
    let target_width = width.min(source_width);
    let target_height = ((u64::from(source_height) * u64::from(target_width)) / u64::from(source_width)).max(1) as u32;
    let thumbnail = image.thumbnail_exact(target_width, target_height);
    if let Some(parent) = target.parent() { std::fs::create_dir_all(parent)?; }
    let temporary = target.with_extension(format!("{}.tmp.jpg", random_id()));
    let file = File::create(&temporary)?;
    let mut writer = BufWriter::new(file);
    JpegEncoder::new_with_quality(&mut writer, 82).encode_image(&thumbnail)?;
    replace_file(&temporary, target)?;
    Ok(())
}

async fn generate_ffmpeg_thumbnail(state: &AppState, media: &MediaItem, source: &Path, target: &Path, width: i64) -> Result<()> {
    if state.config.ffmpeg_path.as_os_str().is_empty() { anyhow::bail!("ffmpeg is not configured"); }
    if !state.config.ffmpeg_path.is_file() { anyhow::bail!("ffmpeg unavailable: {}", state.config.ffmpeg_path.display()); }
    if let Some(parent) = target.parent() { tokio::fs::create_dir_all(parent).await?; }
    let temporary = target.with_extension(format!("{}.tmp.jpg", random_id()));
    let mut command = Command::new(&state.config.ffmpeg_path);
    command.args(["-hide_banner", "-loglevel", "error"]);
    if media.media_type == "video" {
        command.args(["-ss", if media.duration_ms > 0 && media.duration_ms < 6000 { "0.2" } else { "2" }]);
    }
    let scale = format!("scale={}:-2", width.clamp(64, 1920));
    let output = command.arg("-i").arg(source).args(["-frames:v", "1", "-vf"]).arg(scale).args(["-q:v", "4", "-y"]).arg(&temporary).output().await?;
    if !output.status.success() {
        let _ = tokio::fs::remove_file(&temporary).await;
        anyhow::bail!("ffmpeg: {}", String::from_utf8_lossy(&output.stderr).trim());
    }
    replace_file(&temporary, target)?;
    Ok(())
}

fn replace_file(source: &Path, target: &Path) -> Result<()> {
    if target.exists() { std::fs::remove_file(target)?; }
    std::fs::rename(source, target)?;
    Ok(())
}

fn truncate_error(error: &anyhow::Error) -> String {
    let value = error.to_string();
    if value.chars().count() <= 1000 { value } else { value.chars().take(1000).collect() }
}
