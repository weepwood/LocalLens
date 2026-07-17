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
  "version": "0.1.0",
  "apiVersion": "v1"
}
```

## 媒体列表

### `GET /media`

查询参数：

- `type=image|video`
- `q=<文件名关键字>`
- `libraryId=<library-id>`
- `limit=1..200`
- `offset>=0`

响应：

```json
{
  "items": [
    {
      "id": "...",
      "fileName": "IMG_0001.jpg",
      "type": "image",
      "width": 4032,
      "height": 3024,
      "sizeBytes": 4231421,
      "modifiedAt": "2026-07-18T10:00:00Z",
      "thumbnailUrl": "/api/v1/media/.../thumbnail?width=480",
      "originalUrl": "/api/v1/media/.../original",
      "streamUrl": "/api/v1/media/.../stream"
    }
  ],
  "total": 1,
  "limit": 100,
  "offset": 0
}
```

## 文件内容

- 图片网格：`GET /media/{id}/thumbnail?width=480`
- 原始文件：`GET /media/{id}/original`
- 视频播放：`GET /media/{id}/stream`

`stream` 与 `original` 都支持 HTTP Range；视频客户端应使用 `stream` 表达播放意图。

## 扫描

### `POST /scan`

启动后台扫描。如果已有扫描运行，返回 `409 Conflict`。

### `GET /scan`

返回当前或最近一次扫描状态。
