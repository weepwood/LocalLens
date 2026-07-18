# LocalLens API v0.2

Base URL：`http://<windows-ip>:9527/api/v1`

## 鉴权

```http
Authorization: Bearer <token>
```

存在两类 Token：

- 管理员 Token：来自 `config.json`，可扫描、创建配对会话和撤销设备；
- 设备 Token：扫码配对后签发，可浏览与管理媒体，但不能执行管理员操作。

无需鉴权：

- `GET /health`
- `GET /server`
- `POST /pairing/claim`

## 服务信息

```http
GET /health
GET /server
```

`GET /server` 返回版本和能力列表：

```json
{
  "name": "Home LocalLens",
  "version": "0.2.0",
  "apiVersion": "v1",
  "capabilities": [
    "timeline",
    "folders",
    "favorites",
    "ratings",
    "albums",
    "tags",
    "playback",
    "pairing"
  ]
}
```

## 媒体库、统计和目录

```http
GET /libraries
GET /stats
GET /folders?libraryId=<id>&parent=<relative-path>
```

目录接口只返回相对路径：

```json
{
  "items": [
    {
      "id": "...",
      "libraryId": "main-media",
      "path": "2026/Tokyo",
      "parentPath": "2026",
      "name": "Tokyo",
      "mediaCount": 125,
      "childCount": 3
    }
  ]
}
```

Windows 盘符和绝对路径不会返回给客户端。

## 媒体列表与时间线

```http
GET /media
```

查询参数：

- `type=image|video`
- `q=<文件名或相对路径关键字>`
- `libraryId=<媒体库ID>`
- `folder=<相对目录>`；传空值表示根目录
- `recursive=true`：包含目录后代
- `favorite=true`
- `albumId=<相册ID>`
- `tagId=<标签ID>`
- `minRating=1..5`
- `sort=timeline|modified|name`
- `limit=1..200`
- `cursor=<nextCursor>`
- `offset>=0`：仅保留旧客户端兼容

`sort=timeline` 使用 `capturedAt` 排序。其来源优先级为：

1. 图片 EXIF 时间；
2. 视频容器创建时间；
3. 文件修改时间。

媒体对象示例：

```json
{
  "id": "...",
  "libraryId": "main-media",
  "relativePath": "2026/Tokyo/IMG_0001.jpg",
  "folderPath": "2026/Tokyo",
  "fileName": "IMG_0001.jpg",
  "type": "image",
  "mimeType": "image/jpeg",
  "sizeBytes": 4231421,
  "modifiedAt": "2026-07-18T10:00:00Z",
  "capturedAt": "2024-03-20T08:30:00Z",
  "capturedAtSource": "exif",
  "width": 4032,
  "height": 3024,
  "durationMs": 0,
  "codec": "",
  "latitude": 35.6762,
  "longitude": 139.6503,
  "cameraModel": "Camera Model",
  "metadataStatus": "done",
  "metadataError": "",
  "favorite": true,
  "rating": 4,
  "thumbnailUrl": "/api/v1/media/.../thumbnail?width=480",
  "originalUrl": "/api/v1/media/.../original",
  "streamUrl": "/api/v1/media/.../stream"
}
```

分页响应：

```json
{
  "items": [],
  "total": 12500,
  "limit": 100,
  "offset": 0,
  "nextCursor": "...",
  "hasMore": true
}
```

改变任何筛选条件后必须丢弃旧游标。

## 收藏与评分

```http
PUT    /media/{id}/favorite
DELETE /media/{id}/favorite
PUT    /media/{id}/rating
DELETE /media/{id}/rating
```

设置评分：

```json
{"rating": 4}
```

评分范围为 1～5；删除评分会恢复为 0。

## 元数据重试与文件内容

```http
POST /media/{id}/metadata
GET  /media/{id}/thumbnail?width=480
GET  /media/{id}/original
GET  /media/{id}/stream
```

缩略图不存在时会进入持久队列。服务端最多等待约 8 秒；仍未完成时返回：

```http
HTTP/1.1 202 Accepted
Retry-After: 3
```

```json
{"status":"queued"}
```

客户端应显示占位图并稍后重试。`original` 和 `stream` 支持 HTTP Range。

## 播放进度

```http
GET /media/{id}/progress
PUT /media/{id}/progress
```

播放进度绑定当前设备 Token：

```json
{
  "positionMs": 125000,
  "durationMs": 3600000,
  "completed": false
}
```

管理员 Token 使用固定设备标识 `admin`；每个已配对设备拥有独立进度。

## 相册

```http
GET    /albums
POST   /albums
DELETE /albums/{id}
PUT    /albums/{id}/items/{mediaId}
DELETE /albums/{id}/items/{mediaId}
```

创建：

```json
{"name":"东京旅行","description":"2024 年旅行照片"}
```

## 标签

```http
GET    /tags
POST   /tags
DELETE /tags/{id}
PUT    /media/{id}/tags/{tagId}
DELETE /media/{id}/tags/{tagId}
```

创建：

```json
{"name":"夜景","color":"#5b5bd6"}
```

查询媒体所属集合：

```http
GET /media/{id}/collections
```

```json
{"albumIds":["..."],"tagIds":["..."]}
```

## 扫描与实时监听

```http
POST /scan
GET  /scan
```

`POST /scan` 仅管理员可调用。服务端同时使用 fsnotify 实时监听，因此全量扫描主要用于启动检查和漏失事件校验。

## 配对与设备

### 创建配对会话

```http
POST /pairing/session
```

仅管理员可调用，返回短时一次性 payload 和二维码地址：

```json
{
  "id": "...",
  "payload": "{...}",
  "expiresAt": "2026-07-18T13:30:00Z",
  "qrUrl": "/api/v1/pairing/session/.../qr"
}
```

```http
GET /pairing/session/{id}/qr
```

返回 `image/png`。

### 手机领取设备令牌

```http
POST /pairing/claim
```

无需已有 Token：

```json
{
  "pairingId": "...",
  "secret": "...",
  "deviceName": "Pixel",
  "platform": "android"
}
```

成功时只返回一次令牌：

```json
{
  "device": {"id":"...","name":"Pixel","platform":"android"},
  "token": "<device-token>"
}
```

服务端数据库只保存令牌哈希。

### 管理设备

```http
GET    /devices
DELETE /devices/{id}
```

仅管理员可调用。撤销后该设备 Token 立即失效。

## 错误状态

- `400`：查询参数或 JSON 无效；
- `401`：Token 无效或已撤销；
- `403`：需要管理员权限；
- `404`：媒体、相册、标签或设备不存在；
- `409`：扫描已运行或唯一约束冲突；
- `410`：媒体记录存在，但原文件当前缺失；
- `202`：缩略图任务已入队，稍后重试；
- `500`：服务端内部错误。
