mod collections;
mod jobs;
mod media;
mod schema;

use std::{path::Path, time::Duration};

use anyhow::{Context, Result};
use chrono::Utc;
use sqlx::{
    Row, SqlitePool,
    sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions},
};

use crate::{LibraryConfig, LibraryInfo, MediaStats};

const RUST_MIGRATION_MARKER: &str = ".rust-backend-migration-v1";

#[derive(Debug, Clone)]
pub struct Store {
    pool: SqlitePool,
}

impl Store {
    pub async fn open(data_dir: impl AsRef<Path>) -> Result<Self> {
        let data_dir = data_dir.as_ref();
        tokio::fs::create_dir_all(data_dir).await?;
        let path = data_dir.join("locallens.db");
        backup_before_first_rust_migration(data_dir, &path).await?;
        let options = SqliteConnectOptions::new()
            .filename(&path)
            .create_if_missing(true)
            .journal_mode(SqliteJournalMode::Wal)
            .foreign_keys(true)
            .busy_timeout(Duration::from_secs(15));
        let pool = SqlitePoolOptions::new()
            .max_connections(8)
            .min_connections(1)
            .connect_with(options)
            .await
            .with_context(|| format!("无法打开 SQLite：{}", path.display()))?;
        let store = Self { pool };
        store.ensure_compatible_schema().await?;
        store.reset_running_jobs().await?;
        tokio::fs::write(
            data_dir.join(RUST_MIGRATION_MARKER),
            Utc::now().to_rfc3339(),
        )
        .await?;
        Ok(store)
    }

    pub fn pool(&self) -> &SqlitePool {
        &self.pool
    }

    pub async fn reset_running_jobs(&self) -> Result<()> {
        sqlx::query(
            "UPDATE thumbnail_jobs SET status='pending' WHERE status IN ('running','native_running')",
        )
        .execute(&self.pool)
        .await?;
        sqlx::query("UPDATE metadata_jobs SET status='pending' WHERE status='running'")
            .execute(&self.pool)
            .await?;
        sqlx::query("UPDATE transcode_jobs SET status='pending',progress=0 WHERE status='running'")
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
 name=excluded.name,root_path=excluded.root_path,
 recursive=excluded.recursive,enabled=excluded.enabled"#,
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
        Ok(rows
            .into_iter()
            .map(|row| LibraryInfo {
                id: row.get("id"),
                name: row.get("name"),
                recursive: row.get::<i64, _>("recursive") != 0,
                enabled: row.get::<i64, _>("enabled") != 0,
                last_scanned_at: row
                    .try_get::<Option<String>, _>("last_scanned_at")
                    .ok()
                    .flatten(),
                media_count: row.get("media_count"),
            })
            .collect())
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
        )
        .fetch_one(&self.pool)
        .await?;
        let thumbnails_pending = sqlx::query_scalar::<_, i64>(
            "SELECT COUNT(*) FROM thumbnail_jobs WHERE status IN ('pending','native_pending','running','native_running')",
        )
        .fetch_one(&self.pool)
        .await?;
        let transcodes_pending = sqlx::query_scalar::<_, i64>(
            "SELECT COUNT(*) FROM transcode_jobs WHERE status IN ('pending','running')",
        )
        .fetch_one(&self.pool)
        .await?;
        Ok(MediaStats {
            total: row.get("total"),
            images: row.get("images"),
            videos: row.get("videos"),
            favorites: row.get("favorites"),
            size_bytes: row.get("size_bytes"),
            metadata_pending: row.get("metadata_pending"),
            thumbnails_pending,
            transcodes_pending,
        })
    }
}

async fn backup_before_first_rust_migration(data_dir: &Path, database: &Path) -> Result<()> {
    if !database.is_file() || data_dir.join(RUST_MIGRATION_MARKER).is_file() {
        return Ok(());
    }
    let backup_dir = data_dir.join("backups");
    tokio::fs::create_dir_all(&backup_dir).await?;
    let stamp = Utc::now().format("%Y%m%d-%H%M%S");
    let base = backup_dir.join(format!("locallens-before-rust-{stamp}.db"));
    tokio::fs::copy(database, &base)
        .await
        .with_context(|| format!("无法备份数据库到 {}", base.display()))?;
    for suffix in ["-wal", "-shm"] {
        let source = data_dir.join(format!("locallens.db{suffix}"));
        if source.is_file() {
            let target = backup_dir.join(format!("locallens-before-rust-{stamp}.db{suffix}"));
            tokio::fs::copy(source, target).await?;
        }
    }
    Ok(())
}
