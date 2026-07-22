# LocalLens 原生 Android 与 Rust 迁移方案

## 目标架构

```text
Windows 本地文件夹
        ↓
Rust LocalLens Core
├── SQLite 兼容与迁移
├── 文件扫描与实时监听
├── FFmpeg / FFprobe 调用
├── 缩略图与元数据任务
├── Axum REST API
└── 配对、设备与播放进度
        ↓
Tauri 2 Windows 管理端     Kotlin / Jetpack Compose Android 客户端
```

## 技术边界

### 桌面端

- React + TypeScript + Vite 负责桌面管理界面；
- Tauri 2 负责窗口、安装包、用户目录和 Rust 命令；
- Axum 服务直接运行在 Tauri Rust 进程中，不再启动 Go 子进程；
- 桌面端可以停止、启动和查看本地 Rust 服务状态。

### Android

- Kotlin 与 Jetpack Compose 构建标准 Android 原生 UI；
- 使用 Android 生命周期、权限、后台服务和系统媒体能力；
- 不使用 React Native、Flutter、WebView 或 Go GUI；
- 只通过 `/api/v1` 访问 Windows Rust 服务。

### 数据与协议

- 继续使用原来的 `config.json` 字段；
- 继续读取原来的 `data/locallens.db`；
- 保留 `/api/v1` URL、JSON 字段和 Bearer Token 规则；
- 新旧后端不可同时写入同一数据库；迁移期间必须确保 Go 服务已停止。

## 当前已完成

- Rust workspace 与共享领域模型；
- 兼容旧 SQLite 的连接、媒体查询、统计、收藏和评分；
- Axum 的 health、server、libraries、stats、media、favorite、rating 与文件流接口；
- Tauri 2 桌面管理程序和 Rust 服务生命周期管理；
- Kotlin/Compose 原生 Android 连接、网格、搜索、筛选、收藏和图片预览；
- 新的 Windows、Rust 和 Android 构建流程。

## 迁移阶段

### 阶段 1：双实现验证

保留旧 Go/Flutter 源码用于回归比较，但正式构建改为 Rust/Tauri/Android。重点验证：

1. 原数据库能否直接打开；
2. 媒体数量、收藏和评分是否一致；
3. 图片与视频 Range 响应是否兼容；
4. Android 在真实局域网中的连接和鉴权；
5. Tauri 关闭时 Rust 服务能否正常停止。

### 阶段 2：Rust 后台任务迁移

依次迁移：

1. 全量扫描与增量扫描；
2. notify 文件系统监听；
3. FFprobe/EXIF 元数据提取；
4. 缩略图持久队列；
5. 视频转码和缓存；
6. 配对、设备 Token 和撤销；
7. 相册、标签、播放进度与目录接口。

### 阶段 3：删除旧实现

只有在 Rust API 契约测试与旧实现结果一致、现有数据库完成备份，并通过真实媒体库验证后，才删除：

- `server/` Go 服务；
- `apps/local_lens/` Flutter 客户端；
- `apps/local_lens_mobile/` React Native 试验实现。

## 安全要求

- 9527 端口只允许 Windows 专用网络；
- Android Token 不写入日志；
- 服务端必须拒绝包含 `..`、盘符或绝对路径的媒体路径；
- Rust 服务只能读取配置声明的媒体根目录；
- 正式版本需要 Android 签名、Tauri 代码签名和更新包签名；
- 切换后端前备份 `config.json` 和整个 `data` 目录。
