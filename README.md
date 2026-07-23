# LocalLens

LocalLens 是一个本地优先的图片与视频管理系统。媒体原文件保存在用户选择的 Windows 文件夹中，LocalLens 只维护 SQLite 索引、缩略图、元数据、播放记录和虚拟分类。

当前正式架构：

- Windows 桌面端：Tauri 2 + React + TypeScript；
- 后端处理：Rust + Axum + SQLx + SQLite；
- Android：Kotlin + Jetpack Compose 原生应用；
- 媒体工具：FFmpeg / FFprobe；
- 局域网协议：兼容原有 `/api/v1` REST API。

> `server/`、`apps/local_lens/` 和 `apps/local_lens_mobile/` 中的旧 Go、Flutter 与 React Native 实现暂时保留为迁移对照，不再作为正式架构或发布产物。

## 功能

### Rust 后端

- 全量扫描、增量索引和文件系统实时监听；
- 文件事件防抖，大文件稳定后再写入索引；
- 旧版 `locallens.db` 原地升级；
- 首次 Rust 迁移前自动备份数据库、WAL 和 SHM；
- SQLite WAL、外键、忙等待和有限连接池；
- 持久化缩略图、元数据和转码任务队列；
- 服务重启后恢复未完成任务；
- 原生图片缩略图，失败时回退 FFmpeg；
- EXIF 拍摄时间、GPS 和相机型号；
- FFprobe 视频时长、尺寸、编码与容器时间；
- HTTP Range 原始视频流；
- 直接播放能力协商；
- HLS 转码、字幕发现和转码缓存配额；
- 文件夹树、收藏、0～5 星评分、相册和标签；
- 跨设备共享播放进度；
- 一次性二维码配对、设备 Token、设备列表和撤销；
- 管理员接口与设备接口权限隔离；
- 媒体根目录边界与路径穿越防护。

### Tauri 2 Windows 桌面端

- Rust/Axum 服务直接运行在 Tauri 进程内；
- 不再启动外部 Go 服务进程；
- 查看、启动、停止和重启本地服务；
- 编辑局域网地址、数据目录、任务 Worker、转码方式与媒体库；
- 首次启动自动检测 Windows 局域网 IPv4；
- 支持手动重新检测公开地址；
- 生成一次性配对二维码并显示过期倒计时；
- 查看已配对设备和最近连接时间；
- 撤销设备 Token；
- 自动创建配置和数据目录；
- 正式构建自动携带 FFmpeg 与 FFprobe；
- 生成 MSI 和 NSIS Windows 安装包；
- 另行生成 Rust 独立服务压缩包。

### Kotlin 原生 Android

- Jetpack Compose + Material 3；
- 不使用 Flutter、React Native、WebView 或 Go GUI；
- Google Code Scanner 一次性二维码配对；
- 扫码由 Google Play 服务提供，应用自身不请求相机权限；
- 手动填写服务地址和 Token；
- 媒体网格、搜索、图片/视频/收藏筛选；
- 游标分页加载；
- 收藏和 0～5 星评分；
- 原图查看；
- Media3 ExoPlayer 视频播放；
- 直接播放与 HLS 自动协商；
- 带 Bearer Token 的图片和视频请求；
- 跨设备播放进度读取和保存；
- 手机和平板自适应布局。

## 架构

```text
Windows 本地媒体文件夹
        ↓
Rust Core
├── 扫描与文件监听
├── SQLx / SQLite
├── EXIF / FFprobe
├── 缩略图与任务队列
├── HLS 转码与缓存
├── 配对与设备令牌
└── Axum REST API
        ↓
Tauri 2 Windows 管理端
        ↓ 局域网
Kotlin / Jetpack Compose Android 客户端
```

## 仓库结构

```text
LocalLens/
├── rust/
│   └── crates/
│       ├── local-lens-core/       # 配置、模型、数据库与任务队列
│       └── local-lens-server/     # Axum、扫描、监听、元数据、配对与转码
├── apps/
│   ├── local_lens_desktop/        # Tauri 2 Windows 管理端
│   └── local_lens_android/        # Kotlin 原生 Android
├── server/                        # 旧 Go 实现，仅作迁移对照
├── apps/local_lens/               # 旧 Flutter 实现，仅作迁移对照
├── apps/local_lens_mobile/        # React Native 试验实现，仅作迁移对照
└── docs/
```

## 正式构建产物

GitHub Actions 只生成：

- Tauri 2 Windows MSI；
- Tauri 2 Windows NSIS 安装程序；
- `LocalLens-Rust-Server-Windows-x64.zip`；
- `LocalLens-Native-Android.apk`；
- `SHA256SUMS.txt`。

新流程不再构建 Go 服务、Flutter 客户端或 React Native 客户端。

## 从源码运行 Rust 服务

复制示例配置，或新建 `config.json`：

```json
{
  "listen_address": "0.0.0.0:9527",
  "public_url": "http://192.168.1.20:9527",
  "server_name": "Home LocalLens",
  "data_dir": "./data",
  "api_token": "replace-with-a-long-random-token",
  "ffmpeg_path": "./bin/ffmpeg.exe",
  "ffprobe_path": "./bin/ffprobe.exe",
  "auto_scan": true,
  "watch_files": true,
  "thumbnail_workers": 2,
  "metadata_workers": 2,
  "transcode_workers": 1,
  "transcode_cache_gb": 20,
  "transcode_hardware": "software",
  "pairing_ttl_minutes": 5,
  "libraries": [
    {
      "id": "main-media",
      "name": "媒体库",
      "path": "D:\\Media",
      "recursive": true,
      "enabled": true
    }
  ]
}
```

启动：

```powershell
cargo run --manifest-path .\rust\Cargo.toml `
  -p local-lens-server --bin local-lens-server -- `
  -config .\config.json
```

检查：

```powershell
Invoke-RestMethod http://127.0.0.1:9527/api/v1/health
```

`public_url` 必须是 Android 能访问的 HTTP/HTTPS 服务根地址，不能包含路径、查询参数、账号或密码。Tauri 桌面端可以自动检测局域网地址。

## 数据升级

Rust 后端继续使用原有 `data/locallens.db`，不要求重新扫描后才能保留收藏、评分、相册、标签、设备和播放记录。

首次由 Rust 打开旧数据库时会：

1. 在 `data/backups/` 创建迁移前备份；
2. 同时备份存在的 `locallens.db-wal` 和 `locallens.db-shm`；
3. 原地补齐 Rust 需要的表、列和索引；
4. 写入 `.rust-backend-migration-v1`，避免后续重复备份。

大规模正式切换前仍建议完整备份 `data` 目录和媒体配置。旧 Go 服务与 Rust 服务不能同时写入同一数据库。

## Windows 防火墙

只为专用网络放行：

```powershell
New-NetFirewallRule `
  -DisplayName "LocalLens Media Server" `
  -Direction Inbound `
  -Action Allow `
  -Protocol TCP `
  -LocalPort 9527 `
  -Profile Private
```

不要直接把 `9527` 暴露到公网。远程访问优先使用 Tailscale、WireGuard 等可信 VPN。

## 安全边界

- 客户端只接收媒体 ID 和相对路径；
- 后端只允许读取配置中的媒体根目录；
- 包含 `..`、绝对路径或 Windows 路径前缀的媒体路径会被拒绝；
- Token 只以 SHA-256 哈希保存在设备表；
- 一次性配对密钥使用后立即失效；
- 设备 Token 不能启动扫描、生成二维码或撤销其他设备；
- 相册、标签、收藏和评分不会修改原始文件；
- 当前不提供远程删除、移动或重命名原始文件的接口。

## 自动化验证

CI 会执行：

- `cargo fmt --check`；
- Clippy，启用 `-D warnings`；
- Rust Workspace 测试；
- 旧 SQLite 原地升级与备份测试；
- 临时真实媒体库扫描和缩略图测试；
- 收藏、评分、相册、标签和播放进度测试；
- 二维码 PNG、一次性配对、设备列表和撤销失效测试；
- 路径穿越拦截测试；
- 现场生成真实 H.264 MP4；
- FFprobe 元数据、HTTP Range、字幕发现、直接播放和 HLS 转码测试；
- Tauri React 构建、Rust 宿主检查和安装包构建；
- Kotlin 原生 Android APK 构建。

## 当前发布限制

- Android APK 当前使用开发签名，只适合测试和侧载；
- Windows 安装包尚未进行 Authenticode 签名，可能显示未知发布者；
- 正式商店发布需要维护者提供 Android keystore、Windows 代码签名证书和更新签名密钥；
- Windows FFmpeg 是独立第三方程序，发布时必须保留来源和许可证说明；
- iOS 客户端不在当前迁移范围内。

详见 [API 文档](docs/api.md)、[架构文档](docs/architecture.md) 和 [Rust 迁移说明](docs/native-rust-migration.md)。
