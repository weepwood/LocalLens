use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

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
    pub transcodes_pending: i64,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaQuery {
    #[serde(rename = "type")]
    pub kind: Option<String>,
    #[serde(rename = "q")]
    pub search: Option<String>,
    pub library_id: Option<String>,
    pub folder: Option<String>,
    #[serde(default)]
    pub recursive: bool,
    #[serde(default)]
    pub favorite: bool,
    pub album_id: Option<String>,
    pub tag_id: Option<String>,
    #[serde(default)]
    pub min_rating: i64,
    pub sort: Option<String>,
    #[serde(default = "default_limit")]
    pub limit: i64,
    #[serde(default)]
    pub offset: i64,
    pub cursor: Option<String>,
}

fn default_limit() -> i64 {
    100
}

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
pub struct FolderInfo {
    pub id: String,
    pub library_id: String,
    pub path: String,
    pub parent_path: String,
    pub name: String,
    pub media_count: i64,
    pub child_count: i64,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ScanStatus {
    pub running: bool,
    pub started_at: Option<DateTime<Utc>>,
    pub finished_at: Option<DateTime<Utc>>,
    pub current: String,
    pub discovered: i64,
    pub indexed: i64,
    pub failed: i64,
    pub error_message: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Album {
    pub id: String,
    pub name: String,
    pub description: String,
    pub item_count: i64,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Tag {
    pub id: String,
    pub name: String,
    pub color: String,
    pub item_count: i64,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Device {
    pub id: String,
    pub name: String,
    pub platform: String,
    pub scopes: String,
    pub created_at: String,
    pub last_seen_at: Option<String>,
    pub revoked_at: Option<String>,
}

#[derive(Debug, Clone)]
pub struct AuthIdentity {
    pub device_id: String,
    pub name: String,
    pub admin: bool,
    pub scopes: String,
}

impl AuthIdentity {
    pub fn playback_profile(&self) -> &'static str {
        "shared-media-profile"
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct PlaybackProgress {
    pub device_id: String,
    pub media_id: String,
    pub position_ms: i64,
    pub duration_ms: i64,
    pub completed: bool,
    pub updated_at: Option<String>,
}

#[derive(Debug, Clone)]
pub struct ThumbnailJob {
    pub media_id: String,
    pub width: i64,
    pub source_modified_at: String,
    pub attempts: i64,
}

#[derive(Debug, Clone)]
pub struct MetadataJob {
    pub media_id: String,
    pub source_modified_at: String,
    pub attempts: i64,
}

#[derive(Debug, Clone)]
pub struct TranscodeJob {
    pub media_id: String,
    pub profile: String,
    pub source_modified_at: String,
    pub attempts: i64,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TranscodeState {
    pub status: String,
    pub progress: f64,
    pub error: String,
}

#[derive(Debug, Clone, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct PlaybackRequest {
    #[serde(default)]
    pub platform: String,
    #[serde(default)]
    pub video_codecs: Vec<String>,
    #[serde(default)]
    pub containers: Vec<String>,
    #[serde(default = "default_true")]
    pub supports_hls: bool,
    #[serde(default)]
    pub max_width: i64,
    #[serde(default)]
    pub max_height: i64,
    #[serde(default)]
    pub preferred_height: i64,
    #[serde(default)]
    pub force_transcode: bool,
}

fn default_true() -> bool {
    true
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SubtitleManifest {
    pub id: String,
    pub name: String,
    pub language: String,
    pub format: String,
    pub url: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlaybackManifest {
    pub mode: String,
    pub status: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub url: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub mime_type: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub profile: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub codec: String,
    pub width: i64,
    pub height: i64,
    #[serde(skip_serializing_if = "is_zero_f64")]
    pub progress: f64,
    #[serde(skip_serializing_if = "is_zero_i64")]
    pub retry_after: i64,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub error: String,
    pub subtitles: Vec<SubtitleManifest>,
}

fn is_zero_f64(value: &f64) -> bool {
    *value == 0.0
}
fn is_zero_i64(value: &i64) -> bool {
    *value == 0
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
