use std::path::Path;

use sha2::{Digest, Sha256};
use uuid::Uuid;

pub fn stable_id(library_id: &str, relative: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(library_id.as_bytes());
    hasher.update([0]);
    hasher.update(relative.to_ascii_lowercase().as_bytes());
    hex::encode(&hasher.finalize()[..16])
}

pub fn random_id() -> String {
    Uuid::new_v4().simple().to_string()
}

pub fn media_type_for_path(path: &Path) -> Option<(&'static str, &'static str)> {
    let extension = path.extension()?.to_string_lossy().to_ascii_lowercase();
    match extension.as_str() {
        "jpg" | "jpeg" => Some(("image", "image/jpeg")),
        "png" => Some(("image", "image/png")),
        "gif" => Some(("image", "image/gif")),
        "webp" => Some(("image", "image/webp")),
        "bmp" => Some(("image", "image/bmp")),
        "tif" | "tiff" => Some(("image", "image/tiff")),
        "heic" | "heif" => Some(("image", "image/heic")),
        "avif" => Some(("image", "image/avif")),
        "mp4" => Some(("video", "video/mp4")),
        "m4v" => Some(("video", "video/x-m4v")),
        "mov" => Some(("video", "video/quicktime")),
        "mkv" => Some(("video", "video/x-matroska")),
        "avi" => Some(("video", "video/x-msvideo")),
        "webm" => Some(("video", "video/webm")),
        "wmv" => Some(("video", "video/x-ms-wmv")),
        _ => None,
    }
}
