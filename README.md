# LocalLens

LocalLens 是一个本地优先的跨平台媒体库：Windows 上运行 Go 媒体服务，Flutter 客户端通过局域网访问图片与视频。

> 当前状态：MVP 骨架。已包含媒体目录扫描、SQLite 索引、图片缩略图、视频 Range 流、Bearer Token 鉴权，以及 Flutter 媒体网格、图片查看和视频播放界面。

## 架构

```text
Windows 文件夹
    ↓
Go Media Server
├── 增量扫描
├── SQLite 索引
├── 图片缩略图缓存
├── 视频 HTTP Range
└── Token 鉴权
    ↓ 局域网
Flutter Android / iOS / Windows
```

## 仓库结构

```text
LocalLens/
├── server/                 # Go 媒体服务端
├── apps/local_lens/        # Flutter 客户端源码
└── docs/                   # 架构与 API 文档
```

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

首次启动会扫描配置中的媒体目录。视频缩略图需要把 `ffmpeg.exe` 放到 `server/bin/`；没有 FFmpeg 时，图片浏览和视频播放仍可工作，但视频封面会返回错误占位。

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

## 已实现接口

- `GET /api/v1/health`
- `GET /api/v1/server`
- `GET /api/v1/libraries`
- `GET /api/v1/media`
- `GET /api/v1/media/{id}`
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

- MVP 暂时使用手动输入地址和 Token，尚未实现二维码配对。
- 视频默认直接播放原文件，客户端不支持的编码尚未自动转码。
- 视频元数据和封面依赖 FFmpeg/FFprobe 的后续完善。
- 暂不提供真实文件删除、移动和重命名接口。
- 目前使用 HTTP 便于局域网调试；正式远程访问前需要增加 TLS 或通过可信 VPN 接入。

## 路线图

1. 二维码配对、设备令牌与撤销。
2. 文件变化监听与扫描事件推送。
3. FFprobe 视频元数据、HLS 按需转码。
4. 时间线、收藏、相册和标签。
5. Windows 托盘管理端与 Windows Service。
6. HTTPS 证书指纹固定与远程安全接入。

详见 [docs/architecture.md](docs/architecture.md) 与 [docs/api.md](docs/api.md)。
