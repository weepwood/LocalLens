use anyhow::Result;
use sqlx::Row;

use super::Store;

impl Store {
    pub(super) async fn ensure_compatible_schema(&self) -> Result<()> {
        let statements = [
            r#"CREATE TABLE IF NOT EXISTS schema_migrations (
                version INTEGER PRIMARY KEY,
                applied_at TEXT NOT NULL
            )"#,
            r#"CREATE TABLE IF NOT EXISTS libraries (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                root_path TEXT NOT NULL UNIQUE,
                recursive INTEGER NOT NULL,
                enabled INTEGER NOT NULL,
                last_scanned_at TEXT
            )"#,
            r#"CREATE TABLE IF NOT EXISTS media_items (
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
            )"#,
            r#"CREATE TABLE IF NOT EXISTS folders (
                id TEXT PRIMARY KEY,
                library_id TEXT NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
                relative_path TEXT NOT NULL,
                parent_path TEXT NOT NULL,
                name TEXT NOT NULL,
                missing INTEGER NOT NULL DEFAULT 0,
                last_seen_scan TEXT NOT NULL,
                UNIQUE(library_id, relative_path)
            )"#,
            r#"CREATE TABLE IF NOT EXISTS thumbnail_jobs (
                media_id TEXT NOT NULL REFERENCES media_items(id) ON DELETE CASCADE,
                width INTEGER NOT NULL,
                source_modified_at TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'pending',
                attempts INTEGER NOT NULL DEFAULT 0,
                last_error TEXT NOT NULL DEFAULT '',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                PRIMARY KEY(media_id, width)
            )"#,
            r#"CREATE TABLE IF NOT EXISTS metadata_jobs (
                media_id TEXT PRIMARY KEY REFERENCES media_items(id) ON DELETE CASCADE,
                source_modified_at TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'pending',
                attempts INTEGER NOT NULL DEFAULT 0,
                last_error TEXT NOT NULL DEFAULT '',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )"#,
            r#"CREATE TABLE IF NOT EXISTS devices (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                platform TEXT NOT NULL,
                token_hash TEXT NOT NULL UNIQUE,
                scopes TEXT NOT NULL,
                created_at TEXT NOT NULL,
                last_seen_at TEXT,
                revoked_at TEXT
            )"#,
            r#"CREATE TABLE IF NOT EXISTS playback_progress (
                device_id TEXT NOT NULL,
                media_id TEXT NOT NULL REFERENCES media_items(id) ON DELETE CASCADE,
                position_ms INTEGER NOT NULL,
                duration_ms INTEGER NOT NULL,
                completed INTEGER NOT NULL DEFAULT 0,
                updated_at TEXT NOT NULL,
                PRIMARY KEY(device_id, media_id)
            )"#,
            r#"CREATE TABLE IF NOT EXISTS albums (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                description TEXT NOT NULL DEFAULT '',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )"#,
            r#"CREATE TABLE IF NOT EXISTS album_items (
                album_id TEXT NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
                media_id TEXT NOT NULL REFERENCES media_items(id) ON DELETE CASCADE,
                position INTEGER NOT NULL DEFAULT 0,
                added_at TEXT NOT NULL,
                PRIMARY KEY(album_id, media_id)
            )"#,
            r#"CREATE TABLE IF NOT EXISTS tags (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL COLLATE NOCASE UNIQUE,
                color TEXT NOT NULL DEFAULT '',
                created_at TEXT NOT NULL
            )"#,
            r#"CREATE TABLE IF NOT EXISTS media_tags (
                media_id TEXT NOT NULL REFERENCES media_items(id) ON DELETE CASCADE,
                tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                added_at TEXT NOT NULL,
                PRIMARY KEY(media_id, tag_id)
            )"#,
            r#"CREATE TABLE IF NOT EXISTS transcode_jobs (
                media_id TEXT NOT NULL REFERENCES media_items(id) ON DELETE CASCADE,
                profile TEXT NOT NULL,
                source_modified_at TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'pending',
                attempts INTEGER NOT NULL DEFAULT 0,
                progress REAL NOT NULL DEFAULT 0,
                last_error TEXT NOT NULL DEFAULT '',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                PRIMARY KEY(media_id, profile)
            )"#,
        ];
        for statement in statements {
            sqlx::query(statement).execute(&self.pool).await?;
        }

        let columns = [
            ("media_items", "favorite", "INTEGER NOT NULL DEFAULT 0"),
            ("media_items", "folder_path", "TEXT NOT NULL DEFAULT ''"),
            ("media_items", "captured_at", "TEXT"),
            (
                "media_items",
                "captured_at_source",
                "TEXT NOT NULL DEFAULT 'modified'",
            ),
            ("media_items", "width", "INTEGER NOT NULL DEFAULT 0"),
            ("media_items", "height", "INTEGER NOT NULL DEFAULT 0"),
            ("media_items", "duration_ms", "INTEGER NOT NULL DEFAULT 0"),
            ("media_items", "codec", "TEXT NOT NULL DEFAULT ''"),
            ("media_items", "latitude", "REAL"),
            ("media_items", "longitude", "REAL"),
            ("media_items", "camera_model", "TEXT NOT NULL DEFAULT ''"),
            (
                "media_items",
                "metadata_status",
                "TEXT NOT NULL DEFAULT 'pending'",
            ),
            ("media_items", "metadata_error", "TEXT NOT NULL DEFAULT ''"),
            ("media_items", "rating", "INTEGER NOT NULL DEFAULT 0"),
        ];
        for (table, column, definition) in columns {
            self.ensure_column(table, column, definition).await?;
        }

        let indexes = [
            "CREATE INDEX IF NOT EXISTS idx_media_type_modified ON media_items(media_type, modified_at DESC, id DESC)",
            "CREATE INDEX IF NOT EXISTS idx_media_library ON media_items(library_id)",
            "CREATE INDEX IF NOT EXISTS idx_media_favorite_modified ON media_items(favorite, modified_at DESC, id DESC)",
            "CREATE INDEX IF NOT EXISTS idx_media_captured ON media_items(captured_at DESC, id DESC)",
            "CREATE INDEX IF NOT EXISTS idx_media_folder ON media_items(library_id, folder_path, captured_at DESC, id DESC)",
            "CREATE INDEX IF NOT EXISTS idx_media_rating ON media_items(rating, captured_at DESC, id DESC)",
            "CREATE INDEX IF NOT EXISTS idx_media_metadata_status ON media_items(metadata_status, modified_at)",
            "CREATE INDEX IF NOT EXISTS idx_folders_parent ON folders(library_id, parent_path, name)",
            "CREATE INDEX IF NOT EXISTS idx_thumbnail_jobs_status ON thumbnail_jobs(status, updated_at)",
            "CREATE INDEX IF NOT EXISTS idx_metadata_jobs_status ON metadata_jobs(status, updated_at)",
            "CREATE INDEX IF NOT EXISTS idx_devices_token ON devices(token_hash, revoked_at)",
            "CREATE INDEX IF NOT EXISTS idx_playback_updated ON playback_progress(device_id, updated_at DESC)",
            "CREATE INDEX IF NOT EXISTS idx_album_items_media ON album_items(media_id)",
            "CREATE INDEX IF NOT EXISTS idx_media_tags_tag ON media_tags(tag_id, media_id)",
            "CREATE INDEX IF NOT EXISTS idx_transcode_jobs_status ON transcode_jobs(status, updated_at, media_id, profile)",
        ];
        for statement in indexes {
            sqlx::query(statement).execute(&self.pool).await?;
        }

        sqlx::query(
            "UPDATE media_items SET captured_at=modified_at,captured_at_source='modified' WHERE captured_at IS NULL OR captured_at=''",
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    async fn ensure_column(&self, table: &str, column: &str, definition: &str) -> Result<()> {
        let rows = sqlx::query(&format!("PRAGMA table_info({table})"))
            .fetch_all(&self.pool)
            .await?;
        if rows
            .iter()
            .any(|row| row.get::<String, _>("name") == column)
        {
            return Ok(());
        }
        sqlx::query(&format!(
            "ALTER TABLE {table} ADD COLUMN {column} {definition}"
        ))
        .execute(&self.pool)
        .await?;
        Ok(())
    }
}
