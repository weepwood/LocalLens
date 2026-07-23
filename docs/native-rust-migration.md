# LocalLens 原生 Android 与 Rust 迁移说明

## 当前状态

LocalLens 的新架构迁移已经完成，正式构建链不再依赖 Go、Flutter 或 React Native：

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

旧 Go、Flutter 与 React Native 源码暂时保留为迁移对照，但不进入正式产物。

## 技术边界

### Windows 桌面端

- React + TypeScript + Vite 负责桌面管理界面；
- Tauri 2 负责窗口、安装包、用户目录与 Rust 命令；
- Axum 服务直接运行在 Tauri Rust 进程中，不再启动 Go 子进程；
- 支持启动、停止、查看和重启 Rust 服务；
- 支持编辑服务地址、数据目录、任务 Worker、转码方式和媒体库；
- 首次启动自动识别局域网 IPv4，也可在界面中重新检测公开地址；
- 支持生成一次性配对二维码、显示过期倒计时、查看设备和撤销设备 Token；
- 正式安装包自动携带 FFmpeg 与 FFprobe。

### Android

- Kotlin + Jetpack Compose + Material 3；
- 使用 Google Code Scanner 完成二维码配对，应用本身不直接申请相机权限；
- 使用 Media3 ExoPlayer 播放原始视频或 HLS；
- 支持媒体网格、搜索、分页、筛选、收藏、评分和原图查看；
- 支持共享播放进度；
- 不使用 React Native、Flutter、WebView 或 Go GUI。

### Rust 后端

- 使用 Axum、SQLx、SQLite 和 Tokio；
- 保留原 `/api/v1`、JSON 字段和 Bearer Token 规则；
- 支持全量扫描、增量索引和文件系统监听；
- 支持 EXIF、FFprobe、图片缩略图和视频缩略图；
- 使用持久任务队列处理缩略图、元数据与 HLS；
- 支持相册、标签、文件夹树、收藏、0～5 星评分和播放进度；
- 支持一次性配对、设备 Token、设备列表和撤销；
- 支持 HTTP Range、直接播放协商、字幕发现和 HLS 缓存配额；
- 拒绝路径穿越、绝对路径和媒体库根目录之外的访问。

## 配置与局域网

`public_url` 用于写入二维码，必须满足：

- 使用 `http` 或 `https`；
- 包含主机名或 IP；
- 是服务根地址；
- 不包含用户名、密码、路径、查询参数或片段。

示例：

```json
{
  "listen_address": "0.0.0.0:9527",
  "public_url": "http://192.168.1.20:9527"
}
```

首次安装会尝试自动识别 Windows 局域网 IPv4。网络环境变化后，可在 Tauri 管理端点击“自动检测”，保存配置后重新生成二维码。

只应在 Windows 专用网络中放行 9527 端口，不应直接暴露到公网。远程访问建议使用可信 VPN。

## 数据升级

Rust 后端继续读取原来的 `config.json` 与 `data/locallens.db`。首次打开旧数据库时：

1. 在 `data/backups/` 创建迁移前备份；
2. 同时备份存在的 WAL 与 SHM 文件；
3. 原地补齐表、字段和索引；
4. 保留媒体索引、收藏、评分、相册、标签、设备和播放进度；
5. 写入一次性迁移标记，防止重复备份。

新旧后端不能同时写入同一数据库。切换前必须停止旧 Go 服务，并建议额外备份整个 `data` 目录。

## 自动化验证

CI 当前执行：

- `cargo fmt --check`；
- Clippy，启用 `-D warnings`；
- Rust Workspace 单元测试与接口回归；
- 旧 SQLite 原地升级和备份测试；
- 真实临时媒体库扫描、缩略图和路径边界测试；
- 收藏、评分、相册、标签和共享播放进度测试；
- 二维码 PNG、一次性配对、设备 Token、设备列表和撤销失效测试；
- 现场生成真实 H.264 MP4；
- FFprobe 尺寸、时长和编码提取；
- HTTP Range 206 响应；
- SRT 字幕发现与读取；
- 直接播放协商；
- FFmpeg HLS 转码、播放列表和诊断接口；
- Tauri React 构建和 Windows Rust 宿主检查；
- Kotlin 原生 Android APK 构建；
- Tauri MSI、NSIS 和独立 Rust 服务包构建。

## 正式构建产物

正式工作流生成：

- Tauri 2 Windows MSI；
- Tauri 2 Windows NSIS 安装程序；
- `LocalLens-Rust-Server-Windows-x64.zip`；
- `LocalLens-Native-Android.apk`；
- `SHA256SUMS.txt`。

独立 Rust 服务包包含服务程序、配置模板、FFmpeg、FFprobe 和第三方许可证说明。

## 仍需外部凭据完成的事项

代码迁移和功能对等已经完成，但公开分发前仍需要由项目维护者提供签名材料：

- Android 正式 keystore 与密码；
- Windows Authenticode 代码签名证书；
- 后续自动更新包的签名密钥。

没有签名材料时，CI 仍可生成用于测试和侧载的 APK、MSI 与 NSIS，但 Windows 可能显示未知发布者，Android 产物也不适合直接提交应用商店。

## 旧实现清理策略

以下目录暂时保留为回归参考：

- `server/`：旧 Go 服务；
- `apps/local_lens/`：旧 Flutter 客户端；
- `apps/local_lens_mobile/`：React Native 试验实现。

建议在新架构合并、完成真实 Windows 媒体库试运行并确认数据备份可恢复后，再通过独立 PR 删除旧实现，避免把架构迁移与历史清理混在同一个变更中。
