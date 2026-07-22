use std::{path::{Path, PathBuf}, time::Duration};

use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sqlx::{sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions}, Row, SqlitePool};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppConfig {
    #[serde(default = "default_listen_address")]
    pub listen_address: String,
    #[serde(default)]
    pub public_url: String,
    #[serde(default = "default_server_name")]
    pub server_name: String,
    #[serde(default = "default_data_dir")]
    pub data_dir: PathBuf,
    #[serde(default)]
    pub api_token: String,
    #[serde(default)]
    pub ffmpeg_path: PathBuf,
    #[serde(default)]
    pub ffprobe_path: PathBuf,
    #[serde(default = "default_true")]
    pub auto_scan: bool,
    #[serde(default = "default_true")]
    pub watch_files: bool,
    #[serde(default = "default_workers")]
    pub thumbnail_workers: usize,
    #[serde(default = "default_workers")]
    pub metadata_workers: usize,
    #[serde(default = "default_pairing_ttl")]
    pub pairing_ttl_minutes: u64,
    #[serde(default)]
    pub libraries: Vec<LibraryConfig>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LibraryConfig {
    pub id: String,
    pub name: String,
    pub path: PathBuf,
    #[serde(default = "default_true")]
    pub recursive: bool,
    #[serde(default = "default_true")]
    pub enabled: bool,
}

impl AppConfig {
    pub fn load(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref();
        let content = std::fs::read_to_string(path)
            .with_context(|| format!("无法读取配置文件：{}", path.display()))?;
        let mut config: Self = serde_json::from_str(&content)
            .with_context(|| format!("无法解析配置文件：{}", path.display()))?;
        if config.api_token.trim().len() < 16 {
            anyhow::bail!("api_token 至少需要 16 个字符");
        }
        if config.public_url.trim().is_empty() {
            config.public_url = format!("http://{}", config.listen_address.replace("0.0.0.0", "127.0.0.1"));
        }
        Ok(config)
    }

    pub fn save(&self, path: impl AsRef<Path>) -> Result<()> {
        let path = path.as_ref();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(path, serde_json::to_string_pretty(self)?)?;
        Ok(())
    }
}

fn default_listen_address() -> String { "0.0.0.0:9527".into() }
fn default_server_name() -> String { "LocalLens".into() }
fn default_data_dir() -> PathBuf { PathBuf::from("./data") }
fn default_true() -> bool { true }
fn default_workers() -> usize { 2 }
fn default_pairing_ttl() -> u64 { 5 }

#[derive(Debug, Clone)]
pub struct Store {
    pool: SqlitePool,
}

impl Store {
    pub async fn open(data_dir: impl AsRef<Path>) -> Result<Self> {
        let data_dir = data_dir.as_ref();
        tokio::fs::create_dir_all(data_dir).await?;
        let path = data_dir.join("locallens.db");
        let options = SqliteConnectOptions::new()
            .filename(&path)
            .create_if_missing(true)
            .journal_mode(SqliteJournalMode::Wal)
            .foreign_keys(true)
            .busy_timeout(Duration::from_secs(15));
        let pool = SqlitePoolOptions::new()
            .max_connections(8)
            .connect_with(options)
            .await
            .with_context(|| format!("无法打开 SQLite：{}", path.display()))?;
        let store = Self { pool };
        store.ensure_compatible_schema().await?;
        Ok(store)
    }

    pub fn pool(&self) -> &SqlitePool { &self.pool }

    async fn ensure_compatible_schema(&self) -> Result<()> {
        sqlx::query(
            r#"
CREATE TABLE IF NOT EXISTS libraries (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  root_path TEXT NOT NULL UNIQUE,
  recursive INTEGER NOT NULL,
  enabled INTEGER NOT NULL,
  last_scanned_at TEXT
);
CREATE TABLE IF NOT EXISTS media_items (
  id TEXT PRIMARY KEY,
  library_id TEXT NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
  relative_path TEXT NOT NULL,
  file_name TEXT NOT NULL,
  media_type TEXT NOT NULL,
  mime_type TEXT NOT NULL,
  size_bytes INTEGER NOT NULL,
  modified_at TEXT NOT NULL,
  missing INTEGER NOT NULL DEFAULT 0,
  last_seen_scan TEXT NOT NULL,
  favorite INTEGER NOT NULL DEFAULT 0,
  folder_path TEXT NOT NULL DEFAULT '',
  captured_at TEXT,
  captured_at_source TEXT NOT NULL DEFAULT 'modified',
  width INTEGER NOT NULL DEFAULT 0,
  height INTEGER NOT NULL DEFAULT 0,
  duration_ms INTEGER NOT NULL DEFAULT 0,
  codec TEXT NOT NULL DEFAULT '',
  latitude REAL,
  longitude REAL,
  camera_model TEXT NOT NULL DEFAULT '',
  metadata_status TEXT NOT NULL DEFAULT 'pending',
  metadata_error TEXT NOT NULL DEFAULT '',
  rating INTEGER NOT NULL DEFAULT 0,
  UNIQUE(library_id, relative_path)
);
CREATE INDEX IF NOT EXISTS idx_media_rust_timeline
  ON media_items(captured_at DESC, id DESC);
"#,
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn sync_libraries(&self, libraries: &[LibraryConfig]) -> Result<()> {
        let mut tx = self.pool.begin().await?;
        for library in libraries {
            sqlx::query(
                r#"INSERT INTO libraries(id,name,root_path,recursive,enabled)
VALUES(?,?,?,?,?)
ON CONFLICT(id) DO UPDATE SET
  name=excluded.name,
  root_path=excluded.root_path,
  recursive=excluded.recursive,
  enabled=excluded.enabled"#,
            )
            .bind(&library.id)
            .bind(&library.name)
            .bind(library.path.to_string_lossy().to_string())
            .bind(library.recursive)
            .bind(library.enabled)
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await?;
        Ok(())
    }

    pub async fn libraries(&self) -> Result<Vec<LibraryInfo>> {
        let rows = sqlx::query(
            r#"SELECT l.id,l.name,l.recursive,l.enabled,l.last_scanned_at,
COALESCE(SUM(CASE WHEN m.missing=0 THEN 1 ELSE 0 END),0) media_count
FROM libraries l LEFT JOIN media_items m ON m.library_id=l.id
GROUP BY l.id,l.name,l.recursive,l.enabled,l.last_scanned_at
ORDER BY l.name"#,
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.into_iter().map(|row| LibraryInfo {
            id: row.get("id"),
            name: row.get("name"),
            recursive: row.get::<i64, _>("recursive") != 0,
            enabled: row.get::<i64, _>("enabled") != 0,
            last_scanned_at: row.try_get("last_scanned_at").ok(),
            media_count: row.get("media_count"),
        }).collect())
    }

    pub async fn stats(&self) -> Result<MediaStats> {
        let row = sqlx::query(
            r#"SELECT COUNT(*) total,
COALESCE(SUM(CASE WHEN media_type='image' THEN 1 ELSE 0 END),0) images,
COALESCE(SUM(CASE WHEN media_type='video' THEN 1 ELSE 0 END),0) videos,
COALESCE(SUM(CASE WHEN favorite=1 THEN 1 ELSE 0 END),0) favorites,
COALESCE(SUM(size_bytes),0) size_bytes,
COALESCE(SUM(CASE WHEN metadata_status='pending' THEN 1 ELSE 0 END),0) metadata_pending
FROM media_items WHERE missing=0"#,
        ).fetch_one(&self.pool).await?;
        Ok(MediaStats {
            total: row.get("total"), images: row.get("images"), videos: row.get("videos"),
            favorites: row.get("favorites"), size_bytes: row.get("size_bytes"),
            metadata_pending: row.get("metadata_pending"), thumbnails_pending: 0,
        })
    }

    pub async fn media_page(&self, query: &MediaQuery) -> Result<MediaPage> {
        let limit = query.limit.clamp(1, 200);
        let offset = query.cursor.as_deref().and_then(|value| value.parse::<i64>().ok()).unwrap_or(query.offset.max(0));
        let kind = query.kind.as_deref().unwrap_or("");
        let search = query.search.as_deref().unwrap_or("");
        let pattern = format!("%{}%", search);
        let rows = sqlx::query(
            r#"SELECT * FROM media_items
WHERE missing=0
  AND (?='' OR media_type=?)
  AND (?='' OR file_name LIKE ? OR relative_path LIKE ?)
  AND (?=0 OR favorite=1)
ORDER BY COALESCE(captured_at,modified_at) DESC,id DESC
LIMIT ? OFFSET ?"#,
        )
        .bind(kind).bind(kind)
        .bind(search).bind(&pattern).bind(&pattern)
        .bind(query.favorite)
        .bind(limit + 1).bind(offset)
        .fetch_all(&self.pool).await?;
        let has_more = rows.len() as i64 > limit;
        let items = rows.into_iter().take(limit as usize).map(media_from_row).collect::<Result<Vec<_>>>()?;
        let total: i64 = sqlx::query_scalar(
            r#"SELECT COUNT(*) FROM media_items
WHERE missing=0
  AND (?='' OR media_type=?)
  AND (?='' OR file_name LIKE ? OR relative_path LIKE ?)
  AND (?=0 OR favorite=1)"#,
        )
        .bind(kind).bind(kind)
        .bind(search).bind(&pattern).bind(&pattern)
        .bind(query.favorite)
        .fetch_one(&self.pool).await?;
        Ok(MediaPage {
            items, total, limit, offset,
            next_cursor: has_more.then(|| (offset + limit).to_string()),
            has_more,
        })
    }

    pub async fn media_by_id(&self, id: &str) -> Result<Option<MediaItem>> {
        let row = sqlx::query("SELECT * FROM media_items WHERE id=? AND missing=0")
            .bind(id).fetch_optional(&self.pool).await?;
        row.map(media_from_row).transpose()
    }

    pub async fn set_favorite(&self, id: &str, favorite: bool) -> Result<Option<MediaItem>> {
        sqlx::query("UPDATE media_items SET favorite=? WHERE id=?")
            .bind(favorite).bind(id).execute(&self.pool).await?;
        self.media_by_id(id).await
    }

    pub async fn set_rating(&self, id: &str, rating: i64) -> Result<Option<MediaItem>> {
        let rating = rating.clamp(0, 5);
        sqlx::query("UPDATE media_items SET rating=? WHERE id=?")
            .bind(rating).bind(id).execute(&self.pool).await?;
        self.media_by_id(id).await
    }
}

fn media_from_row(row: sqlx::sqlite::SqliteRow) -> Result<MediaItem> {
    let id: String = row.get("id");
    Ok(MediaItem {
        thumbnail_url: format!("/api/v1/media/{id}/thumbnail?width=480"),
        original_url: format!("/api/v1/media/{id}/original"),
        stream_url: format!("/api/v1/media/{id}/stream"),
        id,
        library_id: row.get("library_id"), relative_path: row.get("relative_path"),
        folder_path: row.get("folder_path"), file_name: row.get("file_name"),
        media_type: row.get("media_type"), mime_type: row.get("mime_type"),
        size_bytes: row.get("size_bytes"), modified_at: row.get("modified_at"),
        captured_at: row.try_get::<Option<String>, _>("captured_at")?.unwrap_or_default(),
        captured_at_source: row.get("captured_at_source"), width: row.get("width"), height: row.get("height"),
        duration_ms: row.get("duration_ms"), codec: row.get("codec"),
        latitude: row.try_get("latitude")?, longitude: row.try_get("longitude")?,
        camera_model: row.get("camera_model"), metadata_status: row.get("metadata_status"),
        metadata_error: row.get("metadata_error"), favorite: row.get::<i64, _>("favorite") != 0,
        rating: row.get("rating"),
    })
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LibraryInfo {
    pub id: String,
    pub name: String,
    pub recursive: bool,
    pub enabled: bool,
    pub last_scanned_at: Option<String>,
    pub media_count: i64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaStats {
    pub total: i64,
    pub images: i64,
    pub videos: i64,
    pub favorites: i64,
    pub size_bytes: i64,
    pub metadata_pending: i64,
    pub thumbnails_pending: i64,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct MediaQuery {
    #[serde(rename = "type")]
    pub kind: Option<String>,
    #[serde(rename = "q")]
    pub search: Option<String>,
    #[serde(default)]
    pub favorite: bool,
    #[serde(default = "default_limit")]
    pub limit: i64,
    #[serde(default)]
    pub offset: i64,
    pub cursor: Option<String>,
}
fn default_limit() -> i64 { 100 }

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaPage {
    pub items: Vec<MediaItem>,
    pub total: i64,
    pub limit: i64,
    pub offset: i64,
    pub next_cursor: Option<String>,
    pub has_more: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaItem {
    pub id: String,
    pub library_id: String,
    pub relative_path: String,
    pub folder_path: String,
    pub file_name: String,
    #[serde(rename = "type")]
    pub media_type: String,
    pub mime_type: String,
    pub size_bytes: i64,
    pub modified_at: String,
    pub captured_at: String,
    pub captured_at_source: String,
    pub width: i64,
    pub height: i64,
    pub duration_ms: i64,
    pub codec: String,
    pub latitude: Option<f64>,
    pub longitude: Option<f64>,
    pub camera_model: String,
    pub metadata_status: String,
    pub metadata_error: String,
    pub favorite: bool,
    pub rating: i64,
    pub thumbnail_url: String,
    pub original_url: String,
    pub stream_url: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerInfo {
    pub name: String,
    pub version: String,
    pub api_version: String,
    pub capabilities: Vec<&'static str>,
}

#[derive(Debug, Clone, Serialize)]
pub struct HealthResponse {
    pub status: &'static str,
    pub timestamp: DateTime<Utc>,
}
