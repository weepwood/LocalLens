use std::{
    collections::HashSet,
    path::{Path, PathBuf},
};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use url::Url;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppConfig {
    #[serde(default = "default_listen_address")]
    pub listen_address: String,
    #[serde(default)]
    pub public_url: String,
    #[serde(default = "default_server_name")]
    pub server_name: String,
    #[serde(default = "default_data_dir")]
    pub data_dir: PathBuf,
    #[serde(default)]
    pub api_token: String,
    #[serde(default)]
    pub ffmpeg_path: PathBuf,
    #[serde(default)]
    pub ffprobe_path: PathBuf,
    #[serde(default = "default_true")]
    pub auto_scan: bool,
    #[serde(default = "default_true")]
    pub watch_files: bool,
    #[serde(default = "default_workers")]
    pub thumbnail_workers: usize,
    #[serde(default = "default_workers")]
    pub metadata_workers: usize,
    #[serde(default = "default_transcode_workers")]
    pub transcode_workers: usize,
    #[serde(default = "default_transcode_cache_gb")]
    pub transcode_cache_gb: u64,
    #[serde(default = "default_transcode_hardware")]
    pub transcode_hardware: String,
    #[serde(default = "default_pairing_ttl")]
    pub pairing_ttl_minutes: u64,
    #[serde(default)]
    pub libraries: Vec<LibraryConfig>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LibraryConfig {
    pub id: String,
    pub name: String,
    pub path: PathBuf,
    #[serde(default = "default_true")]
    pub recursive: bool,
    #[serde(default = "default_true")]
    pub enabled: bool,
}

impl AppConfig {
    pub fn load(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref();
        let content = std::fs::read_to_string(path)
            .with_context(|| format!("无法读取配置文件：{}", path.display()))?;
        let mut config: Self = serde_json::from_str(&content)
            .with_context(|| format!("无法解析配置文件：{}", path.display()))?;
        config.normalize(path.parent().unwrap_or_else(|| Path::new(".")))?;
        Ok(config)
    }

    pub fn normalize(&mut self, base: &Path) -> Result<()> {
        if self.listen_address.trim().is_empty() {
            self.listen_address = default_listen_address();
        }
        if self.server_name.trim().is_empty() {
            self.server_name = default_server_name();
        }
        if self.api_token.trim().len() < 16 {
            anyhow::bail!("api_token 至少需要 16 个字符");
        }
        self.thumbnail_workers = self.thumbnail_workers.clamp(1, 8);
        self.metadata_workers = self.metadata_workers.clamp(1, 8);
        self.transcode_workers = self.transcode_workers.clamp(1, 4);
        self.transcode_cache_gb = self.transcode_cache_gb.clamp(1, 500);
        self.pairing_ttl_minutes = self.pairing_ttl_minutes.clamp(1, 60);
        self.transcode_hardware = self.transcode_hardware.trim().to_ascii_lowercase();
        if !matches!(
            self.transcode_hardware.as_str(),
            "software" | "nvenc" | "qsv" | "amf"
        ) {
            anyhow::bail!("transcode_hardware 必须是 software、nvenc、qsv 或 amf");
        }

        self.data_dir = resolve_path(base, &self.data_dir);
        self.ffmpeg_path = resolve_optional_path(base, &self.ffmpeg_path);
        self.ffprobe_path = resolve_optional_path(base, &self.ffprobe_path);
        if self.ffprobe_path.as_os_str().is_empty() && !self.ffmpeg_path.as_os_str().is_empty() {
            let executable = if cfg!(windows) {
                "ffprobe.exe"
            } else {
                "ffprobe"
            };
            self.ffprobe_path = self.ffmpeg_path.parent().unwrap_or(base).join(executable);
        }

        self.public_url = self.public_url.trim().trim_end_matches('/').to_string();
        if self.public_url.is_empty() {
            self.public_url = format!(
                "http://{}",
                self.listen_address.replace("0.0.0.0", "127.0.0.1")
            );
        }
        let public_url = Url::parse(&self.public_url)
            .with_context(|| format!("public_url 不是有效 URL：{}", self.public_url))?;
        if !matches!(public_url.scheme(), "http" | "https") {
            anyhow::bail!("public_url 只支持 http 或 https");
        }
        if public_url.host_str().is_none() {
            anyhow::bail!("public_url 必须包含主机名或 IP 地址");
        }
        if !public_url.username().is_empty() || public_url.password().is_some() {
            anyhow::bail!("public_url 不能包含用户名或密码");
        }
        if public_url.path() != "/"
            || public_url.query().is_some()
            || public_url.fragment().is_some()
        {
            anyhow::bail!("public_url 必须是服务根地址，不能包含路径、查询参数或片段");
        }
        self.public_url = public_url.as_str().trim_end_matches('/').to_string();

        let mut ids = HashSet::new();
        let mut paths = HashSet::new();
        for library in &mut self.libraries {
            library.id = library.id.trim().to_string();
            library.name = library.name.trim().to_string();
            if library.id.is_empty()
                || library.name.is_empty()
                || library.path.as_os_str().is_empty()
            {
                anyhow::bail!("媒体库 id、name 和 path 不能为空");
            }
            library.path = resolve_path(base, &library.path);
            let id_key = library.id.to_ascii_lowercase();
            if !ids.insert(id_key) {
                anyhow::bail!("媒体库 id 重复：{}", library.id);
            }
            let path_key = library.path.to_string_lossy().to_ascii_lowercase();
            if !paths.insert(path_key) {
                anyhow::bail!("多个媒体库不能使用同一个目录：{}", library.path.display());
            }
        }
        Ok(())
    }

    pub fn save(&self, path: impl AsRef<Path>) -> Result<()> {
        let path = path.as_ref();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(path, serde_json::to_string_pretty(self)?)?;
        Ok(())
    }
}

fn resolve_path(base: &Path, path: &Path) -> PathBuf {
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        base.join(path)
    }
}

fn resolve_optional_path(base: &Path, path: &Path) -> PathBuf {
    if path.as_os_str().is_empty() {
        PathBuf::new()
    } else {
        resolve_path(base, path)
    }
}

fn default_listen_address() -> String {
    "0.0.0.0:9527".into()
}
fn default_server_name() -> String {
    "LocalLens".into()
}
fn default_data_dir() -> PathBuf {
    PathBuf::from("./data")
}
fn default_true() -> bool {
    true
}
fn default_workers() -> usize {
    2
}
fn default_transcode_workers() -> usize {
    1
}
fn default_transcode_cache_gb() -> u64 {
    20
}
fn default_transcode_hardware() -> String {
    "software".into()
}
fn default_pairing_ttl() -> u64 {
    5
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_config(public_url: &str) -> AppConfig {
        AppConfig {
            listen_address: "0.0.0.0:9527".into(),
            public_url: public_url.into(),
            server_name: "LocalLens Test".into(),
            data_dir: PathBuf::from("data"),
            api_token: "test-administrator-token-123456".into(),
            ffmpeg_path: PathBuf::new(),
            ffprobe_path: PathBuf::new(),
            auto_scan: false,
            watch_files: false,
            thumbnail_workers: 1,
            metadata_workers: 1,
            transcode_workers: 1,
            transcode_cache_gb: 1,
            transcode_hardware: "software".into(),
            pairing_ttl_minutes: 5,
            libraries: Vec::new(),
        }
    }

    #[test]
    fn accepts_http_service_root() -> Result<()> {
        let root = tempfile::tempdir()?;
        let mut config = test_config("http://192.168.1.20:9527/");
        config.normalize(root.path())?;
        assert_eq!(config.public_url, "http://192.168.1.20:9527");
        Ok(())
    }

    #[test]
    fn rejects_non_root_or_credentialed_public_url() {
        let root = tempfile::tempdir().expect("create temp dir");
        for value in [
            "ftp://192.168.1.20:9527",
            "http://user:pass@192.168.1.20:9527",
            "http://192.168.1.20:9527/api",
            "http://192.168.1.20:9527?token=secret",
            "not-a-url",
        ] {
            let mut config = test_config(value);
            assert!(
                config.normalize(root.path()).is_err(),
                "{value} should fail"
            );
        }
    }
}
