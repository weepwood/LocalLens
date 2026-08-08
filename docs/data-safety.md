# LocalLens 数据安全与备份

LocalLens 0.8.x 开始提供数据安全中心，用于检查 SQLite 索引库并创建可验证的本地快照。

## 数据安全中心

Windows 桌面端右下角提供“数据安全”入口。打开后可以查看：

- SQLite `quick_check` 结果；
- 外键约束异常数量；
- 主数据库与 WAL 文件体积；
- 数据库实际位置；
- 最近创建的备份及 SHA-256 摘要。

服务尚未启动时无法执行自检与备份，因为数据库连接和一致性快照由正在运行的 Rust 后端统一管理。

## 启动保护

Rust 后端打开数据库后会先执行 `PRAGMA quick_check`。检查未通过时，服务拒绝继续迁移和启动，避免在已损坏的数据库上继续写入。

发现启动失败时：

1. 不要删除 `data` 目录；
2. 复制完整数据目录，包括 `locallens.db`、`locallens.db-wal` 和 `locallens.db-shm`；
3. 查看日志中的 `SQLite quick_check 失败` 信息；
4. 使用最近一次已验证备份进行恢复，或在副本上使用 SQLite 修复工具分析。

## 备份格式

默认位置：

```text
<data_dir>/backups/backup-YYYYMMDD-HHMMSS-xxxxxxxx/
├── locallens.db
├── config.json
└── manifest.json
```

`locallens.db` 使用 SQLite `VACUUM INTO` 生成，是不依赖当前 WAL 文件的一致性数据库快照。

`manifest.json` 包含：

- 备份格式版本；
- LocalLens 核心版本；
- 创建时间；
- 数据库文件名和大小；
- 数据库 SHA-256；
- 备份数据库的 `quick_check` 结果；
- 是否包含配置文件。

备份完成前会重新打开快照并执行 `quick_check`。校验失败时，LocalLens 会删除未完成的备份目录，不将其列为有效备份。

## 当前边界

本阶段完成“自检、创建备份、验证和查看记录”。自动恢复向导尚未开放，以避免在服务运行时直接覆盖数据库。恢复前应停止 LocalLens，并保留当前数据目录的完整副本。

后续恢复流程应包含：

- 读取并验证备份清单；
- 校验 SHA-256；
- 恢复前自动创建当前状态快照；
- 停止后台 Worker 和文件监听；
- 原子替换数据库与配置；
- 重新启动并执行完整性检查。
