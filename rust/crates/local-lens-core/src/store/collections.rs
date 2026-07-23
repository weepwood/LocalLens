use anyhow::{Context, Result};
use chrono::Utc;
use sha2::{Digest, Sha256};
use sqlx::Row;

use crate::{Album, AppConfig, AuthIdentity, Device, PlaybackProgress, Tag, random_id};

use super::Store;

impl Store {
    pub async fn playback_progress(
        &self,
        profile: &str,
        media_id: &str,
    ) -> Result<PlaybackProgress> {
        let row = sqlx::query(
            "SELECT device_id,media_id,position_ms,duration_ms,completed,updated_at FROM playback_progress WHERE device_id=? AND media_id=?",
        )
        .bind(profile)
        .bind(media_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(match row {
            Some(row) => PlaybackProgress {
                device_id: row.get("device_id"),
                media_id: row.get("media_id"),
                position_ms: row.get("position_ms"),
                duration_ms: row.get("duration_ms"),
                completed: row.get::<i64, _>("completed") != 0,
                updated_at: row
                    .try_get::<Option<String>, _>("updated_at")
                    .ok()
                    .flatten(),
            },
            None => PlaybackProgress {
                device_id: profile.into(),
                media_id: media_id.into(),
                ..Default::default()
            },
        })
    }

    pub async fn save_playback_progress(
        &self,
        mut progress: PlaybackProgress,
    ) -> Result<PlaybackProgress> {
        progress.position_ms = progress.position_ms.max(0);
        progress.duration_ms = progress.duration_ms.max(0);
        if progress.duration_ms > 0 {
            progress.position_ms = progress.position_ms.min(progress.duration_ms);
        }
        let updated_at = Utc::now().to_rfc3339();
        sqlx::query(
            r#"INSERT INTO playback_progress(device_id,media_id,position_ms,duration_ms,completed,updated_at)
VALUES(?,?,?,?,?,?)
ON CONFLICT(device_id,media_id) DO UPDATE SET
 position_ms=excluded.position_ms,duration_ms=excluded.duration_ms,
 completed=excluded.completed,updated_at=excluded.updated_at"#,
        )
        .bind(&progress.device_id)
        .bind(&progress.media_id)
        .bind(progress.position_ms)
        .bind(progress.duration_ms)
        .bind(progress.completed)
        .bind(&updated_at)
        .execute(&self.pool)
        .await?;
        progress.updated_at = Some(updated_at);
        Ok(progress)
    }

    pub async fn albums(&self) -> Result<Vec<Album>> {
        let rows = sqlx::query(
            r#"SELECT a.id,a.name,a.description,a.created_at,a.updated_at,COUNT(ai.media_id) item_count
FROM albums a LEFT JOIN album_items ai ON ai.album_id=a.id
GROUP BY a.id ORDER BY a.updated_at DESC"#,
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|row| Album {
                id: row.get("id"),
                name: row.get("name"),
                description: row.get("description"),
                created_at: row.get("created_at"),
                updated_at: row.get("updated_at"),
                item_count: row.get("item_count"),
            })
            .collect())
    }

    pub async fn create_album(&self, name: &str, description: &str) -> Result<Album> {
        let name = name.trim();
        if name.is_empty() {
            anyhow::bail!("album name is required");
        }
        let now = Utc::now().to_rfc3339();
        let album = Album {
            id: random_id(),
            name: name.into(),
            description: description.trim().into(),
            item_count: 0,
            created_at: now.clone(),
            updated_at: now.clone(),
        };
        sqlx::query(
            "INSERT INTO albums(id,name,description,created_at,updated_at) VALUES(?,?,?,?,?)",
        )
        .bind(&album.id)
        .bind(&album.name)
        .bind(&album.description)
        .bind(&album.created_at)
        .bind(&album.updated_at)
        .execute(&self.pool)
        .await?;
        Ok(album)
    }

    pub async fn delete_album(&self, id: &str) -> Result<bool> {
        Ok(sqlx::query("DELETE FROM albums WHERE id=?")
            .bind(id)
            .execute(&self.pool)
            .await?
            .rows_affected()
            > 0)
    }

    pub async fn set_album_item(&self, album_id: &str, media_id: &str, add: bool) -> Result<()> {
        if add {
            let now = Utc::now().to_rfc3339();
            sqlx::query(
                "INSERT OR IGNORE INTO album_items(album_id,media_id,added_at) VALUES(?,?,?)",
            )
            .bind(album_id)
            .bind(media_id)
            .bind(&now)
            .execute(&self.pool)
            .await?;
            sqlx::query("UPDATE albums SET updated_at=? WHERE id=?")
                .bind(now)
                .bind(album_id)
                .execute(&self.pool)
                .await?;
        } else {
            sqlx::query("DELETE FROM album_items WHERE album_id=? AND media_id=?")
                .bind(album_id)
                .bind(media_id)
                .execute(&self.pool)
                .await?;
        }
        Ok(())
    }

    pub async fn tags(&self) -> Result<Vec<Tag>> {
        let rows = sqlx::query(
            r#"SELECT t.id,t.name,t.color,t.created_at,COUNT(mt.media_id) item_count
FROM tags t LEFT JOIN media_tags mt ON mt.tag_id=t.id
GROUP BY t.id ORDER BY t.name COLLATE NOCASE"#,
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|row| Tag {
                id: row.get("id"),
                name: row.get("name"),
                color: row.get("color"),
                created_at: row.get("created_at"),
                item_count: row.get("item_count"),
            })
            .collect())
    }

    pub async fn create_tag(&self, name: &str, color: &str) -> Result<Tag> {
        let name = name.trim();
        if name.is_empty() {
            anyhow::bail!("tag name is required");
        }
        let tag = Tag {
            id: random_id(),
            name: name.into(),
            color: color.trim().into(),
            item_count: 0,
            created_at: Utc::now().to_rfc3339(),
        };
        sqlx::query("INSERT INTO tags(id,name,color,created_at) VALUES(?,?,?,?)")
            .bind(&tag.id)
            .bind(&tag.name)
            .bind(&tag.color)
            .bind(&tag.created_at)
            .execute(&self.pool)
            .await?;
        Ok(tag)
    }

    pub async fn delete_tag(&self, id: &str) -> Result<bool> {
        Ok(sqlx::query("DELETE FROM tags WHERE id=?")
            .bind(id)
            .execute(&self.pool)
            .await?
            .rows_affected()
            > 0)
    }

    pub async fn set_media_tag(&self, media_id: &str, tag_id: &str, add: bool) -> Result<()> {
        if add {
            sqlx::query("INSERT OR IGNORE INTO media_tags(media_id,tag_id,added_at) VALUES(?,?,?)")
                .bind(media_id)
                .bind(tag_id)
                .bind(Utc::now().to_rfc3339())
                .execute(&self.pool)
                .await?;
        } else {
            sqlx::query("DELETE FROM media_tags WHERE media_id=? AND tag_id=?")
                .bind(media_id)
                .bind(tag_id)
                .execute(&self.pool)
                .await?;
        }
        Ok(())
    }

    pub async fn media_collections(&self, media_id: &str) -> Result<(Vec<String>, Vec<String>)> {
        let album_rows =
            sqlx::query("SELECT album_id FROM album_items WHERE media_id=? ORDER BY added_at")
                .bind(media_id)
                .fetch_all(&self.pool)
                .await?;
        let tag_rows =
            sqlx::query("SELECT tag_id FROM media_tags WHERE media_id=? ORDER BY added_at")
                .bind(media_id)
                .fetch_all(&self.pool)
                .await?;
        Ok((
            album_rows
                .into_iter()
                .map(|row| row.get("album_id"))
                .collect(),
            tag_rows.into_iter().map(|row| row.get("tag_id")).collect(),
        ))
    }

    pub async fn authenticate_token(
        &self,
        token: &str,
        config: &AppConfig,
    ) -> Result<AuthIdentity> {
        let token = token.trim();
        if token.is_empty() {
            anyhow::bail!("missing token");
        }
        if hash_token(token) == hash_token(&config.api_token) {
            return Ok(AuthIdentity {
                device_id: "admin".into(),
                name: "Administrator".into(),
                admin: true,
                scopes: "*".into(),
            });
        }
        let row = sqlx::query("SELECT id,name,scopes,revoked_at FROM devices WHERE token_hash=?")
            .bind(hash_token(token))
            .fetch_optional(&self.pool)
            .await?
            .context("设备 Token 不存在")?;
        let revoked_at: Option<String> = row.try_get("revoked_at")?;
        if revoked_at.is_some() {
            anyhow::bail!("设备 Token 已撤销");
        }
        let identity = AuthIdentity {
            device_id: row.get("id"),
            name: row.get("name"),
            admin: false,
            scopes: row.get("scopes"),
        };
        sqlx::query("UPDATE devices SET last_seen_at=? WHERE id=?")
            .bind(Utc::now().to_rfc3339())
            .bind(&identity.device_id)
            .execute(&self.pool)
            .await?;
        Ok(identity)
    }

    pub async fn create_device(&self, name: &str, platform: &str, token: &str) -> Result<Device> {
        let now = Utc::now().to_rfc3339();
        let device = Device {
            id: random_id(),
            name: name.trim().into(),
            platform: platform.trim().into(),
            scopes: "media:read,media:write".into(),
            created_at: now.clone(),
            last_seen_at: None,
            revoked_at: None,
        };
        sqlx::query(
            "INSERT INTO devices(id,name,platform,token_hash,scopes,created_at) VALUES(?,?,?,?,?,?)",
        )
        .bind(&device.id)
        .bind(&device.name)
        .bind(&device.platform)
        .bind(hash_token(token))
        .bind(&device.scopes)
        .bind(&now)
        .execute(&self.pool)
        .await?;
        Ok(device)
    }

    pub async fn devices(&self) -> Result<Vec<Device>> {
        let rows = sqlx::query(
            "SELECT id,name,platform,scopes,created_at,last_seen_at,revoked_at FROM devices ORDER BY created_at DESC",
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|row| Device {
                id: row.get("id"),
                name: row.get("name"),
                platform: row.get("platform"),
                scopes: row.get("scopes"),
                created_at: row.get("created_at"),
                last_seen_at: row
                    .try_get::<Option<String>, _>("last_seen_at")
                    .ok()
                    .flatten(),
                revoked_at: row
                    .try_get::<Option<String>, _>("revoked_at")
                    .ok()
                    .flatten(),
            })
            .collect())
    }

    pub async fn revoke_device(&self, id: &str) -> Result<bool> {
        Ok(
            sqlx::query("UPDATE devices SET revoked_at=? WHERE id=? AND revoked_at IS NULL")
                .bind(Utc::now().to_rfc3339())
                .bind(id)
                .execute(&self.pool)
                .await?
                .rows_affected()
                > 0,
        )
    }
}

pub fn hash_token(value: &str) -> String {
    hex::encode(Sha256::digest(value.as_bytes()))
}
