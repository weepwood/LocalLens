# LocalLens

LocalLens 是一个本地优先的跨平台图片与视频媒体库。Windows 应用内置 Go 服务端和 FFmpeg，负责扫描本地媒体、生成索引、缩略图和兼容播放内容；Windows 与 Android 客户端通过本机或局域网浏览、播放和管理媒体。

> 当前版本：`v0.6.x`。原始媒体始终保存在用户选择的媒体文件夹中，LocalLens 只维护 SQLite 索引、缩略图、元数据、转码缓存和虚拟分类。

## 推荐下载

普通 Windows 用户只需要下载：

- **`LocalLens-Windows-x64.zip`**：Windows 一体化应用，包含客户端、Go 服务端、FFmpeg 和 FFprobe；
- `LocalLens-Android-universal.apk`：Android 客户端，通过局域网连接 Windows；
- `SHA256SUMS.txt`：发布文件校验值。

从 [GitHub Releases](https://github.com/weepwood/LocalLens/releases) 下载正式版本。

`LocalLens-Server-Windows-x64.zip` 是面向高级部署的独立服务端，不是普通 Windows 用户的首选下载。

## Windows 一体化包

完整压缩包应包含以下结构：

```text
LocalLens-Windows-x64.zip
├── LocalLens.exe
├── flutter_windows.dll
├── data/
├── BUNDLE-MANIFEST.json
└── runtime/
    ├── LocalLensServer.exe
    └── media-tools/
        ├── ffmpeg.exe
        ├── ffprobe.exe
        └── FFMPEG-NOTICE.txt
```

请完整解压 ZIP，然后只启动 `LocalLens.exe`。不要只复制 EXE，也不要直接运行 `runtime/LocalLensServer.exe`。

如果解压目录中没有 `runtime/LocalLensServer.exe`、`ffmpeg.exe` 或 `ffprobe.exe`，说明下载或解压的不是完整 Windows 一体化包。

## 首次启动

Windows 首次启动会进入“设置本机 LocalLens”向导：

1. 设置服务器名称和媒体库名称；
2. 选择原始图片和视频目录；
3. 选择 LocalLens 数据目录；
4. 设置端口，默认 `9527`；
5. 选择是否允许手机和其他局域网设备访问；
6. 客户端自动生成管理员 Token；
7. 自动创建配置、启动内置服务端并完成健康检查；
8. 健康检查成功后进入媒体库。

本机客户端始终通过 `127.0.0.1` 访问内置服务端。开启局域网访问后，Android 等设备可以通过 Windows 的局域网地址连接。

### 媒体目录和数据目录必须分开

媒体目录保存用户自己的原始图片和视频。LocalLens 数据目录保存：

```text
LocalLensData/
├── .locallens-data-root.json
├── config/
│   ├── server.json
│   └── server.json.backup
├── data/                 # SQLite 数据库和服务端数据
├── cache/                # 缩略图和转码缓存
├── logs/server.log
└── runtime/server.pid
```

选择数据目录时，应用会在所选上级目录中创建独立的 `LocalLensData` 子目录。媒体目录和数据目录不能相同，也不能互相包含，从而避免扫描自身缓存或清理时影响原始媒体。

默认数据目录是：

```text
%LOCALAPPDATA%\LocalLens
```

当用户选择其他目录时，应用只在以下固定位置保存一个很小的目录指针：

```text
%LOCALAPPDATA%\LocalLens.storage.json
```

实际配置、数据库、缓存和日志均保存在用户指定的 `LocalLensData` 目录中。

## 更换数据目录

在 Windows 应用的“本机服务器设置 → 数据存储”中可以选择新的目录。应用会：

1. 停止内置服务端；
2. 将配置、数据库、缩略图、缓存和日志复制到新目录；
3. 更新数据目录指针和服务端配置；
4. 从新目录启动服务端；
5. 启动成功后清理旧的 LocalLens 数据目录。

应用拒绝迁移到非空且未标记为 LocalLens 专用的目录，避免覆盖用户其他文件。

## 清除数据并恢复默认

在“本机服务器设置 → 恢复默认”中可以执行重置。该操作会删除：

- 本机服务端配置和管理员 Token；
- SQLite 媒体索引；
- 缩略图和转码缓存；
- LocalLens 日志和运行状态；
- 自定义数据目录指针。

重置后应用返回首次设置向导。**媒体目录中的原始图片和视频不会被删除。**

## 从旧版本升级

旧版 Windows 客户端只保存服务器地址和 Token，没有记录“本机”或“远程”运行模式。

升级到新版一体化包后，应用会要求选择：

- **使用本机内置服务器**：进入本地媒体目录和数据目录设置向导；
- **继续连接原来的服务器**：保留原服务器地址和 Token。

旧版位于 `%LOCALAPPDATA%\LocalLens` 的本机配置仍可直接使用；之后可以在设置页迁移到其他磁盘。

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
- 自定义数据目录和安全迁移；
- 清除数据并恢复首次设置；
- 手机扫码配对和设备撤销。

## 架构

```text
Windows 原始媒体目录
        ↓
LocalLens.exe
├── Flutter Windows 界面
├── runtime/media-tools/ffmpeg.exe
├── runtime/media-tools/ffprobe.exe
└── runtime/LocalLensServer.exe
    ├── fsnotify 文件监听
    ├── SQLite 索引与迁移
    ├── 元数据与缩略图任务
    ├── FFmpeg / FFprobe / EXIF
    ├── Direct Play / HLS
    ├── 文件夹、时间线与集合
    └── 配对与设备令牌
        ↓ 局域网
Flutter Android 客户端
```

## FFmpeg

Windows 一体化包固定包含 FFmpeg `8.1.2` 的 Windows Essentials 构建：

```text
runtime\media-tools\ffmpeg.exe
runtime\media-tools\ffprobe.exe
runtime\media-tools\FFMPEG-NOTICE.txt
```

构建流程从 GyanD 的 FFmpeg Windows 构建发布页下载固定版本，并执行以下验证：

- `ffmpeg -version` 必须返回预期版本；
- `ffprobe -version` 必须成功运行；
- 两个文件都写入 `BUNDLE-MANIFEST.json`；
- 最终 ZIP 解压后再次执行版本检查；
- 内置服务端使用最终 ZIP 内的 FFmpeg 路径启动健康检查。

FFmpeg 是随 LocalLens 分发的独立第三方可执行程序，来源和许可说明记录在 `FFMPEG-NOTICE.txt` 中。

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

独立服务端包不内置 FFmpeg，需要自行配置 `ffmpeg_path` 和 `ffprobe_path`。

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
- 下载并运行固定版本的 FFmpeg 和 FFprobe；
- 将服务端和媒体工具复制到最终 Windows ZIP；
- 校验 `BUNDLE-MANIFEST.json` 和必要文件；
- 解压最终 ZIP，再次验证 FFmpeg；
- 真实启动 ZIP 中的 Go 服务端；
- 轮询 `/api/v1/health`，通过后才允许上传发布资产。

## 文件安全边界

- 客户端只接收媒体 ID 和相对路径，不接收 Windows 绝对路径；
- 服务端只读取配置中的媒体根目录；
- LocalLens 数据固定写入独立的数据根目录；
- 数据重置不会删除媒体目录；
- 收藏、评分、相册和标签不会修改原始文件；
- 当前不提供远程删除、移动和重命名原始文件的接口；
- 外接磁盘暂时不可用时，索引会标记缺失，不会删除原始数据。

## 当前限制

- HEIC、RAW 等格式的缩略图能力取决于内置 FFmpeg 构建；
- 局域网模式当前仍使用 HTTP；
- Android Release APK 当前使用开发签名，不适合直接提交应用商店；
- 退出 `LocalLens.exe` 会停止由它托管的内置服务端；
- Windows 托盘常驻、登录自启动和可选 Windows Service 尚未实现。

详见 [API 文档](docs/api.md)、[架构文档](docs/architecture.md)、[v0.6 说明](docs/v0.6.0.md) 和 [发布说明](docs/releasing.md)。
