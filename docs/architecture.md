# LocalLens 架构

## 设计边界

LocalLens 不复制或接管用户的原始媒体文件。Rust 服务只对配置过的媒体根目录建立索引，并通过不可猜测的媒体 ID 向客户端提供访问。

```text
┌────────────────────── Windows ──────────────────────┐
│ D:\Photos / E:\Videos                               │
│          ↓                                           │
│ Rust Scanner / notify                                │
│          ↓                                           │
│ SQLx + SQLite ──→ Thumbnail / Metadata / HLS Queue  │
│          ↓                                           │
│ Axum REST API                                        │
│          ↑                                           │
│ Tauri 2 管理端                                       │
└──────────────────────┬──────────────────────────────┘
                       │ LAN / Bearer Token
             ┌─────────┴─────────┐
             │ Kotlin Android    │
             │ Jetpack Compose   │
             └───────────────────┘
```

## 组件职责

### Rust Core

- 读取并校验 JSON 配置；
- 管理 SQLite 连接、迁移、备份和任务队列；
- 提供媒体、文件夹、相册、标签、设备和播放进度领域模型；
- 保持 `/api/v1` JSON 契约稳定。

### Rust Server

- 全量扫描和增量索引；
- 使用 `notify` 监听文件系统变化并进行防抖；
- 在大文件稳定后再进入索引；
- 提取 EXIF 与 FFprobe 元数据；
- 生成图片和视频缩略图；
- 提供 HTTP Range、字幕和 HLS 转码；
- 处理二维码配对、设备 Token 和权限隔离；
- 通过 Axum 暴露局域网 API。

### Tauri 2 Windows 管理端

- 在进程内启动和停止 Rust/Axum 服务；
- 管理媒体库、局域网地址、数据目录和后台 Worker；
- 自动检测局域网 IPv4；
- 生成一次性配对二维码；
- 查看和撤销已配对设备；
- 构建 MSI、NSIS 和独立 Rust 服务包。

### Kotlin Android 客户端

- 使用 Jetpack Compose 和 Material 3；
- 使用 Google Code Scanner 完成一次性配对；
- 通过 Bearer Token 访问图片、视频和集合接口；
- 使用 Media3 ExoPlayer 协商直接播放或 HLS；
- 保存共享播放进度。

## 数据模型

LocalLens 继续使用 `data/locallens.db`。主要数据包括：

- 媒体库与文件夹树；
- 媒体索引和元数据；
- 缩略图、元数据与转码任务；
- 收藏和评分；
- 相册和标签；
- 配对会话与设备 Token 哈希；
- 共享播放进度。

首次打开旧数据库时，服务会先备份数据库、WAL 和 SHM，再原地补齐表、字段和索引。

## 索引策略

每次全量扫描生成唯一 `scan_id`：

1. 遍历启用的媒体库；
2. 用 `library_id + relative_path` 生成稳定媒体 ID；
3. 根据路径、文件大小和修改时间更新记录；
4. 本次出现的记录写入 `last_seen_scan`；
5. 完整遍历成功后，把未出现的记录标记为 `missing`；
6. 将缩略图和元数据工作写入持久任务队列。

只有完整遍历成功后才执行缺失标记，避免扫描中断造成大批误判。

## 播放策略

1. 客户端提交支持的容器、编码和最大尺寸；
2. 服务端满足条件时返回原始 HTTP Range 地址；
3. 不兼容时创建持久 HLS 转码任务；
4. 转码完成后返回播放列表；
5. 缓存超过配置配额时按旧任务优先回收。

字幕从视频同目录发现，支持 `srt`、`vtt`、`ass` 和 `ssa`。

## 文件安全

- 客户端不能提交 Windows 绝对路径；
- API 只接收媒体 ID 和受控的字幕文件名；
- 服务端从数据库解析媒体库和相对路径；
- 每次读取前检查目标仍位于允许的根目录内；
- 拒绝 `..`、盘符前缀和绝对路径；
- 不提供远程删除、移动或覆盖原文件的接口。

## 鉴权边界

- 管理员 Token 来自配置文件；
- 一次性配对会话只在短时间内有效；
- 设备 Token 只以 SHA-256 哈希保存；
- 设备 Token 不能扫描、创建配对会话或撤销其他设备；
- 撤销设备后 Token 立即失效。

## 构建与发布

正式构建只包含：

- `rust/`；
- `apps/local_lens_desktop/`；
- `apps/local_lens_android/`；
- 根目录 `config.example.json`；
- FFmpeg / FFprobe 和许可证说明。

迁移前实现已从工作树移除，历史实现通过 Git 提交和历史 Release 追溯。