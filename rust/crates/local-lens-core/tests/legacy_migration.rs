use std::time::Duration;

use anyhow::Result;
use local_lens_core::Store;
use sqlx::{
    sqlite::SqliteConnectOptions,
    Connection, Row, SqliteConnection,
};

#[tokio::test]
async fn legacy_database_is_backed_up_and_upgraded_in_place() -> Result<()> {
    let root = tempfile::tempdir()?;
    let data_dir = root.path().join("data");
    std::fs::create_dir_all(&data_dir)?;
    let database = data_dir.join("locallens.db");
    let options = SqliteConnectOptions::new()
        .filename(&database)
        .create_if_missing(true)
        .busy_timeout(Duration::from_secs(5));
    let mut connection = SqliteConnection::connect_with(&options).await?;
    sqlx::query(
        r#"CREATE TABLE libraries (
 id TEXT PRIMARY KEY,name TEXT NOT NULL,root_path TEXT NOT NULL UNIQUE,
 recursive INTEGER NOT NULL,enabled INTEGER NOT NULL,last_scanned_at TEXT
);
CREATE TABLE media_items (
 id TEXT PRIMARY KEY,library_id TEXT NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
 relative_path TEXT NOT NULL,file_name TEXT NOT NULL,media_type TEXT NOT NULL,
 mime_type TEXT NOT NULL,size_bytes INTEGER NOT NULL,modified_at TEXT NOT NULL,
 missing INTEGER NOT NULL DEFAULT 0,last_seen_scan TEXT NOT NULL,
 UNIQUE(library_id,relative_path)
);"#,
    )
    .execute(&mut connection)
    .await?;
    sqlx::query(
        "INSERT INTO libraries(id,name,root_path,recursive,enabled) VALUES('main','旧媒体库','D:/Media',1,1)",
    )
    .execute(&mut connection)
    .await?;
    sqlx::query(
        r#"INSERT INTO media_items(
 id,library_id,relative_path,file_name,media_type,mime_type,size_bytes,
 modified_at,missing,last_seen_scan)
VALUES('legacy','main','old.jpg','old.jpg','image','image/jpeg',123,
 '2025-01-01T00:00:00Z',0,'legacy-scan')"#,
    )
    .execute(&mut connection)
    .await?;
    connection.close().await?;

    let store = Store::open(&data_dir).await?;
    let row = sqlx::query(
        "SELECT id,favorite,rating,folder_path,captured_at,metadata_status FROM media_items WHERE id='legacy'",
    )
    .fetch_one(store.pool())
    .await?;
    assert_eq!(row.get::<String, _>("id"), "legacy");
    assert_eq!(row.get::<i64, _>("favorite"), 0);
    assert_eq!(row.get::<i64, _>("rating"), 0);
    assert_eq!(row.get::<String, _>("folder_path"), "");
    assert_eq!(
        row.get::<Option<String>, _>("captured_at").as_deref(),
        Some("2025-01-01T00:00:00Z")
    );
    assert_eq!(row.get::<String, _>("metadata_status"), "pending");
    drop(store);

    let backups = std::fs::read_dir(data_dir.join("backups"))?
        .filter_map(|entry| entry.ok())
        .filter(|entry| entry.path().extension().and_then(|value| value.to_str()) == Some("db"))
        .count();
    assert_eq!(backups, 1);
    assert!(data_dir.join(".rust-backend-migration-v1").is_file());

    let store = Store::open(&data_dir).await?;
    drop(store);
    let backups_after_second_open = std::fs::read_dir(data_dir.join("backups"))?
        .filter_map(|entry| entry.ok())
        .filter(|entry| entry.path().extension().and_then(|value| value.to_str()) == Some("db"))
        .count();
    assert_eq!(backups_after_second_open, 1);
    Ok(())
}
