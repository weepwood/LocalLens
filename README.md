# LocalLens

LocalLens 是一个本地优先的跨平台图片与视频媒体库。Windows 应用内置 Go 服务端，负责扫描本地媒体、生成索引和缩略图；Windows 与 Android 客户端通过本机或局域网浏览、播放和管理媒体。

> 当前版本：`v0.6.x`。原始媒体始终保存在用户选择的文件夹中，LocalLens 只维护 SQLite 索引、缩略图、元数据、转码缓存和虚拟分类。

## 推荐下载

普通 Windows 用户只需要下载：

- **`LocalLens-Windows-x64.zip`**：Windows 一体化应用，已经包含客户端和 Go 服务端；
- `LocalLens-Android-universal.apk`：Android 客户端，通过局域网连接 Windows；
- `SHA256SUMS.txt`：发布文件校验值。

从 [GitHub Releases](https://github.com/weepwood/LocalLens/releases) 下载正式版本。

`LocalLens-Server-Windows-x64.zip` 是面向高级部署的独立服务端，不是普通 Windows 用户的首选下载。

## Windows 一体化包

完整压缩包应包含以下结构：

```text
LocalLens-Windows-x64/
├── LocalLens.exe
├── flutter_windows.dll
├── data/
├── BUNDLE-MANIFEST.json
└── runtime/
    ├── LocalLensServer.exe
    └── media-tools/
        └── README.txt
```

请完整解压 ZIP，然后只启动 `LocalLens.exe`。不要只复制 EXE，也不要直接运行 `runtime/LocalLensServer.exe`。

如果解压目录中没有 `runtime/LocalLensServer.exe`，说明下载的不是完整的一体化 Windows 包。

## 首次启动

Windows 首次启动会进入“设置本机 LocalLens”向导：

1. 设置服务器名称和媒体库名称；
2. 选择图片与视频目录；
3. 设置端口，默认 `9527`；
4. 选择是否允许手机和其他局域网设备访问；
5. 客户端自动生成管理员 Token；
6. 自动创建配置、启动内置服务端并完成健康检查；
7. 健康检查成功后进入媒体库。

本机客户端始终通过 `127.0.0.1` 访问内置服务端。开启局域网访问后，Android 等设备可以通过 Windows 的局域网地址连接。

配置和运行数据保存在：

```text
%LOCALAPPDATA%\LocalLens\
├── config\server.json
├── config\server.json.backup
├── data\
├── cache\
├── logs\server.log
└── runtime\server.pid
```

## 从旧版本升级

旧版 Windows 客户端只保存服务器地址和 Token，没有记录“本机”或“远程”运行模式。

升级到新版一体化包后，应用会要求选择：

- **使用本机内置服务器**：进入本地媒体目录设置向导；
- **继续连接原来的服务器**：保留原服务器地址和 Token。

选择本机模式不会删除原服务器上的任何文件或数据库。

## 主要功能

### 内置 Go 服务端

- 使用 `fsnotify` 递归监听新增、修改、删除和重命名；
- 启动校验、手动全量扫描和实时增量索引；
- SQLite 版本迁移和持久任务队列；
- 图片 EXIF、视频 FFprobe 元数据提取；
- 按真实拍摄时间建立时间线；
- 文件夹树、收藏、评分、相册和标签；
- HTTP Range 视频播放和按需 HLS 转码；
- 外部字幕发现和播放能力协商；
- 跨设备播放进度；
- 一次性二维码配对和独立设备 Token；
- Token 只以 SHA-256 哈希保存在 SQLite 中。

### Flutter Windows / Android

- 图片和视频时间线；
- 与服务端一致的物理目录树；
- 搜索、游标分页和媒体筛选；
- 收藏、评分、相册和标签；
- 全屏图片浏览和胶片导航；
- Direct Play 与 1080p / 720p / 480p 兼容播放；
- Windows 与手机跨设备续播；
- Windows 可视化服务器设置；
- 手机扫码配对和设备撤销。

## 架构

```text
Windows 本地文件夹
        ↓
LocalLens.exe
├── Flutter Windows 界面
└── runtime/LocalLensServer.exe
    ├── fsnotify 文件监听
    ├── SQLite 索引与迁移
    ├── 元数据与缩略图任务
    ├── FFprobe / EXIF
    ├── Direct Play / HLS
    ├── 文件夹、时间线与集合
    └── 配对与设备令牌
        ↓ 局域网
Flutter Android 客户端
```

## FFmpeg

为控制安装包体积和第三方二进制分发，Windows 一体化包默认不包含 FFmpeg。

需要视频缩略图、更多格式元数据或 HLS 转码时，将以下文件放入：

```text
runtime\media-tools\ffmpeg.exe
runtime\media-tools\ffprobe.exe
```

缺少 FFmpeg **不会导致内置 Go 服务端缺失或无法启动**。JPEG、PNG 和 GIF 的常见图片缩略图可以使用原生 Go 实现生成。

如果首次创建配置时还没有放入 FFmpeg，可在本机服务器设置中配置路径后重启服务端。

## Android 配对

1. Windows 应用进入“服务器与设备”；
2. 生成一次性配对二维码；
3. Android 首次启动选择扫码配对；
4. 服务端签发只属于该设备的 Token。

设备 Token 可以浏览和管理媒体，但不能创建配对码、启动全量扫描或撤销其他设备。

## 高级部署：独立 Windows 服务端

仅在需要把服务端与 Windows 客户端分开运行时，下载 `LocalLens-Server-Windows-x64.zip`。

```powershell
Copy-Item config.example.json config.json
.\LocalLensServer.exe -config .\config.json
```

健康检查：

```powershell
Invoke-RestMethod http://127.0.0.1:9527/api/v1/health
```

只为 Windows 专用网络放行服务端口，不要直接将端口映射到公网。远程访问优先使用 Tailscale、WireGuard 等可信 VPN。

## 仓库结构

```text
LocalLens/
├── server/                    # Go 媒体服务端
├── apps/local_lens/           # Flutter Windows / Android 应用
├── docs/                      # 架构、API 和发布文档
└── .github/workflows/         # 构建、验证和 Release
```

## 发布质量保证

CI 会执行：

- Go 单元测试；
- Flutter 测试和静态分析；
- 构建独立服务端和无控制台内置服务端；
- 将内置服务端复制到最终 Windows ZIP；
- 校验 `BUNDLE-MANIFEST.json` 和必要文件；
- 解压最终 ZIP，真实启动其中的 Go 服务端；
- 轮询 `/api/v1/health`，通过后才允许上传发布资产。

## 文件安全边界

- 客户端只接收媒体 ID 和相对路径，不接收 Windows 绝对路径；
- 服务端只读取配置中的媒体根目录；
- 收藏、评分、相册和标签不会修改原始文件；
- 当前不提供远程删除、移动和重命名原始文件的接口；
- 外接磁盘暂时不可用时，索引会标记缺失，不会删除原始数据。

## 当前限制

- HEIC、RAW 等格式的缩略图能力取决于 FFmpeg 构建；
- 局域网模式当前仍使用 HTTP；
- Android Release APK 当前使用开发签名，不适合直接提交应用商店；
- 退出 `LocalLens.exe` 会停止由它托管的内置服务端；
- Windows 托盘常驻、登录自启动和可选 Windows Service 尚未实现。

详见 [API 文档](docs/api.md)、[架构文档](docs/architecture.md)、[v0.6 说明](docs/v0.6.0.md) 和 [发布说明](docs/releasing.md)。
