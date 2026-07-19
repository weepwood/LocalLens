# LocalLens 打包与发布

仓库通过 `.github/workflows/build-release.yml` 自动构建以下产物：

| 产物 | 文件名 | 用途 |
|---|---|---|
| Windows 一体化应用 | `LocalLens-Windows-x64.zip` | 推荐下载；包含 Flutter 界面和内置 Go 服务端 |
| 独立 Go 服务端 | `LocalLens-Server-Windows-x64.zip` | 高级部署；服务端与客户端分开运行 |
| Android 客户端 | `LocalLens-Android-universal.apk` | Android 手机安装包 |
| 校验文件 | `SHA256SUMS.txt` | 验证下载文件完整性 |

## Windows 一体化包验收

最终 ZIP 必须包含：

```text
LocalLens-Windows-x64/
├── LocalLens.exe
├── BUNDLE-MANIFEST.json
└── runtime/
    ├── LocalLensServer.exe
    └── media-tools/
        └── README.txt
```

`BUNDLE-MANIFEST.json` 记录客户端版本、服务端版本、构建编号、提交 SHA 和内置服务端路径。

Windows 构建任务会在上传 Artifact 前执行以下验证：

1. 校验客户端、服务端、清单和说明文件是否存在；
2. 压缩为最终 `LocalLens-Windows-x64.zip`；
3. 将最终 ZIP 解压到全新目录；
4. 从 ZIP 内启动 `runtime/LocalLensServer.exe`；
5. 使用临时配置、数据库和媒体目录运行；
6. 轮询 `/api/v1/health`；
7. 健康检查失败、服务端提前退出或缺少文件时终止构建。

不能仅验证构建目录，因为发布阶段真正交付的是压缩后的文件。

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

Release 任务会在发布前再次确认以下资产存在：

```text
LocalLens-Windows-x64.zip
LocalLens-Server-Windows-x64.zip
LocalLens-Android-universal.apk
```

随后生成 `SHA256SUMS.txt` 并上传全部文件。

## Android 签名说明

当前 Android Release APK 使用 Flutter 平台模板中的开发签名配置，适合内部测试和局域网验证，不适合应用商店正式分发。

正式发布前，应配置独立 Android keystore，并把密钥内容和密码保存为 GitHub Actions Secrets。不要把 keystore 或密码提交到仓库。

## FFmpeg 说明

Windows 一体化包和独立服务端包默认都不直接包含 FFmpeg。

一体化包使用：

```text
LocalLens-Windows-x64/
└── runtime/
    └── media-tools/
        ├── ffmpeg.exe
        └── ffprobe.exe
```

独立服务端使用：

```text
LocalLens-Server-Windows-x64/
└── bin/
    ├── ffmpeg.exe
    └── ffprobe.exe
```

FFmpeg 用于视频缩略图、更多格式元数据和 HLS 转码。内置 Go 服务端必须始终随 Windows 一体化包发布，不能把“未附带 FFmpeg”和“未附带服务端”混为一谈。

## 校验下载文件

Windows PowerShell：

```powershell
Get-FileHash .\LocalLens-Windows-x64.zip -Algorithm SHA256
Get-Content .\SHA256SUMS.txt
```

比较两处 SHA-256 值是否一致。
