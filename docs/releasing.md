# LocalLens 打包与发布

仓库通过 `.github/workflows/build-release.yml` 自动构建以下产物：

| 产物 | 文件名 | 用途 |
|---|---|---|
| Windows 一体化应用 | `LocalLens-Windows-x64.zip` | 推荐下载；包含 Flutter 界面、Go 服务端、FFmpeg 和 FFprobe |
| 独立 Go 服务端 | `LocalLens-Server-Windows-x64.zip` | 高级部署；服务端与客户端分开运行 |
| Android 客户端 | `LocalLens-Android-universal.apk` | Android 手机安装包 |
| 校验文件 | `SHA256SUMS.txt` | 验证下载文件完整性 |

## Windows 一体化包验收

最终 ZIP 根目录必须包含：

```text
LocalLens.exe
flutter_windows.dll
BUNDLE-MANIFEST.json
runtime/
├── LocalLensServer.exe
└── media-tools/
    ├── ffmpeg.exe
    ├── ffprobe.exe
    └── FFMPEG-NOTICE.txt
```

`BUNDLE-MANIFEST.json` 记录：

- 客户端和服务端版本；
- 构建编号和提交 SHA；
- 客户端与内置服务端相对路径；
- FFmpeg 版本；
- FFmpeg 与 FFprobe 相对路径和 SHA-256；
- UTC 构建时间。

Windows 构建任务会在上传 Artifact 前执行：

1. 从固定 URL 下载固定版本的 FFmpeg Windows Essentials 构建；
2. 运行 `ffmpeg -version` 和 `ffprobe -version`；
3. 构建 Flutter Windows 应用和两个 Go 服务端 EXE；
4. 将内置服务端、FFmpeg 与 FFprobe 放入最终 ZIP；
5. 校验全部必要文件和构建清单；
6. 解压最终 ZIP 到全新目录；
7. 再次运行 ZIP 内的 FFmpeg 与 FFprobe；
8. 使用 ZIP 内的 `runtime/LocalLensServer.exe`、FFmpeg 和临时数据目录启动服务端；
9. 轮询 `/api/v1/health`；
10. 任何文件缺失、版本不符、进程提前退出或健康检查失败都会终止构建。

不能只验证构建目录，因为发布阶段真正交付的是压缩后的文件。

## FFmpeg 固定版本策略

当前 Windows 一体化包固定使用：

```text
FFmpeg 8.1.2 Essentials Build
```

工作流环境变量同时记录版本和完整下载 URL。升级 FFmpeg 时必须同时修改：

- `FFMPEG_VERSION`；
- `FFMPEG_ARCHIVE_URL`；
- README 和版本发布说明；
- 重新通过最终 ZIP 冒烟测试。

下载归档的 SHA-256 会写入 `FFMPEG-NOTICE.txt`，最终 `ffmpeg.exe` 和 `ffprobe.exe` 的 SHA-256 会写入 `BUNDLE-MANIFEST.json`。

独立服务端包仍不内置 FFmpeg，使用者需要自行设置 `ffmpeg_path` 和 `ffprobe_path`。

## 用户数据目录验收

Windows 应用默认使用：

```text
%LOCALAPPDATA%\LocalLens
```

用户可以在首次设置或服务器设置页选择其他磁盘。应用在所选上级目录中创建：

```text
LocalLensData/
├── .locallens-data-root.json
├── config/
├── data/
├── cache/
├── logs/
└── runtime/
```

自定义路径只通过以下指针文件定位：

```text
%LOCALAPPDATA%\LocalLens.storage.json
```

发布验收应确认：

- 旧版默认目录仍能被读取；
- 新目录迁移时先停止服务，再复制数据并切换指针；
- 新服务启动成功后才删除旧目录；
- 数据目录和媒体目录不能相同或互相包含；
- 非默认目录必须具有 `.locallens-data-root.json` 标记，才能被迁移清理或重置删除；
- 重置不会删除媒体目录中的原始文件。

## Actions Artifacts

以下操作会执行构建和静态检查：

- 向 `main` 提交 Pull Request；
- 向 `main` 推送提交；
- 推送 `v*` 版本标签；
- 在 GitHub Actions 页面手动运行工作流。

构建成功后，可以在工作流运行页面下载 Windows 一体化包、独立服务端和 Android APK。Actions Artifacts 默认保留 30 天。

## GitHub Releases

以下三种情况会发布 GitHub Release：

1. 推送 `v1.2.3` 格式的版本标签；
2. 在 Actions 页面手动运行，并填写版本标签；
3. `main` 分支提交信息以 `release:` 开头。

推荐流程：

```powershell
git checkout main
git pull
git tag v0.6.1
git push origin v0.6.1
```

Release 任务会再次确认以下资产存在：

```text
LocalLens-Windows-x64.zip
LocalLens-Server-Windows-x64.zip
LocalLens-Android-universal.apk
```

随后生成 `SHA256SUMS.txt` 并上传全部文件。

## Android 签名说明

当前 Android Release APK 使用 Flutter 平台模板中的开发签名配置，适合内部测试和局域网验证，不适合应用商店正式分发。

正式发布前，应配置独立 Android keystore，并把密钥内容和密码保存为 GitHub Actions Secrets。不要把 keystore 或密码提交到仓库。

## 校验下载文件

Windows PowerShell：

```powershell
Get-FileHash .\LocalLens-Windows-x64.zip -Algorithm SHA256
Get-Content .\SHA256SUMS.txt
```

比较两处 SHA-256 值是否一致。解压后还可以执行：

```powershell
.\runtime\media-tools\ffmpeg.exe -version
.\runtime\media-tools\ffprobe.exe -version
Get-Content .\BUNDLE-MANIFEST.json
```
