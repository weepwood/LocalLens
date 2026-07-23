use local_lens_core::{BackupSnapshot, DatabaseHealth};
use tauri::{State, ipc::Response as IpcResponse};

use crate::RuntimeState;

#[tauri::command]
pub(crate) async fn desktop_database_health(
    state: State<'_, RuntimeState>,
) -> Result<DatabaseHealth, String> {
    let current = state.current().await?;
    current
        .store
        .database_health()
        .await
        .map_err(|error| error.to_string())
}

#[tauri::command]
pub(crate) async fn desktop_create_backup(
    state: State<'_, RuntimeState>,
) -> Result<BackupSnapshot, String> {
    let current = state.current().await?;
    current
        .store
        .create_backup(&state.config_path)
        .await
        .map_err(|error| error.to_string())
}

#[tauri::command]
pub(crate) async fn desktop_list_backups(
    state: State<'_, RuntimeState>,
) -> Result<Vec<BackupSnapshot>, String> {
    let current = state.current().await?;
    current
        .store
        .list_backups()
        .await
        .map_err(|error| error.to_string())
}

#[tauri::command]
pub(crate) async fn desktop_backup_manifest(
    state: State<'_, RuntimeState>,
    backup_id: String,
) -> Result<IpcResponse, String> {
    if backup_id.is_empty()
        || backup_id.contains('/')
        || backup_id.contains('\\')
        || backup_id.contains("..")
    {
        return Err("备份标识无效".into());
    }
    let current = state.current().await?;
    let path = current
        .config
        .data_dir
        .join("backups")
        .join(backup_id)
        .join("manifest.json");
    let bytes = tokio::fs::read(&path)
        .await
        .map_err(|error| format!("读取备份清单失败：{error}"))?;
    Ok(IpcResponse::new(bytes))
}
