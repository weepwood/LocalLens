use std::{collections::HashMap, io::Cursor};

use anyhow::{Context, Result};
use chrono::{DateTime, Duration, SecondsFormat, Utc};
use image::{DynamicImage, GrayImage, ImageFormat, Luma};
use local_lens_core::{random_id, Device};
use qrcode::{Color, QrCode};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::sync::Mutex;

use crate::runtime::AppState;

#[derive(Debug, Clone)]
struct PairingSession {
    secret_hash: String,
    payload: String,
    expires_at: DateTime<Utc>,
}

#[derive(Default)]
pub struct PairingManager {
    sessions: Mutex<HashMap<String, PairingSession>>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingSessionResponse {
    pub id: String,
    pub payload: String,
    pub expires_at: String,
    pub qr_url: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingClaim {
    pub pairing_id: String,
    pub secret: String,
    pub device_name: String,
    #[serde(default)]
    pub platform: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct PairingPayload {
    version: i64,
    base_url: String,
    server_name: String,
    pairing_id: String,
    secret: String,
    expires_at: String,
}

impl PairingManager {
    pub async fn create(
        &self,
        state: &AppState,
        base_url: &str,
    ) -> Result<PairingSessionResponse> {
        let id = random_id();
        let secret = format!("{}{}", random_id(), random_id());
        let expires_at = Utc::now()
            + Duration::minutes(i64::try_from(state.config.pairing_ttl_minutes).unwrap_or(5));
        let payload = serde_json::to_string(&PairingPayload {
            version: 1,
            base_url: base_url.trim_end_matches('/').into(),
            server_name: state.config.server_name.clone(),
            pairing_id: id.clone(),
            secret: secret.clone(),
            expires_at: expires_at.to_rfc3339_opts(SecondsFormat::Nanos, true),
        })?;
        let mut sessions = self.sessions.lock().await;
        remove_expired(&mut sessions);
        sessions.insert(
            id.clone(),
            PairingSession {
                secret_hash: hash_token(&secret),
                payload: payload.clone(),
                expires_at,
            },
        );
        Ok(PairingSessionResponse {
            id: id.clone(),
            payload,
            expires_at: expires_at.to_rfc3339_opts(SecondsFormat::Nanos, true),
            qr_url: format!("/api/v1/pairing/session/{id}/qr"),
        })
    }

    pub async fn qr_png(&self, session_id: &str) -> Result<Vec<u8>> {
        let payload = {
            let mut sessions = self.sessions.lock().await;
            remove_expired(&mut sessions);
            sessions
                .get(session_id)
                .map(|session| session.payload.clone())
                .context("配对会话不存在或已过期")?
        };
        render_qr(&payload)
    }

    pub async fn claim(&self, state: &AppState, claim: PairingClaim) -> Result<(Device, String)> {
        let pairing_id = claim.pairing_id.trim();
        let secret = claim.secret.trim();
        let device_name = claim.device_name.trim();
        if pairing_id.is_empty() || secret.is_empty() || device_name.is_empty() {
            anyhow::bail!("pairingId、secret 和 deviceName 不能为空");
        }
        {
            let mut sessions = self.sessions.lock().await;
            remove_expired(&mut sessions);
            let session = sessions
                .get(pairing_id)
                .context("配对会话不存在或已过期")?;
            if session.secret_hash != hash_token(secret) {
                anyhow::bail!("配对密钥无效");
            }
            sessions.remove(pairing_id);
        }
        let token = format!("{}{}", random_id(), random_id());
        let device = state
            .store
            .create_device(device_name, claim.platform.trim(), &token)
            .await?;
        Ok((device, token))
    }
}

fn remove_expired(sessions: &mut HashMap<String, PairingSession>) {
    let now = Utc::now();
    sessions.retain(|_, session| session.expires_at > now);
}

fn render_qr(payload: &str) -> Result<Vec<u8>> {
    let code = QrCode::new(payload.as_bytes())?;
    let modules = u32::try_from(code.width()).unwrap_or(21);
    let border = 4_u32;
    let scale = (384 / (modules + border * 2)).max(1);
    let size = (modules + border * 2) * scale;
    let mut image = GrayImage::from_pixel(size, size, Luma([255]));
    for y in 0..modules {
        for x in 0..modules {
            if code[(x as usize, y as usize)] != Color::Dark {
                continue;
            }
            let left = (x + border) * scale;
            let top = (y + border) * scale;
            for dy in 0..scale {
                for dx in 0..scale {
                    image.put_pixel(left + dx, top + dy, Luma([0]));
                }
            }
        }
    }
    let mut output = Cursor::new(Vec::new());
    DynamicImage::ImageLuma8(image).write_to(&mut output, ImageFormat::Png)?;
    Ok(output.into_inner())
}

fn hash_token(value: &str) -> String {
    hex::encode(Sha256::digest(value.as_bytes()))
}
