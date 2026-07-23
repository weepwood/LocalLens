use anyhow::{Context, Result};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use serde::{Deserialize, Serialize};
use sqlx::{QueryBuilder, Row, Sqlite, sqlite::SqliteRow};

use crate::{FolderInfo, MediaItem, MediaPage, MediaQuery};

use super::Store;

impl Store {
    pub async fn media_page(&self, query: &MediaQuery) -> Result<MediaPage> {
        let limit = query.limit.clamp(1, 200);
        let mut offset = query.offset.max(0);
        let sort = query.sort.as_deref().unwrap_or("timeline");
        let sort_expression = if sort == "modified" {
            "m.modified_at"
        } else {
            "COALESCE(NULLIF(m.captured_at,''),m.modified_at)"
        };

        let mut count =
            QueryBuilder::<Sqlite>::new("SELECT COUNT(*) FROM media_items m WHERE m.missing=0");
        push_media_filters(&mut count, query);
        let total = count
            .build_query_scalar::<i64>()
            .fetch_one(&self.pool)
            .await?;

        let mut list = QueryBuilder::<Sqlite>::new(MEDIA_SELECT);
        list.push(" WHERE m.missing=0");
        push_media_filters(&mut list, query);

        if sort != "name" {
            if let Some(cursor_value) = query
                .cursor
                .as_deref()
                .filter(|value| !value.trim().is_empty())
            {
                let cursor = decode_cursor(cursor_value)?;
                list.push(" AND (")
                    .push(sort_expression)
                    .push(" < ")
                    .push_bind(cursor.sort_at.clone())
                    .push(" OR (")
                    .push(sort_expression)
                    .push(" = ")
                    .push_bind(cursor.sort_at)
                    .push(" AND m.id < ")
                    .push_bind(cursor.id)
                    .push("))");
                offset = 0;
            }
        }

        match sort {
            "name" => list.push(" ORDER BY m.file_name COLLATE NOCASE ASC,m.id ASC"),
            "modified" => list.push(" ORDER BY m.modified_at DESC,m.id DESC"),
            _ => list
                .push(" ORDER BY COALESCE(NULLIF(m.captured_at,''),m.modified_at) DESC,m.id DESC"),
        };
        list.push(" LIMIT ").push_bind(limit + 1);
        if query.cursor.as_deref().unwrap_or_default().is_empty() && offset > 0 {
            list.push(" OFFSET ").push_bind(offset);
        }

        let rows = list.build().fetch_all(&self.pool).await?;
        let has_more = rows.len() as i64 > limit;
        let mut items = rows
            .into_iter()
            .take(limit as usize)
            .map(media_from_row)
            .collect::<Result<Vec<_>>>()?;
        let next_cursor = if has_more && sort != "name" {
            items
                .last()
                .map(|item| encode_cursor(item, sort))
                .transpose()?
        } else {
            None
        };
        items.shrink_to_fit();
        Ok(MediaPage {
            items,
            total,
            limit,
            offset,
            next_cursor,
            has_more,
        })
    }

    pub async fn media_by_id(&self, id: &str) -> Result<Option<MediaItem>> {
        let row = sqlx::query(&format!("{MEDIA_SELECT} WHERE m.id=? AND m.missing=0"))
            .bind(id)
            .fetch_optional(&self.pool)
            .await?;
        row.map(media_from_row).transpose()
    }

    pub async fn set_favorite(&self, id: &str, favorite: bool) -> Result<Option<MediaItem>> {
        sqlx::query("UPDATE media_items SET favorite=? WHERE id=? AND missing=0")
            .bind(favorite)
            .bind(id)
            .execute(&self.pool)
            .await?;
        self.media_by_id(id).await
    }

    pub async fn set_rating(&self, id: &str, rating: i64) -> Result<Option<MediaItem>> {
        if !(0..=5).contains(&rating) {
            anyhow::bail!("rating 必须在 0 到 5 之间");
        }
        sqlx::query("UPDATE media_items SET rating=? WHERE id=? AND missing=0")
            .bind(rating)
            .bind(id)
            .execute(&self.pool)
            .await?;
        self.media_by_id(id).await
    }

    pub async fn folders(&self, library_id: &str, parent: &str) -> Result<Vec<FolderInfo>> {
        let rows = sqlx::query(
            r#"SELECT f.id,f.library_id,f.relative_path,f.parent_path,f.name,
(SELECT COUNT(*) FROM media_items m WHERE m.library_id=f.library_id AND m.folder_path=f.relative_path AND m.missing=0) media_count,
(SELECT COUNT(*) FROM folders c WHERE c.library_id=f.library_id AND c.parent_path=f.relative_path AND c.missing=0) child_count
FROM folders f
WHERE f.library_id=? AND f.parent_path=? AND f.relative_path<>'' AND f.missing=0
ORDER BY f.name COLLATE NOCASE"#,
        )
        .bind(library_id)
        .bind(parent)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|row| FolderInfo {
                id: row.get("id"),
                library_id: row.get("library_id"),
                path: row.get("relative_path"),
                parent_path: row.get("parent_path"),
                name: row.get("name"),
                media_count: row.get("media_count"),
                child_count: row.get("child_count"),
            })
            .collect())
    }
}

const MEDIA_SELECT: &str = r#"SELECT
m.id,m.library_id,m.relative_path,m.folder_path,m.file_name,
m.media_type,m.mime_type,m.size_bytes,m.modified_at,m.captured_at,
m.captured_at_source,m.width,m.height,m.duration_ms,m.codec,
m.latitude,m.longitude,m.camera_model,m.metadata_status,m.metadata_error,
m.favorite,m.rating
FROM media_items m"#;

fn push_media_filters<'a>(builder: &mut QueryBuilder<'a, Sqlite>, query: &'a MediaQuery) {
    if let Some(kind) = query
        .kind
        .as_deref()
        .filter(|value| matches!(*value, "image" | "video"))
    {
        builder.push(" AND m.media_type=").push_bind(kind);
    }
    if let Some(library_id) = query
        .library_id
        .as_deref()
        .filter(|value| !value.trim().is_empty())
    {
        builder
            .push(" AND m.library_id=")
            .push_bind(library_id.trim());
    }
    if let Some(folder) = query.folder.as_deref() {
        let folder = folder.trim_matches('/');
        if query.recursive && !folder.is_empty() {
            builder
                .push(" AND (m.folder_path=")
                .push_bind(folder.to_string())
                .push(" OR m.folder_path LIKE ")
                .push_bind(format!("{folder}/%"))
                .push(")");
        } else {
            builder
                .push(" AND m.folder_path=")
                .push_bind(folder.to_string());
        }
    }
    if let Some(search) = query
        .search
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        let pattern = format!("%{search}%");
        builder
            .push(" AND (m.file_name LIKE ")
            .push_bind(pattern.clone())
            .push(" OR m.relative_path LIKE ")
            .push_bind(pattern)
            .push(")");
    }
    if query.favorite {
        builder.push(" AND m.favorite=1");
    }
    if query.min_rating > 0 {
        builder
            .push(" AND m.rating>=")
            .push_bind(query.min_rating.clamp(1, 5));
    }
    if let Some(album_id) = query
        .album_id
        .as_deref()
        .filter(|value| !value.trim().is_empty())
    {
        builder
            .push(
                " AND EXISTS(SELECT 1 FROM album_items ai WHERE ai.media_id=m.id AND ai.album_id=",
            )
            .push_bind(album_id.trim())
            .push(")");
    }
    if let Some(tag_id) = query
        .tag_id
        .as_deref()
        .filter(|value| !value.trim().is_empty())
    {
        builder
            .push(" AND EXISTS(SELECT 1 FROM media_tags mt WHERE mt.media_id=m.id AND mt.tag_id=")
            .push_bind(tag_id.trim())
            .push(")");
    }
}

fn media_from_row(row: SqliteRow) -> Result<MediaItem> {
    let id: String = row.get("id");
    let modified_at: String = row.get("modified_at");
    let captured_at = row
        .try_get::<Option<String>, _>("captured_at")?
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| modified_at.clone());
    Ok(MediaItem {
        thumbnail_url: format!("/api/v1/media/{id}/thumbnail?width=480"),
        original_url: format!("/api/v1/media/{id}/original"),
        stream_url: format!("/api/v1/media/{id}/stream"),
        id,
        library_id: row.get("library_id"),
        relative_path: row.get("relative_path"),
        folder_path: row.get("folder_path"),
        file_name: row.get("file_name"),
        media_type: row.get("media_type"),
        mime_type: row.get("mime_type"),
        size_bytes: row.get("size_bytes"),
        modified_at,
        captured_at,
        captured_at_source: row.get("captured_at_source"),
        width: row.get("width"),
        height: row.get("height"),
        duration_ms: row.get("duration_ms"),
        codec: row.get("codec"),
        latitude: row.try_get("latitude")?,
        longitude: row.try_get("longitude")?,
        camera_model: row.get("camera_model"),
        metadata_status: row.get("metadata_status"),
        metadata_error: row.get("metadata_error"),
        favorite: row.get::<i64, _>("favorite") != 0,
        rating: row.get("rating"),
    })
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct MediaCursor {
    sort_at: String,
    id: String,
}

fn encode_cursor(item: &MediaItem, sort: &str) -> Result<String> {
    let sort_at = if sort == "modified" {
        item.modified_at.clone()
    } else {
        item.captured_at.clone()
    };
    Ok(URL_SAFE_NO_PAD.encode(serde_json::to_vec(&MediaCursor {
        sort_at,
        id: item.id.clone(),
    })?))
}

fn decode_cursor(value: &str) -> Result<MediaCursor> {
    let bytes = URL_SAFE_NO_PAD
        .decode(value)
        .context("invalid cursor encoding")?;
    let cursor: MediaCursor = serde_json::from_slice(&bytes).context("invalid cursor payload")?;
    if cursor.id.is_empty() || cursor.sort_at.is_empty() {
        anyhow::bail!("invalid cursor fields");
    }
    Ok(cursor)
}
