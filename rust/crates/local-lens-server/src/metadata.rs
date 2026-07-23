use std::{fs::File, io::BufReader, path::Path};

use anyhow::{Context, Result};
use chrono::{DateTime, NaiveDateTime, SecondsFormat, Utc};
use exif::{In, Reader as ExifReader, Tag, Value};
use image::ImageReader;
use local_lens_core::MediaItem;
use serde::Deserialize;
use tokio::process::Command;

use crate::runtime::AppState;

#[derive(Debug, Clone)]
pub struct ExtractedMetadata {
    pub width: i64,
    pub height: i64,
    pub duration_ms: i64,
    pub codec: String,
    pub captured_at: String,
    pub captured_at_source: String,
    pub latitude: Option<f64>,
    pub longitude: Option<f64>,
    pub camera_model: String,
}

impl ExtractedMetadata {
    fn from_media(media: &MediaItem) -> Self {
        Self {
            width: media.width,
            height: media.height,
            duration_ms: media.duration_ms,
            codec: media.codec.clone(),
            captured_at: media.modified_at.clone(),
            captured_at_source: "modified".into(),
            latitude: media.latitude,
            longitude: media.longitude,
            camera_model: media.camera_model.clone(),
        }
    }
}

#[derive(Debug, Deserialize)]
struct ProbeResult {
    #[serde(default)]
    streams: Vec<ProbeStream>,
    #[serde(default)]
    format: ProbeFormat,
}

#[derive(Debug, Default, Deserialize)]
struct ProbeStream {
    #[serde(default)]
    width: i64,
    #[serde(default)]
    height: i64,
    #[serde(default)]
    codec_name: String,
    #[serde(default)]
    duration: String,
    #[serde(default)]
    tags: ProbeTags,
}

#[derive(Debug, Default, Deserialize)]
struct ProbeFormat {
    #[serde(default)]
    duration: String,
    #[serde(default)]
    tags: ProbeTags,
}

#[derive(Debug, Default, Deserialize)]
struct ProbeTags {
    #[serde(default)]
    creation_time: String,
}

pub async fn extract_and_store(state: &AppState, media: &MediaItem) -> Result<()> {
    let path = state
        .media_path(media)
        .context("媒体文件路径不安全或媒体库不存在")?;
    let mut extracted = ExtractedMetadata::from_media(media);
    let mut errors = Vec::new();

    if media.media_type == "image" {
        let image_path = path.clone();
        match tokio::task::spawn_blocking(move || extract_image(&image_path)).await {
            Ok(Ok(image)) => apply_image(image, &mut extracted),
            Ok(Err(error)) => errors.push(error.to_string()),
            Err(error) => errors.push(error.to_string()),
        }
    }

    if media.media_type == "video" || extracted.width == 0 || extracted.height == 0 {
        match run_ffprobe(state, &path).await {
            Ok(probe) => apply_probe(probe, &mut extracted),
            Err(error) => errors.push(error.to_string()),
        }
    }

    if extracted.width == 0 && extracted.height == 0 && !errors.is_empty() {
        anyhow::bail!(errors.join("; "));
    }
    state
        .store
        .update_metadata(
            &media.id,
            extracted.width,
            extracted.height,
            extracted.duration_ms,
            &extracted.codec,
            &extracted.captured_at,
            &extracted.captured_at_source,
            extracted.latitude,
            extracted.longitude,
            &extracted.camera_model,
        )
        .await?;
    Ok(())
}

fn extract_image(path: &Path) -> Result<ExtractedMetadata> {
    let dimensions = ImageReader::open(path)
        .with_context(|| format!("无法打开图片：{}", path.display()))?
        .with_guessed_format()?
        .into_dimensions()?;
    let mut result = ExtractedMetadata {
        width: i64::from(dimensions.0),
        height: i64::from(dimensions.1),
        duration_ms: 0,
        codec: String::new(),
        captured_at: String::new(),
        captured_at_source: "modified".into(),
        latitude: None,
        longitude: None,
        camera_model: String::new(),
    };

    let file = File::open(path)?;
    if let Ok(exif) = ExifReader::new().read_from_container(&mut BufReader::new(file)) {
        if let Some(value) = exif_ascii(&exif, Tag::DateTimeOriginal)
            .or_else(|| exif_ascii(&exif, Tag::DateTime))
            .and_then(|value| parse_exif_time(&value))
        {
            result.captured_at = value;
            result.captured_at_source = "exif".into();
        }
        result.camera_model = exif_ascii(&exif, Tag::Model).unwrap_or_default();
        let latitude_ref = exif_ascii(&exif, Tag::GPSLatitudeRef).unwrap_or_default();
        let longitude_ref = exif_ascii(&exif, Tag::GPSLongitudeRef).unwrap_or_default();
        result.latitude = exif
            .get_field(Tag::GPSLatitude, In::PRIMARY)
            .and_then(|field| gps_coordinate(&field.value, &latitude_ref));
        result.longitude = exif
            .get_field(Tag::GPSLongitude, In::PRIMARY)
            .and_then(|field| gps_coordinate(&field.value, &longitude_ref));
    }
    Ok(result)
}

fn apply_image(image: ExtractedMetadata, target: &mut ExtractedMetadata) {
    target.width = image.width;
    target.height = image.height;
    if !image.captured_at.is_empty() {
        target.captured_at = image.captured_at;
        target.captured_at_source = image.captured_at_source;
    }
    target.latitude = image.latitude;
    target.longitude = image.longitude;
    if !image.camera_model.is_empty() {
        target.camera_model = image.camera_model;
    }
}

async fn run_ffprobe(state: &AppState, path: &Path) -> Result<ProbeResult> {
    if state.config.ffprobe_path.as_os_str().is_empty() {
        anyhow::bail!("ffprobe is not configured");
    }
    if !state.config.ffprobe_path.is_file() {
        anyhow::bail!(
            "ffprobe unavailable: {}",
            state.config.ffprobe_path.display()
        );
    }
    let output = Command::new(&state.config.ffprobe_path)
        .args([
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=width,height,codec_name,duration:stream_tags=creation_time:format=duration:format_tags=creation_time",
            "-of",
            "json",
        ])
        .arg(path)
        .output()
        .await?;
    if !output.status.success() {
        anyhow::bail!(
            "ffprobe: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    serde_json::from_slice(&output.stdout).context("无法解析 ffprobe 输出")
}

fn apply_probe(probe: ProbeResult, metadata: &mut ExtractedMetadata) {
    if let Some(stream) = probe.streams.first() {
        if stream.width > 0 {
            metadata.width = stream.width;
        }
        if stream.height > 0 {
            metadata.height = stream.height;
        }
        if !stream.codec_name.is_empty() {
            metadata.codec = stream.codec_name.clone();
        }
        metadata.duration_ms = metadata.duration_ms.max(parse_seconds(&stream.duration));
        if let Some(value) = parse_media_time(&stream.tags.creation_time) {
            metadata.captured_at = value;
            metadata.captured_at_source = "container".into();
        }
    }
    metadata.duration_ms = metadata
        .duration_ms
        .max(parse_seconds(&probe.format.duration));
    if metadata.captured_at_source == "modified" {
        if let Some(value) = parse_media_time(&probe.format.tags.creation_time) {
            metadata.captured_at = value;
            metadata.captured_at_source = "container".into();
        }
    }
}

fn exif_ascii(exif: &exif::Exif, tag: Tag) -> Option<String> {
    let field = exif.get_field(tag, In::PRIMARY)?;
    match &field.value {
        Value::Ascii(values) => values
            .first()
            .map(|value| {
                String::from_utf8_lossy(value)
                    .trim_matches(char::from(0))
                    .trim()
                    .to_string()
            })
            .filter(|value| !value.is_empty()),
        _ => None,
    }
}

fn gps_coordinate(value: &Value, reference: &str) -> Option<f64> {
    let Value::Rational(parts) = value else {
        return None;
    };
    if parts.len() < 3 {
        return None;
    }
    let mut coordinate = parts[0].to_f64() + parts[1].to_f64() / 60.0 + parts[2].to_f64() / 3600.0;
    if reference.eq_ignore_ascii_case("S") || reference.eq_ignore_ascii_case("W") {
        coordinate = -coordinate;
    }
    Some(coordinate)
}

fn parse_exif_time(value: &str) -> Option<String> {
    let parsed = NaiveDateTime::parse_from_str(value.trim(), "%Y:%m:%d %H:%M:%S").ok()?;
    Some(
        DateTime::<Utc>::from_naive_utc_and_offset(parsed, Utc)
            .to_rfc3339_opts(SecondsFormat::Nanos, true),
    )
}

fn parse_media_time(value: &str) -> Option<String> {
    let value = value.trim();
    if value.is_empty() {
        return None;
    }
    DateTime::parse_from_rfc3339(value).ok().map(|value| {
        value
            .with_timezone(&Utc)
            .to_rfc3339_opts(SecondsFormat::Nanos, true)
    })
}

fn parse_seconds(value: &str) -> i64 {
    value
        .trim()
        .parse::<f64>()
        .ok()
        .filter(|value| *value > 0.0)
        .map(|value| (value * 1000.0) as i64)
        .unwrap_or_default()
}
