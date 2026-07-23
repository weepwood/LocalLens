use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::atomic::Ordering,
    time::SystemTime,
};

use anyhow::{Context, Result};
use chrono::{DateTime, SecondsFormat, Utc};
use local_lens_core::{LibraryConfig, ScanStatus, media_type_for_path, random_id, stable_id};
use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use sqlx::{Sqlite, Transaction};
use tokio::{
    sync::mpsc,
    time::{Duration, Instant, interval, sleep},
};
use walkdir::WalkDir;

use crate::runtime::AppState;

#[derive(Debug)]
enum ScanEntry {
    Folder {
        relative: String,
        parent: String,
        name: String,
    },
    Media {
        id: String,
        relative: String,
        folder: String,
        file_name: String,
        media_type: String,
        mime_type: String,
        size_bytes: i64,
        modified_at: String,
    },
    Failed(String),
}

pub async fn start_scan(state: AppState) -> bool {
    if state
        .runtime
        .scanning
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_err()
    {
        return false;
    }
    {
        let mut status = state.runtime.scan_status.write().await;
        *status = ScanStatus {
            running: true,
            started_at: Some(Utc::now()),
            ..Default::default()
        };
    }
    let runtime = state.runtime.clone();
    let handle = tokio::spawn(async move {
        let mut errors = Vec::new();
        for library in state.libraries.values() {
            if !library.enabled || *state.runtime.shutdown.borrow() {
                continue;
            }
            {
                let mut status = state.runtime.scan_status.write().await;
                status.current = library.name.clone();
            }
            if let Err(error) = scan_library(&state, library.clone()).await {
                tracing::warn!(library = %library.id, %error, "扫描媒体库失败");
                errors.push(format!("{}: {error}", library.name));
            }
        }
        let mut status = state.runtime.scan_status.write().await;
        status.running = false;
        status.current.clear();
        status.finished_at = Some(Utc::now());
        status.error_message = errors.join("; ");
        state.runtime.scanning.store(false, Ordering::SeqCst);
        state.runtime.thumbnail_notify.notify_waiters();
        state.runtime.metadata_notify.notify_waiters();
    });
    runtime.track(handle);
    true
}

pub async fn scan_status(state: &AppState) -> ScanStatus {
    state.runtime.scan_status.read().await.clone()
}

async fn scan_library(state: &AppState, library: LibraryConfig) -> Result<()> {
    let root = library.path.clone();
    if !root.is_dir() {
        anyhow::bail!("媒体库目录不可用：{}", root.display());
    }
    let scan_id = random_id();
    let (sender, mut receiver) = mpsc::channel::<ScanEntry>(512);
    let producer_library = library.clone();
    let producer = tokio::task::spawn_blocking(move || -> Result<()> {
        let mut walker = WalkDir::new(&producer_library.path).follow_links(false);
        if !producer_library.recursive {
            walker = walker.max_depth(1);
        }
        for result in walker {
            let entry = match result {
                Ok(entry) => entry,
                Err(error) => {
                    let _ = sender.blocking_send(ScanEntry::Failed(error.to_string()));
                    continue;
                }
            };
            if entry.depth() == 0 {
                continue;
            }
            let path = entry.path();
            if entry.file_type().is_dir() {
                if !producer_library.recursive {
                    continue;
                }
                let relative = relative_path(&producer_library.path, path)?;
                let item = ScanEntry::Folder {
                    parent: parent_folder(&relative),
                    name: entry.file_name().to_string_lossy().to_string(),
                    relative,
                };
                if sender.blocking_send(item).is_err() {
                    break;
                }
                continue;
            }
            let Some((media_type, mime_type)) = media_type_for_path(path) else {
                continue;
            };
            let metadata = match entry.metadata() {
                Ok(metadata) => metadata,
                Err(error) => {
                    let _ = sender.blocking_send(ScanEntry::Failed(error.to_string()));
                    continue;
                }
            };
            let relative = relative_path(&producer_library.path, path)?;
            let modified_at = system_time(metadata.modified().unwrap_or(SystemTime::UNIX_EPOCH));
            let item = ScanEntry::Media {
                id: stable_id(&producer_library.id, &relative),
                folder: parent_folder(&relative),
                file_name: entry.file_name().to_string_lossy().to_string(),
                relative,
                media_type: media_type.into(),
                mime_type: mime_type.into(),
                size_bytes: i64::try_from(metadata.len()).unwrap_or(i64::MAX),
                modified_at,
            };
            if sender.blocking_send(item).is_err() {
                break;
            }
        }
        Ok(())
    });

    let mut tx = state.store.pool().begin().await?;
    upsert_folder(&mut tx, &library, "", "", &library.name, &scan_id).await?;
    while let Some(entry) = receiver.recv().await {
        match entry {
            ScanEntry::Folder {
                relative,
                parent,
                name,
            } => {
                upsert_folder(&mut tx, &library, &relative, &parent, &name, &scan_id).await?;
            }
            ScanEntry::Media {
                id,
                relative,
                folder,
                file_name,
                media_type,
                mime_type,
                size_bytes,
                modified_at,
            } => {
                if !folder.is_empty() {
                    let name = Path::new(&folder)
                        .file_name()
                        .map(|value| value.to_string_lossy().to_string())
                        .unwrap_or_else(|| folder.clone());
                    upsert_folder(
                        &mut tx,
                        &library,
                        &folder,
                        &parent_folder(&folder),
                        &name,
                        &scan_id,
                    )
                    .await?;
                }
                upsert_media(
                    &mut tx,
                    &library,
                    &id,
                    &relative,
                    &folder,
                    &file_name,
                    &media_type,
                    &mime_type,
                    size_bytes,
                    &modified_at,
                    &scan_id,
                )
                .await?;
                let mut status = state.runtime.scan_status.write().await;
                status.discovered += 1;
                status.indexed += 1;
            }
            ScanEntry::Failed(error) => {
                tracing::debug!(%error, "跳过无法读取的媒体文件");
                state.runtime.scan_status.write().await.failed += 1;
            }
        }
    }
    producer.await.context("扫描线程异常退出")??;
    sqlx::query("UPDATE media_items SET missing=1 WHERE library_id=? AND last_seen_scan<>?")
        .bind(&library.id)
        .bind(&scan_id)
        .execute(&mut *tx)
        .await?;
    sqlx::query("UPDATE folders SET missing=1 WHERE library_id=? AND last_seen_scan<>?")
        .bind(&library.id)
        .bind(&scan_id)
        .execute(&mut *tx)
        .await?;
    sqlx::query("UPDATE libraries SET last_scanned_at=? WHERE id=?")
        .bind(Utc::now().to_rfc3339_opts(SecondsFormat::Nanos, true))
        .bind(&library.id)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
async fn upsert_media(
    tx: &mut Transaction<'_, Sqlite>,
    library: &LibraryConfig,
    id: &str,
    relative: &str,
    folder: &str,
    file_name: &str,
    media_type: &str,
    mime_type: &str,
    size_bytes: i64,
    modified_at: &str,
    scan_id: &str,
) -> Result<()> {
    sqlx::query(
        r#"INSERT INTO media_items(
 id,library_id,relative_path,folder_path,file_name,media_type,mime_type,
 size_bytes,modified_at,captured_at,captured_at_source,missing,last_seen_scan,
 metadata_status,metadata_error)
VALUES(?,?,?,?,?,?,?,?,?,?,?,0,?,'pending','')
ON CONFLICT(library_id,relative_path) DO UPDATE SET
 id=excluded.id,folder_path=excluded.folder_path,file_name=excluded.file_name,
 media_type=excluded.media_type,mime_type=excluded.mime_type,size_bytes=excluded.size_bytes,
 captured_at=CASE WHEN media_items.modified_at<>excluded.modified_at THEN excluded.modified_at ELSE media_items.captured_at END,
 captured_at_source=CASE WHEN media_items.modified_at<>excluded.modified_at THEN 'modified' ELSE media_items.captured_at_source END,
 metadata_status=CASE WHEN media_items.modified_at<>excluded.modified_at THEN 'pending' ELSE media_items.metadata_status END,
 metadata_error=CASE WHEN media_items.modified_at<>excluded.modified_at THEN '' ELSE media_items.metadata_error END,
 modified_at=excluded.modified_at,missing=0,last_seen_scan=excluded.last_seen_scan"#,
    )
    .bind(id)
    .bind(&library.id)
    .bind(relative)
    .bind(folder)
    .bind(file_name)
    .bind(media_type)
    .bind(mime_type)
    .bind(size_bytes)
    .bind(modified_at)
    .bind(modified_at)
    .bind("modified")
    .bind(scan_id)
    .execute(&mut **tx)
    .await?;
    let now = Utc::now().to_rfc3339_opts(SecondsFormat::Nanos, true);
    sqlx::query(
        r#"INSERT INTO metadata_jobs(media_id,source_modified_at,status,attempts,last_error,created_at,updated_at)
VALUES(?,?,'pending',0,'',?,?)
ON CONFLICT(media_id) DO UPDATE SET
 source_modified_at=excluded.source_modified_at,
 status=CASE WHEN metadata_jobs.source_modified_at<>excluded.source_modified_at THEN 'pending' ELSE metadata_jobs.status END,
 attempts=CASE WHEN metadata_jobs.source_modified_at<>excluded.source_modified_at THEN 0 ELSE metadata_jobs.attempts END,
 last_error=CASE WHEN metadata_jobs.source_modified_at<>excluded.source_modified_at THEN '' ELSE metadata_jobs.last_error END,
 updated_at=excluded.updated_at"#,
    )
    .bind(id)
    .bind(modified_at)
    .bind(&now)
    .bind(&now)
    .execute(&mut **tx)
    .await?;
    sqlx::query(
        r#"INSERT INTO thumbnail_jobs(media_id,width,source_modified_at,status,attempts,last_error,created_at,updated_at)
VALUES(?,480,?,'pending',0,'',?,?)
ON CONFLICT(media_id,width) DO UPDATE SET
 source_modified_at=excluded.source_modified_at,
 status=CASE WHEN thumbnail_jobs.source_modified_at<>excluded.source_modified_at THEN 'pending' ELSE thumbnail_jobs.status END,
 attempts=CASE WHEN thumbnail_jobs.source_modified_at<>excluded.source_modified_at THEN 0 ELSE thumbnail_jobs.attempts END,
 last_error=CASE WHEN thumbnail_jobs.source_modified_at<>excluded.source_modified_at THEN '' ELSE thumbnail_jobs.last_error END,
 updated_at=excluded.updated_at"#,
    )
    .bind(id)
    .bind(modified_at)
    .bind(&now)
    .bind(&now)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

async fn upsert_folder(
    tx: &mut Transaction<'_, Sqlite>,
    library: &LibraryConfig,
    relative: &str,
    parent: &str,
    name: &str,
    scan_id: &str,
) -> Result<()> {
    sqlx::query(
        r#"INSERT INTO folders(id,library_id,relative_path,parent_path,name,missing,last_seen_scan)
VALUES(?,?,?,?,?,0,?)
ON CONFLICT(library_id,relative_path) DO UPDATE SET
 id=excluded.id,parent_path=excluded.parent_path,name=excluded.name,
 missing=0,last_seen_scan=excluded.last_seen_scan"#,
    )
    .bind(stable_id(&library.id, &format!("folder\0{relative}")))
    .bind(&library.id)
    .bind(relative)
    .bind(parent)
    .bind(name)
    .bind(scan_id)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

async fn upsert_single_path(state: &AppState, library: &LibraryConfig, path: &Path) -> Result<()> {
    if !path.exists() {
        return mark_missing(state, library, path).await;
    }
    if path.is_dir() {
        let _ = start_scan(state.clone()).await;
        return Ok(());
    }
    let Some((media_type, mime_type)) = media_type_for_path(path) else {
        return Ok(());
    };
    if !wait_for_stable_file(path).await {
        anyhow::bail!("文件仍在写入：{}", path.display());
    }
    let metadata = tokio::fs::metadata(path).await?;
    let relative = relative_path(&library.path, path)?;
    let folder = parent_folder(&relative);
    let modified_at = system_time(metadata.modified().unwrap_or(SystemTime::UNIX_EPOCH));
    let scan_id = random_id();
    let mut tx = state.store.pool().begin().await?;
    if !folder.is_empty() {
        let name = Path::new(&folder)
            .file_name()
            .map(|value| value.to_string_lossy().to_string())
            .unwrap_or_else(|| folder.clone());
        upsert_folder(
            &mut tx,
            library,
            &folder,
            &parent_folder(&folder),
            &name,
            &scan_id,
        )
        .await?;
    }
    upsert_media(
        &mut tx,
        library,
        &stable_id(&library.id, &relative),
        &relative,
        &folder,
        &path
            .file_name()
            .map(|value| value.to_string_lossy().to_string())
            .unwrap_or_default(),
        media_type,
        mime_type,
        i64::try_from(metadata.len()).unwrap_or(i64::MAX),
        &modified_at,
        &scan_id,
    )
    .await?;
    tx.commit().await?;
    state.runtime.thumbnail_notify.notify_waiters();
    state.runtime.metadata_notify.notify_waiters();
    Ok(())
}

async fn mark_missing(state: &AppState, library: &LibraryConfig, path: &Path) -> Result<()> {
    let relative = relative_path(&library.path, path)?;
    if relative.is_empty() {
        return Ok(());
    }
    let like = format!("{relative}/%");
    sqlx::query(
        "UPDATE media_items SET missing=1 WHERE library_id=? AND (relative_path=? OR relative_path LIKE ?)",
    )
    .bind(&library.id)
    .bind(&relative)
    .bind(&like)
    .execute(state.store.pool())
    .await?;
    sqlx::query(
        "UPDATE folders SET missing=1 WHERE library_id=? AND (relative_path=? OR relative_path LIKE ?)",
    )
    .bind(&library.id)
    .bind(&relative)
    .bind(&like)
    .execute(state.store.pool())
    .await?;
    Ok(())
}

pub fn start_watcher(state: AppState) -> Result<()> {
    let (sender, mut receiver) = mpsc::unbounded_channel();
    let callback_sender = sender.clone();
    let mut watcher: RecommendedWatcher =
        notify::recommended_watcher(move |result: notify::Result<notify::Event>| {
            let _ = callback_sender.send(result);
        })?;
    for library in state.libraries.values() {
        if !library.enabled || !library.path.is_dir() {
            continue;
        }
        let mode = if library.recursive {
            RecursiveMode::Recursive
        } else {
            RecursiveMode::NonRecursive
        };
        if let Err(error) = watcher.watch(&library.path, mode) {
            tracing::warn!(library = %library.id, %error, "无法监听媒体库");
        }
    }
    let runtime = state.runtime.clone();
    let mut shutdown = state.runtime.shutdown.subscribe();
    let handle = tokio::spawn(async move {
        let _watcher = watcher;
        let mut pending = HashMap::<PathBuf, Instant>::new();
        let mut ticker = interval(Duration::from_millis(400));
        loop {
            tokio::select! {
                changed = shutdown.changed() => {
                    if changed.is_err() || *shutdown.borrow() { break; }
                }
                event = receiver.recv() => {
                    match event {
                        Some(Ok(event)) => {
                            for path in event.paths { pending.insert(path, Instant::now()); }
                        }
                        Some(Err(error)) => tracing::warn!(%error, "文件监听错误"),
                        None => break,
                    }
                }
                _ = ticker.tick() => {
                    let now = Instant::now();
                    let ready = pending
                        .iter()
                        .filter(|(_, created)| now.duration_since(**created) >= Duration::from_millis(1200))
                        .map(|(path, _)| path.clone())
                        .collect::<Vec<_>>();
                    for path in ready {
                        pending.remove(&path);
                        let Some(library) = state.library_for_path(&path) else { continue; };
                        if let Err(error) = upsert_single_path(&state, &library, &path).await {
                            tracing::debug!(path = %path.display(), %error, "处理文件变化失败");
                        }
                    }
                }
            }
        }
    });
    runtime.track(handle);
    Ok(())
}

async fn wait_for_stable_file(path: &Path) -> bool {
    let mut previous = None;
    for _ in 0..5 {
        let Ok(metadata) = tokio::fs::metadata(path).await else {
            return false;
        };
        if metadata.is_dir() {
            return false;
        }
        let current = (metadata.len(), metadata.modified().ok());
        if previous == Some(current) {
            return true;
        }
        previous = Some(current);
        sleep(Duration::from_millis(650)).await;
    }
    false
}

fn relative_path(root: &Path, path: &Path) -> Result<String> {
    let relative = path
        .strip_prefix(root)
        .with_context(|| format!("{} 不在媒体库 {} 内", path.display(), root.display()))?;
    Ok(relative
        .to_string_lossy()
        .replace('\\', "/")
        .trim_matches('/')
        .to_string())
}

fn parent_folder(relative: &str) -> String {
    relative
        .rsplit_once('/')
        .map_or_else(String::new, |(parent, _)| parent.to_string())
}

fn system_time(value: SystemTime) -> String {
    DateTime::<Utc>::from(value).to_rfc3339_opts(SecondsFormat::Nanos, true)
}
