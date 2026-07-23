use std::path::Path;

use local_lens_core::Store;
use tempfile::tempdir;

#[tokio::test]
async fn creates_and_lists_verified_database_backup() {
    let temp = tempdir().expect("create temp directory");
    let data_dir = temp.path().join("data");
    let config_path = temp.path().join("config.json");
    tokio::fs::write(&config_path, br#"{"server_name":"LocalLens Test"}"#)
        .await
        .expect("write config");

    let store = Store::open(&data_dir).await.expect("open store");
    let health = store.database_health().await.expect("database health");
    assert_eq!(health.status, "ok");
    assert_eq!(health.quick_check, "ok");
    assert_eq!(health.foreign_key_violations, 0);

    let backup = store
        .create_backup(&config_path)
        .await
        .expect("create backup");
    assert!(backup.verified);
    assert!(backup.database_size_bytes > 0);
    assert_eq!(backup.database_sha256.len(), 64);
    assert!(Path::new(&backup.path).join("locallens.db").is_file());
    assert!(Path::new(&backup.path).join("config.json").is_file());
    assert!(Path::new(&backup.path).join("manifest.json").is_file());

    let backups = store.list_backups().await.expect("list backups");
    assert_eq!(backups.len(), 1);
    assert_eq!(backups[0].id, backup.id);
    assert!(backups[0].verified);
}
