# LocalLens API

Base URL：`http://<windows-ip>:9527/api/v1`

## 鉴权

```http
Authorization: Bearer <token>
```

`/health` 与 `/server` 不需要鉴权。

## 服务信息

### `GET /health`

```json
{"status":"ok"}
```

### `GET /server`

```json
{
  "name": "My LocalLens",
  "version": "0.2.0",
  "apiVersion": "v1"
}
```

## 媒体库

### `GET /libraries`

返回已配置媒体库及其扫描状态和有效媒体数量：

```json
{
  "items": [
    {
      "id": "main-media",
      "name": "媒体库",
      "recursive": true,
      "enabled": true,
      "lastScannedAt": "2026-07-18T10:00:00Z",
      "mediaCount": 12500
    }
  ]
}
```

## 统计

### `GET /stats`

```json
{
  "total": 12500,
  "images": 10000,
  "videos": 2500,
  "favorites": 120,
  "sizeBytes": 9876543210
}
```

## 媒体列表

### `GET /media`

查询参数：

- `type=image|video`
- `q=<文件名关键字>`
- `libraryId=<媒体库ID>`
- `favorite=true`
- `limit=1..200`
- `cursor=<上一页返回的 nextCursor>`
- `offset>=0`，为旧客户端保留；新客户端应优先使用 `cursor`

推荐请求：

```http
GET /api/v1/media?libraryId=main-media&type=image&limit=100
```

响应：

```json
{
  "items": [
    {
      "id": "...",
      "libraryId": "main-media",
      "fileName": "IMG_0001.jpg",
      "type": "image",
      "mimeType": "image/jpeg",
      "sizeBytes": 4231421,
      "modifiedAt": "2026-07-18T10:00:00Z",
      "favorite": true,
      "thumbnailUrl": "/api/v1/media/.../thumbnail?width=480",
      "originalUrl": "/api/v1/media/.../original",
      "streamUrl": "/api/v1/media/.../stream"
    }
  ],
  "total": 12500,
  "limit": 100,
  "offset": 0,
  "nextCursor": "eyJtb2RpZmllZEF0IjoiLi4uIiwiaWQiOiIuLi4ifQ",
  "hasMore": true
}
```

下一页直接传入 `nextCursor`：

```http
GET /api/v1/media?limit=100&cursor=<nextCursor>
```

游标绑定当前排序位置。切换搜索词、媒体类型、媒体库或收藏筛选后，应丢弃旧游标并从第一页重新请求。

MVP 暂未提取图片宽高、EXIF 和视频时长；这些字段将在 FFprobe/元数据阶段加入。

## 收藏

### `PUT /media/{id}/favorite`

将媒体设为收藏，返回更新后的媒体对象。

### `DELETE /media/{id}/favorite`

取消收藏，返回更新后的媒体对象。

收藏只保存在 LocalLens SQLite 索引中，不修改原始图片或视频文件。

## 文件内容

- 图片网格：`GET /media/{id}/thumbnail?width=480`
- 原始文件：`GET /media/{id}/original`
- 视频播放：`GET /media/{id}/stream`

`stream` 与 `original` 都支持 HTTP Range；视频客户端应使用 `stream` 表达播放意图。

缩略图不存在时，服务端会在互斥区内调用 FFmpeg，先写入临时文件，再原子替换到缓存路径，避免并发读取半成品。

## 扫描

### `POST /scan`

启动后台扫描。如果已有扫描运行，返回 `409 Conflict`。

### `GET /scan`

返回当前或最近一次扫描状态。
