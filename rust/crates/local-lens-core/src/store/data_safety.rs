use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use tokio::io::AsyncReadExt;

use super::Store;

const BACKUP_FORMAT_VERSION: u32 = 1;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DatabaseHealth {
    pub status: String,
    pub quick_check: String,
    pub foreign_key_violations: i64,
    pub database_size_bytes: u64,
    pub wal_size_bytes: u64,
    pub database_path: String,
    pub checked_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BackupSnapshot {
    pub id: String,
    pub created_at: String,
    pub path: String,
    pub database_size_bytes: u64,
    pub database_sha256: String,
    pub verified: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct BackupManifest {
    format_version: u32,
    app_version: String,
    id: String,
    created_at: String,
    database_file: String,
    config_file: Option<String>,
    database_size_bytes: u64,
    database_sha256: String,
    database_quick_check: String,
}

impl Store {
    pub async fn verify_database_integrity(&self) -> Result<()> {
        let quick_check = quick_check_pool(&self.pool).await?;
        if quick_check.eq_ignore_ascii_case("ok") {
            return Ok(());
        }
        bail!("SQLite quick_check 失败：{quick_check}")
    }

    pub async fn database_health(&self) -> Result<DatabaseHealth> {
        let quick_check = quick_check_pool(&self.pool).await?;
        let foreign_key_violations = sqlx::query("PRAGMA foreign_key_check")
            .fetch_all(&self.pool)
            .await
            .context("无法执行 SQLite foreign_key_check")?
            .len() as i64;
        let database_size_bytes = file_size(&self.database_path).await;
        let wal_size_bytes = file_size(&PathBuf::from(format!(
            "{}-wal",
            self.database_path.to_string_lossy()
        )))
        .await;
        let status = if quick_check.eq_ignore_ascii_case("ok") && foreign_key_violations == 0 {
            "ok"
        } else {
            "warning"
        };
        Ok(DatabaseHealth {
            status: status.into(),
            quick_check,
            foreign_key_violations,
            database_size_bytes,
            wal_size_bytes,
            database_path: self.database_path.to_string_lossy().to_string(),
            checked_at: Utc::now().to_rfc3339(),
        })
    }

    pub async fn create_backup(&self, config_path: impl AsRef<Path>) -> Result<BackupSnapshot> {
        self.verify_database_integrity().await?;
        let backups_dir = self.data_dir.join("backups");
        tokio::fs::create_dir_all(&backups_dir).await?;
        let suffix = uuid::Uuid::new_v4()
            .simple()
            .to_string()
            .chars()
            .take(8)
            .collect::<String>();
        let id = format!("backup-{}-{suffix}", Utc::now().format("%Y%m%d-%H%M%S"));
        let snapshot_dir = backups_dir.join(&id);
        tokio::fs::create_dir_all(&snapshot_dir).await?;

        let result = self
            .create_backup_inner(config_path.as_ref(), &id, &snapshot_dir)
            .await;
        if result.is_err() {
            let _ = tokio::fs::remove_dir_all(&snapshot_dir).await;
        }
        result
    }

    async fn create_backup_inner(
        &self,
        config_path: &Path,
        id: &str,
        snapshot_dir: &Path,
    ) -> Result<BackupSnapshot> {
        let database_target = snapshot_dir.join("locallens.db");
        let _ = sqlx::query("PRAGMA wal_checkpoint(PASSIVE)")
            .execute(&self.pool)
            .await;
        vacuum_into(&self.pool, &database_target).await?;

        let database_quick_check = quick_check_path(&database_target).await?;
        if !database_quick_check.eq_ignore_ascii_case("ok") {
            bail!("备份数据库校验失败：{database_quick_check}")
        }

        let config_file = if config_path.is_file() {
            let target = snapshot_dir.join("config.json");
            tokio::fs::copy(config_path, &target)
                .await
                .with_context(|| format!("无法备份配置文件 {}", config_path.display()))?;
            Some("config.json".to_string())
        } else {
            None
        };

        let database_size_bytes = file_size(&database_target).await;
        let database_sha256 = hash_file(&database_target).await?;
        let created_at = Utc::now().to_rfc3339();
        let manifest = BackupManifest {
            format_version: BACKUP_FORMAT_VERSION,
            app_version: env!("CARGO_PKG_VERSION").to_string(),
            id: id.to_string(),
            created_at: created_at.clone(),
            database_file: "locallens.db".into(),
            config_file,
            database_size_bytes,
            database_sha256: database_sha256.clone(),
            database_quick_check,
        };
        let manifest_path = snapshot_dir.join("manifest.json");
        tokio::fs::write(&manifest_path, serde_json::to_vec_pretty(&manifest)?)
            .await
            .with_context(|| format!("无法写入备份清单 {}", manifest_path.display()))?;

        Ok(BackupSnapshot {
            id: id.to_string(),
            created_at,
            path: snapshot_dir.to_string_lossy().to_string(),
            database_size_bytes,
            database_sha256,
            verified: true,
        })
    }

    pub async fn list_backups(&self) -> Result<Vec<BackupSnapshot>> {
        let backups_dir = self.data_dir.join("backups");
        if !backups_dir.is_dir() {
            return Ok(Vec::new());
        }
        let mut entries = tokio::fs::read_dir(&backups_dir).await?;
        let mut backups = Vec::new();
        while let Some(entry) = entries.next_entry().await? {
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }
            let manifest_path = path.join("manifest.json");
            let Ok(content) = tokio::fs::read(&manifest_path).await else {
                continue;
            };
            let Ok(manifest) = serde_json::from_slice::<BackupManifest>(&content) else {
                continue;
            };
            if manifest.format_version != BACKUP_FORMAT_VERSION {
                continue;
            }
            backups.push(BackupSnapshot {
                id: manifest.id,
                created_at: manifest.created_at,
                path: path.to_string_lossy().to_string(),
                database_size_bytes: manifest.database_size_bytes,
                database_sha256: manifest.database_sha256,
                verified: manifest.database_quick_check.eq_ignore_ascii_case("ok"),
            });
        }
        backups.sort_by(|left, right| right.created_at.cmp(&left.created_at));
        Ok(backups)
    }
}

async fn quick_check_pool(pool: &sqlx::SqlitePool) -> Result<String> {
    let checks = sqlx::query_scalar::<_, String>("PRAGMA quick_check")
        .fetch_all(pool)
        .await
        .context("无法执行 SQLite quick_check")?;
    Ok(if checks.is_empty() {
        "unknown".into()
    } else {
        checks.join("; ")
    })
}

async fn quick_check_path(path: &Path) -> Result<String> {
    let options = SqliteConnectOptions::new().filename(path).read_only(true);
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(options)
        .await
        .with_context(|| format!("无法打开备份数据库 {}", path.display()))?;
    let result = quick_check_pool(&pool).await;
    pool.close().await;
    result
}

async fn vacuum_into(pool: &sqlx::SqlitePool, destination: &Path) -> Result<()> {
    if destination.exists() {
        tokio::fs::remove_file(destination).await?;
    }
    let escaped = destination.to_string_lossy().replace('\'', "''");
    let statement = format!("VACUUM INTO '{escaped}'");
    sqlx::query(&statement)
        .execute(pool)
        .await
        .with_context(|| format!("无法创建 SQLite 快照 {}", destination.display()))?;
    Ok(())
}

async fn hash_file(path: &Path) -> Result<String> {
    let mut file = tokio::fs::File::open(path)
        .await
        .with_context(|| format!("无法读取备份文件 {}", path.display()))?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0_u8; 1024 * 1024];
    loop {
        let read = file.read(&mut buffer).await?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(hex::encode(hasher.finalize()))
}

async fn file_size(path: &Path) -> u64 {
    tokio::fs::metadata(path)
        .await
        .map(|metadata| metadata.len())
        .unwrap_or(0)
}
