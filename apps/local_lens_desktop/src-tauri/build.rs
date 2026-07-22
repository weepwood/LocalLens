use std::{fs, path::Path};

use base64::{engine::general_purpose::STANDARD, Engine};

const DEFAULT_ICON: &str = "AAABAAEAICAAAAAAIADyAAAAFgAAAIlQTkcNChoKAAAADUlIRFIAAAAgAAAAIAgGAAAAc3p69AAAALlJREFUeJztVkEKgDAMi+JjfI++QB/mD3yP/kZPA6nTJXMwhAZ2GbVNuyyzGabtQEW0NYs7ASfgBACgy/1wXfrb3jjvcp5GNaJY4S9EpCNgiitxgDABmzTWJRNjQU2ATWz3mUnItyDVlSrEJIFrF7EOw3oikZpCtg/YxIrwihAohf8SsHrIcUGA9IE3IX6NlyeQEpsqRooAazA5Tig9Rkp3rCakI2CTKoKUn+OAav8DpfFfI3ICTqAUTo2PUlR+dzbsAAAAAElFTkSuQmCC";

fn ensure_windows_icon() {
    let icon_path = Path::new("icons/icon.ico");
    if icon_path.is_file() {
        return;
    }
    if let Some(parent) = icon_path.parent() {
        fs::create_dir_all(parent).expect("创建 Tauri 图标目录失败");
    }
    let bytes = STANDARD.decode(DEFAULT_ICON).expect("解析默认图标失败");
    fs::write(icon_path, bytes).expect("写入默认 Windows 图标失败");
}

fn main() {
    ensure_windows_icon();
    tauri_build::build()
}
