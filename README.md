# LocalLens

LocalLens 是一个本地优先的跨平台媒体库：Windows 上运行 Go 媒体服务，Flutter 客户端通过局域网访问图片与视频。

> 当前状态：可运行 MVP。已包含媒体目录扫描、SQLite 版本迁移、游标分页、媒体库筛选、收藏、统计、图片缩略图、视频 Range 流、Bearer Token 鉴权，以及 Flutter Windows / Android 浏览客户端。

## 架构

```text
Windows 文件夹
    ↓
Go Media Server
├── 增量扫描
├── SQLite 索引与迁移
├── 游标分页与媒体库过滤
├── 收藏与媒体统计
├── 缩略图缓存
├── 视频 HTTP Range
└── Token 鉴权
    ↓ 局域网
Flutter Android / iOS / Windows
```

## 仓库结构

```text
LocalLens/
├── server/                 # Go 媒体服务端
│   ├── main.go             # 进程启动与关闭
│   ├── config.go           # 配置读取与校验
│   ├── database.go         # SQLite 与版本迁移
│   ├── scanner.go          # 文件扫描
│   ├── media_store.go      # 查询、游标与收藏
│   ├── http_api.go         # REST API 与媒体流
│   └── util.go             # 通用工具
├── apps/local_lens/        # Flutter 客户端源码
└── docs/                   # 架构、API、发布和项目分析文档
```

## 下载打包产物

GitHub Actions 自动生成：

- `LocalLens-Server-Windows-x64.zip`：Windows Go 媒体服务端；
- `LocalLens-Client-Windows-x64.zip`：Windows Flutter 客户端；
- `LocalLens-Android-universal.apk`：Android 测试安装包；
- `SHA256SUMS.txt`：Release 下载文件完整性校验。

正式版本可从 [GitHub Releases](https://github.com/weepwood/LocalLens/releases) 下载。Pull Request 与普通主分支提交产生的临时构建，可以在对应 GitHub Actions 运行页面的 Artifacts 区域下载。

打包、版本标签和 Android 签名说明见 [docs/releasing.md](docs/releasing.md)。

## 1. 启动 Go 服务端

环境建议：Go 1.23 或更高版本；Windows 生产环境建议使用当前受支持的 Go 版本。

```powershell
cd server
Copy-Item config.example.json config.json
```

编辑 `config.json`：

```json
{
  "listen_address": "0.0.0.0:9527",
  "server_name": "My LocalLens",
  "data_dir": "./data",
  "api_token": "replace-with-a-long-random-token",
  "ffmpeg_path": "./bin/ffmpeg.exe",
  "auto_scan": true,
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
go run . -config ./config.json
```

检查：

```powershell
Invoke-RestMethod http://127.0.0.1:9527/api/v1/health
```

首次启动会自动建立或升级 SQLite 数据库，不需要手工删除旧索引。视频缩略图需要把 `ffmpeg.exe` 放到 `server/bin/`；没有 FFmpeg 时，图片浏览和视频原文件播放仍可工作。

### Windows 防火墙

手机需要访问 Windows 的 `9527` 端口。建议只为“专用网络”放行，不要把该端口直接映射到公网。

```powershell
New-NetFirewallRule `
  -DisplayName "LocalLens Media Server" `
  -Direction Inbound `
  -Action Allow `
  -Protocol TCP `
  -LocalPort 9527 `
  -Profile Private
```

## 2. 启动 Flutter 客户端

当前仓库保存 Flutter 业务源码，不提交平台模板生成物。先生成 Android 与 Windows 平台目录：

```powershell
cd apps/local_lens
./tool/bootstrap.ps1
flutter run -d windows
```

Android 真机：

```powershell
flutter devices
flutter run -d <device-id>
```

客户端首次启动输入：

- 服务地址：`http://Windows局域网IP:9527`
- API Token：服务端配置中的 `api_token`

可在 Windows 执行 `ipconfig` 查看局域网 IPv4 地址。手机和 Windows 必须位于可互相访问的同一网络。

## 客户端浏览能力

- 使用 `(modified_at, id)` 游标连续加载大媒体库；
- 支持按媒体库、图片、视频和收藏进行组合筛选；
- 文件名搜索防抖；
- 展示图片数、视频数、收藏数、总容量和各媒体库文件数量；
- 可直接收藏或取消收藏，收藏数据不修改原始媒体文件；
- 下拉刷新媒体、统计、媒体库和扫描状态；
- 客户端启动扫描并轮询展示发现数、索引数、失败数和当前目录；
- 媒体卡片显示文件大小、修改日期和缩略图加载进度；
- 网络超时、TLS、HTTP 和数据解析错误提供明确提示。

## 已实现接口

- `GET /api/v1/health`
- `GET /api/v1/server`
- `GET /api/v1/libraries`
- `GET /api/v1/stats`
- `GET /api/v1/media`
- `GET /api/v1/media/{id}`
- `PUT /api/v1/media/{id}/favorite`
- `DELETE /api/v1/media/{id}/favorite`
- `GET /api/v1/media/{id}/thumbnail`
- `GET /api/v1/media/{id}/original`
- `GET /api/v1/media/{id}/stream`
- `POST /api/v1/scan`
- `GET /api/v1/scan`

除健康检查与服务信息外，其他接口需要：

```http
Authorization: Bearer <api_token>
```

## 当前限制

- 仍使用手动输入地址和统一 Token，尚未实现二维码配对和每设备令牌。
- 视频默认直接播放原文件，客户端不支持的编码尚未自动转码。
- 图片 EXIF、视频时长、分辨率和编码信息尚未提取。
- 文件变化监听与缩略图后台任务队列尚未完成；当前版本通过互斥和临时文件避免并发生成同一缩略图。
- 暂不提供真实文件删除、移动和重命名接口。
- 目前使用 HTTP 便于局域网调试；正式远程访问前需要增加 TLS 或通过可信 VPN 接入。

## 路线图

1. 文件变化监听与缩略图后台任务队列。
2. FFprobe 元数据、时间线和播放进度。
3. 相册、标签、评分与重复媒体检测。
4. 二维码配对、设备令牌与撤销。
5. HLS 按需转码与转码缓存。
6. Windows 托盘管理端、Windows Service 和 HTTPS 证书指纹固定。

详见 [docs/architecture.md](docs/architecture.md)、[docs/api.md](docs/api.md)、[docs/releasing.md](docs/releasing.md) 与 [docs/project-analysis.md](docs/project-analysis.md)。
