use std::{
    collections::HashMap,
    mem,
    path::{Component, Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
};

use anyhow::Result;
use local_lens_core::{AppConfig, LibraryConfig, MediaItem, ScanStatus, Store};
use tokio::{
    sync::{Notify, RwLock, watch},
    task::JoinHandle,
    time::{Duration, timeout},
};

use crate::pairing::PairingManager;

#[derive(Clone)]
pub struct AppState {
    pub config: Arc<AppConfig>,
    pub store: Store,
    pub libraries: Arc<HashMap<String, LibraryConfig>>,
    pub runtime: Arc<Runtime>,
}

pub struct Runtime {
    pub scan_status: RwLock<ScanStatus>,
    pub scanning: AtomicBool,
    pub shutdown: watch::Sender<bool>,
    pub thumbnail_notify: Notify,
    pub metadata_notify: Notify,
    pub transcode_notify: Notify,
    pub pairing: PairingManager,
    handles: Mutex<Vec<JoinHandle<()>>>,
}

impl Runtime {
    fn new() -> Self {
        let (shutdown, _) = watch::channel(false);
        Self {
            scan_status: RwLock::new(ScanStatus::default()),
            scanning: AtomicBool::new(false),
            shutdown,
            thumbnail_notify: Notify::new(),
            metadata_notify: Notify::new(),
            transcode_notify: Notify::new(),
            pairing: PairingManager::default(),
            handles: Mutex::new(Vec::new()),
        }
    }

    pub fn track(&self, handle: JoinHandle<()>) {
        match self.handles.lock() {
            Ok(mut handles) => handles.push(handle),
            Err(error) => error.into_inner().push(handle),
        }
    }

    pub async fn stop(&self) {
        let _ = self.shutdown.send(true);
        self.thumbnail_notify.notify_waiters();
        self.metadata_notify.notify_waiters();
        self.transcode_notify.notify_waiters();
        let handles = match self.handles.lock() {
            Ok(mut handles) => mem::take(&mut *handles),
            Err(error) => mem::take(&mut *error.into_inner()),
        };
        for handle in handles {
            let _ = timeout(Duration::from_secs(15), handle).await;
        }
        self.scanning.store(false, Ordering::SeqCst);
    }
}

impl AppState {
    pub async fn new(config: AppConfig) -> Result<Self> {
        let store = Store::open(&config.data_dir).await?;
        store.sync_libraries(&config.libraries).await?;
        let libraries = config
            .libraries
            .iter()
            .cloned()
            .map(|library| (library.id.clone(), library))
            .collect();
        Ok(Self {
            config: Arc::new(config),
            store,
            libraries: Arc::new(libraries),
            runtime: Arc::new(Runtime::new()),
        })
    }

    pub async fn start_background(&self) -> Result<()> {
        crate::jobs::start_workers(self.clone());
        if self.config.watch_files {
            crate::scanner::start_watcher(self.clone())?;
        }
        if self.config.auto_scan && !self.libraries.is_empty() {
            crate::scanner::start_scan(self.clone()).await;
        }
        Ok(())
    }

    pub fn media_path(&self, item: &MediaItem) -> Option<PathBuf> {
        let relative = PathBuf::from(&item.relative_path);
        if relative.components().any(|part| {
            matches!(
                part,
                Component::ParentDir | Component::RootDir | Component::Prefix(_)
            )
        }) {
            return None;
        }
        self.libraries
            .get(&item.library_id)
            .map(|library| library.path.join(relative))
    }

    pub fn library_for_path(&self, path: &Path) -> Option<LibraryConfig> {
        self.libraries
            .values()
            .filter(|library| library.enabled && path.starts_with(&library.path))
            .max_by_key(|library| library.path.as_os_str().len())
            .cloned()
    }
}
