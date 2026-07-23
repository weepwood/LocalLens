#[cfg(target_os = "windows")]
use std::process::Command;

use local_lens_core::{Album, FolderInfo, MediaItem, Tag};
use serde::{Deserialize, Serialize};
use tauri::State;

use crate::RuntimeState;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MediaCollections {
    album_ids: Vec<String>,
    tag_ids: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct BatchMediaRequest {
    ids: Vec<String>,
    favorite: Option<bool>,
    rating: Option<i64>,
    album_id: Option<String>,
    tag_id: Option<String>,
    #[serde(default = "default_true")]
    add_to_collection: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct BatchMediaResult {
    updated: usize,
    failed: Vec<String>,
}

fn default_true() -> bool {
    true
}

#[tauri::command]
pub(crate) async fn desktop_folders(
    state: State<'_, RuntimeState>,
    library_id: String,
    parent: String,
) -> Result<Vec<FolderInfo>, String> {
    let current = state.current().await?;
    current
        .store
        .folders(library_id.trim(), parent.trim_matches('/'))
        .await
        .map_err(|error| error.to_string())
}

#[tauri::command]
pub(crate) async fn desktop_albums(state: State<'_, RuntimeState>) -> Result<Vec<Album>, String> {
    let current = state.current().await?;
    current
        .store
        .albums()
        .await
        .map_err(|error| error.to_string())
}

#[tauri::command]
pub(crate) async fn desktop_create_album(
    state: State<'_, RuntimeState>,
    name: String,
    description: String,
) -> Result<Album, String> {
    let current = state.current().await?;
    current
        .store
        .create_album(&name, &description)
        .await
        .map_err(|error| error.to_string())
}

#[tauri::command]
pub(crate) async fn desktop_delete_album(
    state: State<'_, RuntimeState>,
    id: String,
) -> Result<(), String> {
    let current = state.current().await?;
    if current
        .store
        .delete_album(&id)
        .await
        .map_err(|error| error.to_string())?
    {
        Ok(())
    } else {
        Err("相册不存在".into())
    }
}

#[tauri::command]
pub(crate) async fn desktop_tags(state: State<'_, RuntimeState>) -> Result<Vec<Tag>, String> {
    let current = state.current().await?;
    current
        .store
        .tags()
        .await
        .map_err(|error| error.to_string())
}

#[tauri::command]
pub(crate) async fn desktop_create_tag(
    state: State<'_, RuntimeState>,
    name: String,
    color: String,
) -> Result<Tag, String> {
    let current = state.current().await?;
    current
        .store
        .create_tag(&name, &color)
        .await
        .map_err(|error| error.to_string())
}

#[tauri::command]
pub(crate) async fn desktop_delete_tag(
    state: State<'_, RuntimeState>,
    id: String,
) -> Result<(), String> {
    let current = state.current().await?;
    if current
        .store
        .delete_tag(&id)
        .await
        .map_err(|error| error.to_string())?
    {
        Ok(())
    } else {
        Err("标签不存在".into())
    }
}

#[tauri::command]
pub(crate) async fn desktop_media_collections(
    state: State<'_, RuntimeState>,
    id: String,
) -> Result<MediaCollections, String> {
    let current = state.current().await?;
    let (album_ids, tag_ids) = current
        .store
        .media_collections(&id)
        .await
        .map_err(|error| error.to_string())?;
    Ok(MediaCollections { album_ids, tag_ids })
}

#[tauri::command]
pub(crate) async fn desktop_set_album_item(
    state: State<'_, RuntimeState>,
    album_id: String,
    media_id: String,
    add: bool,
) -> Result<(), String> {
    let current = state.current().await?;
    current
        .store
        .set_album_item(&album_id, &media_id, add)
        .await
        .map_err(|error| error.to_string())
}

#[tauri::command]
pub(crate) async fn desktop_set_media_tag(
    state: State<'_, RuntimeState>,
    media_id: String,
    tag_id: String,
    add: bool,
) -> Result<(), String> {
    let current = state.current().await?;
    current
        .store
        .set_media_tag(&media_id, &tag_id, add)
        .await
        .map_err(|error| error.to_string())
}

#[tauri::command]
pub(crate) async fn desktop_batch_update(
    state: State<'_, RuntimeState>,
    request: BatchMediaRequest,
) -> Result<BatchMediaResult, String> {
    if request.ids.is_empty() {
        return Err("请先选择媒体".into());
    }
    if request.ids.len() > 500 {
        return Err("单次最多处理 500 个媒体文件".into());
    }
    if request.favorite.is_none()
        && request.rating.is_none()
        && request.album_id.as_deref().unwrap_or_default().is_empty()
        && request.tag_id.as_deref().unwrap_or_default().is_empty()
    {
        return Err("没有可执行的批量操作".into());
    }

    let current = state.current().await?;
    let mut updated = 0;
    let mut failed = Vec::new();

    for id in request.ids.iter().cloned() {
        let result = async {
            let media = current
                .store
                .media_by_id(&id)
                .await?
                .ok_or_else(|| anyhow::anyhow!("媒体不存在"))?;
            apply_media_updates(&current, &media, &request).await
        }
        .await;

        match result {
            Ok(()) => updated += 1,
            Err(error) => failed.push(format!("{id}: {error}")),
        }
    }

    Ok(BatchMediaResult { updated, failed })
}

async fn apply_media_updates(
    current: &local_lens_server::AppState,
    media: &MediaItem,
    request: &BatchMediaRequest,
) -> anyhow::Result<()> {
    if let Some(favorite) = request.favorite {
        current.store.set_favorite(&media.id, favorite).await?;
    }
    if let Some(rating) = request.rating {
        current.store.set_rating(&media.id, rating).await?;
    }
    if let Some(album_id) = request
        .album_id
        .as_deref()
        .filter(|value| !value.trim().is_empty())
    {
        current
            .store
            .set_album_item(album_id.trim(), &media.id, request.add_to_collection)
            .await?;
    }
    if let Some(tag_id) = request
        .tag_id
        .as_deref()
        .filter(|value| !value.trim().is_empty())
    {
        current
            .store
            .set_media_tag(&media.id, tag_id.trim(), request.add_to_collection)
            .await?;
    }
    Ok(())
}

#[tauri::command]
pub(crate) async fn desktop_reveal_media(
    state: State<'_, RuntimeState>,
    id: String,
) -> Result<(), String> {
    let current = state.current().await?;
    let media = current
        .store
        .media_by_id(&id)
        .await
        .map_err(|error| error.to_string())?
        .ok_or_else(|| "媒体不存在".to_string())?;
    let path = current
        .media_path(&media)
        .ok_or_else(|| "媒体路径不安全".to_string())?;

    #[cfg(target_os = "windows")]
    {
        Command::new("explorer.exe")
            .arg(format!("/select,{}", path.display()))
            .spawn()
            .map_err(|error| format!("打开资源管理器失败：{error}"))?;
        Ok(())
    }

    #[cfg(not(target_os = "windows"))]
    {
        let _ = path;
        Err("当前功能仅支持 Windows".into())
    }
}
