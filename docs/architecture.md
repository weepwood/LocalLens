# LocalLens 架构

## 设计边界

LocalLens 不复制或接管用户的原始媒体文件。Go 服务只对配置过的媒体根目录建立索引，并通过不可猜测的媒体 ID 对客户端提供访问。

```text
┌──────────────── Windows ────────────────┐
│ D:\Photos / E:\Videos                  │
│          ↓                              │
│ Scanner → SQLite → HTTP API             │
│                 ↘ Thumbnail Cache       │
└───────────────────┬─────────────────────┘
                    │ LAN
          ┌─────────┴─────────┐
          │ Flutter Clients   │
          │ Android / Windows │
          └───────────────────┘
```

## 服务端职责

- 读取 JSON 配置并校验媒体根目录。
- 使用 SQLite 保存媒体索引，并启用 WAL。
- 扫描图片和视频，按文件路径、大小与修改时间增量更新。
- 为图片生成缩略图；使用 FFmpeg 生成视频封面。
- 通过 HTTP Range 提供视频播放和断点读取。
- 使用 Bearer Token 保护媒体接口。

## 索引策略

每次扫描生成唯一 `scan_id`：

1. 遍历配置目录。
2. 用 `library_id + relative_path` 生成稳定媒体 ID。
3. 根据路径、文件大小、修改时间更新记录。
4. 本次出现的记录写入 `last_seen_scan`。
5. 遍历成功后，把未出现在本次扫描中的记录标记为 `missing`。

只有完整遍历成功后才执行缺失标记，避免扫描中断造成大批误判。

## 文件安全

- 客户端不能传入 Windows 绝对路径。
- API 只接收媒体 ID。
- 服务端从数据库解析媒体所属根目录和相对路径。
- 每次读取前再次检查目标路径仍位于允许的根目录内。
- MVP 不暴露删除、移动和覆盖原文件的接口。

## 缩略图缓存

```text
data/thumbnails/ab/<media-id>-<modified>-<width>.jpg
```

文件修改时间变化后缓存键随之变化，旧缓存可由后续清理任务回收。

## 后续演进

- 二维码配对与每台设备独立令牌。
- `fsnotify` 文件变化监听与定期增量校验。
- FFprobe 视频元数据和 HLS 按需转码。
- Windows 托盘管理端和 Windows Service。
- TLS 证书指纹固定与可信远程访问。
