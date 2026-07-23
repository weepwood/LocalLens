use anyhow::Result;
use chrono::Utc;
use sqlx::Row;

use crate::{MediaItem, MetadataJob, ThumbnailJob, TranscodeJob, TranscodeState};

use super::Store;

impl Store {
    pub async fn enqueue_thumbnail(
        &self,
        media_id: &str,
        width: i64,
        modified_at: &str,
    ) -> Result<()> {
        let now = Utc::now().to_rfc3339();
        sqlx::query(
            r#"INSERT INTO thumbnail_jobs(media_id,width,source_modified_at,status,attempts,last_error,created_at,updated_at)
VALUES(?,?,?,'pending',0,'',?,?)
ON CONFLICT(media_id,width) DO UPDATE SET
 source_modified_at=excluded.source_modified_at,
 status=CASE WHEN thumbnail_jobs.status IN ('running','native_running') THEN thumbnail_jobs.status ELSE 'pending' END,
 attempts=CASE WHEN thumbnail_jobs.source_modified_at<>excluded.source_modified_at OR thumbnail_jobs.status IN ('done','failed') THEN 0 ELSE thumbnail_jobs.attempts END,
 last_error=CASE WHEN thumbnail_jobs.status IN ('running','native_running') THEN thumbnail_jobs.last_error ELSE '' END,
 updated_at=excluded.updated_at"#,
        )
        .bind(media_id)
        .bind(width.clamp(64, 1920))
        .bind(modified_at)
        .bind(&now)
        .bind(&now)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn claim_thumbnail_job(&self) -> Result<Option<ThumbnailJob>> {
        let row = sqlx::query(
            r#"UPDATE thumbnail_jobs
SET status='running',attempts=attempts+1,updated_at=?
WHERE rowid=(SELECT rowid FROM thumbnail_jobs WHERE status IN ('pending','native_pending') ORDER BY updated_at,media_id,width LIMIT 1)
AND status IN ('pending','native_pending')
RETURNING media_id,width,source_modified_at,attempts"#,
        )
        .bind(Utc::now().to_rfc3339())
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|row| ThumbnailJob {
            media_id: row.get("media_id"),
            width: row.get("width"),
            source_modified_at: row.get("source_modified_at"),
            attempts: row.get("attempts"),
        }))
    }

    pub async fn finish_thumbnail_job(
        &self,
        job: &ThumbnailJob,
        status: &str,
        error: &str,
    ) -> Result<()> {
        sqlx::query(
            "UPDATE thumbnail_jobs SET status=?,last_error=?,updated_at=? WHERE media_id=? AND width=?",
        )
        .bind(status)
        .bind(error)
        .bind(Utc::now().to_rfc3339())
        .bind(&job.media_id)
        .bind(job.width)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn enqueue_metadata(&self, media_id: &str, modified_at: &str) -> Result<()> {
        let now = Utc::now().to_rfc3339();
        sqlx::query(
            r#"INSERT INTO metadata_jobs(media_id,source_modified_at,status,attempts,last_error,created_at,updated_at)
VALUES(?,?,'pending',0,'',?,?)
ON CONFLICT(media_id) DO UPDATE SET
 source_modified_at=excluded.source_modified_at,
 status=CASE WHEN metadata_jobs.status='running' THEN metadata_jobs.status ELSE 'pending' END,
 attempts=CASE WHEN metadata_jobs.source_modified_at<>excluded.source_modified_at OR metadata_jobs.status IN ('done','failed') THEN 0 ELSE metadata_jobs.attempts END,
 last_error=CASE WHEN metadata_jobs.status='running' THEN metadata_jobs.last_error ELSE '' END,
 updated_at=excluded.updated_at"#,
        )
        .bind(media_id)
        .bind(modified_at)
        .bind(&now)
        .bind(&now)
        .execute(&self.pool)
        .await?;
        sqlx::query(
            "UPDATE media_items SET metadata_status='pending',metadata_error='' WHERE id=?",
        )
        .bind(media_id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn claim_metadata_job(&self) -> Result<Option<MetadataJob>> {
        let row = sqlx::query(
            r#"UPDATE metadata_jobs
SET status='running',attempts=attempts+1,updated_at=?
WHERE rowid=(SELECT rowid FROM metadata_jobs WHERE status='pending' ORDER BY updated_at,media_id LIMIT 1)
AND status='pending'
RETURNING media_id,source_modified_at,attempts"#,
        )
        .bind(Utc::now().to_rfc3339())
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|row| MetadataJob {
            media_id: row.get("media_id"),
            source_modified_at: row.get("source_modified_at"),
            attempts: row.get("attempts"),
        }))
    }

    pub async fn finish_metadata_job(
        &self,
        job: &MetadataJob,
        status: &str,
        error: &str,
    ) -> Result<()> {
        sqlx::query("UPDATE metadata_jobs SET status=?,last_error=?,updated_at=? WHERE media_id=?")
            .bind(status)
            .bind(error)
            .bind(Utc::now().to_rfc3339())
            .bind(&job.media_id)
            .execute(&self.pool)
            .await?;
        if status == "failed" {
            sqlx::query(
                "UPDATE media_items SET metadata_status='failed',metadata_error=? WHERE id=?",
            )
            .bind(error)
            .bind(&job.media_id)
            .execute(&self.pool)
            .await?;
        }
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn update_metadata(
        &self,
        media_id: &str,
        width: i64,
        height: i64,
        duration_ms: i64,
        codec: &str,
        captured_at: &str,
        captured_at_source: &str,
        latitude: Option<f64>,
        longitude: Option<f64>,
        camera_model: &str,
    ) -> Result<()> {
        sqlx::query(
            r#"UPDATE media_items SET width=?,height=?,duration_ms=?,codec=?,captured_at=?,captured_at_source=?,
latitude=?,longitude=?,camera_model=?,metadata_status='done',metadata_error='' WHERE id=?"#,
        )
        .bind(width)
        .bind(height)
        .bind(duration_ms)
        .bind(codec)
        .bind(captured_at)
        .bind(captured_at_source)
        .bind(latitude)
        .bind(longitude)
        .bind(camera_model)
        .bind(media_id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn enqueue_transcode(&self, media: &MediaItem, profile: &str) -> Result<()> {
        let now = Utc::now().to_rfc3339();
        sqlx::query(
            r#"INSERT INTO transcode_jobs(media_id,profile,source_modified_at,status,attempts,progress,last_error,created_at,updated_at)
VALUES(?,?,?,'pending',0,0,'',?,?)
ON CONFLICT(media_id,profile) DO UPDATE SET
 source_modified_at=excluded.source_modified_at,
 status=CASE WHEN transcode_jobs.status='running' THEN 'running' ELSE 'pending' END,
 attempts=CASE WHEN transcode_jobs.source_modified_at<>excluded.source_modified_at OR transcode_jobs.status='failed' THEN 0 ELSE transcode_jobs.attempts END,
 progress=CASE WHEN transcode_jobs.status='running' THEN transcode_jobs.progress ELSE 0 END,
 last_error='',updated_at=excluded.updated_at"#,
        )
        .bind(&media.id)
        .bind(profile)
        .bind(&media.modified_at)
        .bind(&now)
        .bind(&now)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn claim_transcode_job(&self) -> Result<Option<TranscodeJob>> {
        let row = sqlx::query(
            r#"UPDATE transcode_jobs
SET status='running',attempts=attempts+1,progress=0,updated_at=?
WHERE rowid=(SELECT rowid FROM transcode_jobs WHERE status='pending' ORDER BY updated_at,media_id,profile LIMIT 1)
AND status='pending'
RETURNING media_id,profile,source_modified_at,attempts"#,
        )
        .bind(Utc::now().to_rfc3339())
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|row| TranscodeJob {
            media_id: row.get("media_id"),
            profile: row.get("profile"),
            source_modified_at: row.get("source_modified_at"),
            attempts: row.get("attempts"),
        }))
    }

    pub async fn update_transcode_progress(
        &self,
        media_id: &str,
        profile: &str,
        progress: f64,
    ) -> Result<()> {
        sqlx::query(
            "UPDATE transcode_jobs SET progress=?,updated_at=? WHERE media_id=? AND profile=?",
        )
        .bind(progress.clamp(0.0, 1.0))
        .bind(Utc::now().to_rfc3339())
        .bind(media_id)
        .bind(profile)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn finish_transcode_job(
        &self,
        job: &TranscodeJob,
        status: &str,
        progress: f64,
        error: &str,
    ) -> Result<()> {
        sqlx::query(
            "UPDATE transcode_jobs SET status=?,progress=?,last_error=?,updated_at=? WHERE media_id=? AND profile=?",
        )
        .bind(status)
        .bind(progress.clamp(0.0, 1.0))
        .bind(error)
        .bind(Utc::now().to_rfc3339())
        .bind(&job.media_id)
        .bind(&job.profile)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn transcode_state(&self, media_id: &str, profile: &str) -> Result<TranscodeState> {
        let row = sqlx::query(
            "SELECT status,progress,last_error FROM transcode_jobs WHERE media_id=? AND profile=?",
        )
        .bind(media_id)
        .bind(profile)
        .fetch_optional(&self.pool)
        .await?;
        Ok(
            row.map_or_else(TranscodeState::default, |row| TranscodeState {
                status: row.get("status"),
                progress: row.get("progress"),
                error: row.get("last_error"),
            }),
        )
    }

    pub async fn retry_failed_transcodes(&self) -> Result<u64> {
        Ok(sqlx::query(
            "UPDATE transcode_jobs SET status='pending',attempts=0,progress=0,last_error='',updated_at=? WHERE status='failed'",
        )
        .bind(Utc::now().to_rfc3339())
        .execute(&self.pool)
        .await?
        .rows_affected())
    }
}
