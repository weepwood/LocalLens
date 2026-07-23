# LocalLens 原生 Android 与 Rust 迁移说明

## 当前状态

LocalLens 的架构迁移与旧实现清理已经完成：

```text
Windows 本地文件夹
        ↓
Rust LocalLens Core
├── SQLite 兼容、备份与原地升级
├── 文件扫描、增量索引与实时监听
├── EXIF / FFprobe 元数据
├── 缩略图、元数据与转码持久任务队列
├── HLS 转码、字幕与缓存治理
├── 配对、设备 Token 与共享播放进度
└── Axum REST API
        ↓
Tauri 2 Windows 管理端     Kotlin / Jetpack Compose Android 客户端
```

旧 Go、Flutter 与 React Native 源码不再保留在当前工作树。迁移前实现仍可通过 Git 历史和历史 Release 追溯。

## 技术边界

### Windows 桌面端

- React + TypeScript + Vite 负责管理界面；
- Tauri 2 负责窗口、安装包、用户目录和 Rust 命令；
- Axum 服务直接运行在 Tauri Rust 进程中；
- 支持启动、停止、查看和重启 Rust 服务；
- 支持编辑服务地址、数据目录、任务 Worker、转码方式和媒体库；
- 自动识别局域网 IPv4，也可在界面中重新检测；
- 支持生成一次性配对二维码、查看设备和撤销设备 Token；
- 正式安装包携带 FFmpeg 与 FFprobe。

### Android

- Kotlin + Jetpack Compose + Material 3；
- 使用 Google Code Scanner 完成二维码配对；
- 使用 Media3 ExoPlayer 播放原始视频或 HLS；
- 支持媒体网格、搜索、分页、筛选、收藏、评分和原图查看；
- 支持共享播放进度。

### Rust 后端

- 使用 Axum、SQLx、SQLite 和 Tokio；
- 保留 `/api/v1`、JSON 字段和 Bearer Token 规则；
- 支持全量扫描、增量索引和文件系统监听；
- 支持 EXIF、FFprobe、图片缩略图和视频缩略图；
- 使用持久任务队列处理缩略图、元数据和 HLS；
- 支持相册、标签、文件夹树、收藏、评分和播放进度；
- 支持一次性配对、设备 Token、设备列表和撤销；
- 支持 HTTP Range、直接播放协商、字幕发现和 HLS 缓存配额；
- 拒绝路径穿越、绝对路径和媒体库根目录之外的访问。

## 配置迁移

配置模板已经从旧服务目录迁移到仓库根目录：

```text
config.example.json
```

复制为 `config.json` 后填写：

- `listen_address`；
- `public_url`；
- `data_dir`；
- `api_token`；
- FFmpeg 与 FFprobe 路径；
- 媒体库目录；
- 后台 Worker 与转码配置。

`public_url` 必须使用 `http` 或 `https`，包含主机名或 IP，并且不能包含用户名、密码、路径、查询参数或片段。

## 数据升级

Rust 后端继续读取原来的 `config.json` 与 `data/locallens.db`。首次打开旧数据库时：

1. 在 `data/backups/` 创建迁移前备份；
2. 同时备份存在的 WAL 与 SHM 文件；
3. 原地补齐表、字段和索引；
4. 保留媒体索引、收藏、评分、相册、标签、设备和播放进度；
5. 写入一次性迁移标记，防止重复备份。

切换正式版本前仍建议额外备份整个 `data` 目录。

## 自动化验证

CI 当前执行：

- Rust 与 Tauri `cargo fmt --check`；
- Clippy `-D warnings`；
- Rust Workspace 单元测试与接口回归；
- 旧 SQLite 原地升级和备份测试；
- 真实临时媒体库扫描、缩略图和路径边界测试；
- 收藏、评分、相册、标签和共享播放进度测试；
- 二维码 PNG、一次性配对、设备 Token、设备列表和撤销失效测试；
- 真实 H.264 MP4 生成；
- FFprobe、HTTP Range、字幕、直接播放和 HLS 转码测试；
- Tauri React 构建、Windows Rust 宿主检查和安装包构建；
- Kotlin 原生 Android APK 构建；
- 旧实现目录和残留路径引用检查。

## 正式构建产物

正式工作流生成：

- Tauri 2 Windows MSI；
- Tauri 2 Windows NSIS 安装程序；
- `LocalLens-Rust-Server-Windows-x64.zip`；
- `LocalLens-Native-Android.apk`；
- `SHA256SUMS.txt`。

独立 Rust 服务包包含服务程序、根目录配置模板、FFmpeg、FFprobe 和第三方许可证说明。

## 仍需外部凭据完成的事项

公开分发前仍需要项目维护者提供：

- Android 正式 keystore 与密码；
- Windows Authenticode 代码签名证书；
- 自动更新包签名密钥。

没有签名材料时，CI 生成的 APK、MSI 和 NSIS 只适合测试和侧载。