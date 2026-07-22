# LocalLens

LocalLens 是一个本地优先的跨平台媒体库：Windows 上运行 Go 媒体服务和 Flutter 管理端，Android / iOS 移动端使用 React Native，通过局域网浏览、播放和管理图片与视频。

> 当前版本：`v0.2.0`。原始媒体始终保存在用户选择的 Windows 文件夹中，LocalLens 只维护 SQLite 索引、缩略图、元数据和虚拟分类。

## v0.2 功能

### Windows Go 服务端

- 使用 `fsnotify` 递归监听新增、修改、删除和重命名；
- 文件事件防抖，大文件写入稳定后再进入索引；
- 启动校验、手动全量扫描与实时增量索引并存；
- SQLite `schema_migrations` 自动升级旧版数据库；
- 持久化缩略图队列和固定数量 FFmpeg Worker；
- 持久化元数据队列和固定数量 Metadata Worker；
- 服务重启后自动恢复未完成任务；
- FFprobe 提取视频时长、宽高和编码；
- EXIF 提取图片拍摄时间、GPS 和相机型号；
- 以真实拍摄时间建立时间线，缺失时回退到文件修改时间；
- HTTP Range 视频播放；
- 文件夹树、收藏、评分、相册和标签；
- 按设备保存视频播放位置；
- 一次性二维码配对、独立设备 Token 和设备撤销；
- Token 只以 SHA-256 哈希保存在 SQLite 中。

### Flutter Windows 管理端

- 管理本机内嵌 Go 服务端的启动、停止与配置；
- 生成一次性配对二维码、查看后台任务和撤销设备；
- 拍摄时间线、物理目录、相册、标签、收藏和评分；
- 搜索、筛选、图片查看、视频播放与播放进度管理；
- 与移动设备共享同一套 Go REST API 和媒体索引。

### React Native 移动端

- Expo + React Native + TypeScript，Android 与 iOS 共享业务代码；
- 扫描 Windows 管理端生成的一次性二维码并领取独立设备 Token；
- 手动填写局域网服务地址和管理员或设备 Token；
- Token 使用 Android Keystore / iOS Keychain 对应的 SecureStore 保存；
- 媒体网格、游标分页、下拉刷新和响应式手机/平板列数；
- 文件名与相对路径搜索，以及全部、图片、视频、收藏筛选；
- 原图查看、带 Bearer Header 的视频流播放；
- 收藏和取消收藏；
- 跟随系统的浅色与深色主题。

## 架构

```text
Windows 本地文件夹
        ↓
Go LocalLens Server
├── fsnotify 文件监听
├── SQLite 索引与版本迁移
├── 元数据持久任务队列
├── 缩略图持久任务队列
├── FFprobe / EXIF
├── 文件夹、时间线与虚拟分类
├── HTTP Range 视频流
└── 配对与设备令牌
        ↓ 局域网
├── Flutter Windows 管理端
└── React Native Android / iOS 移动端
```

## 仓库结构

```text
LocalLens/
├── server/
│   ├── main.go              # 生命周期
│   ├── config.go            # 配置
│   ├── database.go          # SQLite 与迁移
│   ├── scanner.go           # 全量与局部索引
│   ├── watcher.go           # fsnotify
│   ├── jobs.go              # 持久任务 Worker
│   ├── metadata.go          # FFprobe / EXIF
│   ├── media_store.go       # 时间线、目录、集合与播放进度
│   ├── pairing.go           # 配对与设备 Token
│   ├── http_api.go          # REST API 与媒体流
│   └── util.go
├── apps/local_lens/         # Flutter Windows 管理端
├── apps/local_lens_mobile/  # React Native Android / iOS 移动端
└── docs/
```

## 下载

GitHub Release 包含：

- `LocalLens-Server-Windows-x64.zip`
- `LocalLens-Client-Windows-x64.zip`
- `LocalLens-Android-universal.apk`（React Native）
- `SHA256SUMS.txt`

从 [GitHub Releases](https://github.com/weepwood/LocalLens/releases) 下载正式版本。

## 启动 Windows 服务端

```powershell
git clone https://github.com/weepwood/LocalLens.git
cd LocalLens\server
Copy-Item config.example.json config.json
```

编辑 `config.json`：

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

`public_url` 应填写手机能够访问的 Windows 局域网地址，否则二维码可能包含 `localhost`。

将 `ffmpeg.exe` 和 `ffprobe.exe` 放到：

```text
server/bin/ffmpeg.exe
server/bin/ffprobe.exe
```

启动：

```powershell
go run . -config ./config.json
```

或使用 Release 中的：

```powershell
.\LocalLensServer.exe -config .\config.json
```

检查：

```powershell
Invoke-RestMethod http://127.0.0.1:9527/api/v1/health
```

### Windows 防火墙

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

不要直接把 `9527` 端口映射到公网。远程访问优先使用 Tailscale、WireGuard 等可信 VPN。

## 连接客户端

### Windows 管理端

首次连接输入：

- 服务地址：`http://127.0.0.1:9527` 或局域网地址；
- Token：`config.json` 中的管理员 `api_token`。

管理员客户端可以：

- 启动全量扫描；
- 生成一次性配对二维码；
- 查看后台任务；
- 查看并撤销设备。

### Android / iOS 手机

1. Windows 客户端进入“服务器与设备”；
2. 点击“生成二维码”；
3. React Native 移动端首次启动后点击“扫描二维码配对”；
4. 服务端签发只属于该手机的设备 Token。

设备 Token 可以浏览和管理媒体，但不能创建新配对码、启动全量扫描或撤销其他设备。

移动端也可以手动填写手机可访问的局域网地址，例如 `http://192.168.1.20:9527`。不要填写 `localhost` 或 `127.0.0.1`，它们在手机上指向手机自身。

## 数据库升级

从 `v0.1.0` 升级时不需要删除 `data/locallens.db`。服务端启动后会自动执行迁移，增加：

- 媒体元数据与拍摄时间；
- 文件夹索引；
- 缩略图和元数据任务；
- 设备和播放进度；
- 相册、标签、评分及关联表。

建议升级前备份 `data` 目录。

## 文件安全边界

- 客户端只看到媒体 ID 和相对路径，不接收 Windows 绝对路径；
- 服务端只允许读取配置中的媒体根目录；
- 相册、标签、收藏和评分不会修改原始文件；
- 当前版本仍不提供远程删除、移动和重命名原始文件的接口；
- 外接磁盘暂时不可用时，索引会标记缺失而不是删除原始数据。

## 当前限制

- React Native 移动端首版尚未迁移相册、标签、星级评分、文件夹树和跨端视频续播；
- 视频默认直接播放原编码，尚未提供 HLS 自动转码；
- HEIC、RAW 等格式的缩略图取决于 FFmpeg 构建能力；
- 当前局域网开发模式仍使用 HTTP，尚未加入内置 TLS 证书指纹固定；
- Android Release APK 当前使用开发签名，不适合直接提交应用商店；
- iOS 业务代码可复用，但 GitHub Actions 暂未生成 iOS 安装包；
- Windows Service 和托盘常驻管理器仍在后续计划中。

详见 [移动端说明](apps/local_lens_mobile/README.md)、[API 文档](docs/api.md)、[架构文档](docs/architecture.md) 和 [发布说明](docs/releasing.md)。
