# LocalLens 打包与发布

仓库通过 `.github/workflows/build-release.yml` 自动构建以下产物：

| 产物 | 文件名 | 用途 |
|---|---|---|
| Go 服务端 | `LocalLens-Server-Windows-x64.zip` | 在保存媒体文件的 Windows 电脑运行 |
| Flutter Windows 客户端 | `LocalLens-Client-Windows-x64.zip` | Windows 桌面浏览客户端 |
| Flutter Android 客户端 | `LocalLens-Android-universal.apk` | Android 手机安装包 |
| 校验文件 | `SHA256SUMS.txt` | 验证下载文件完整性 |

## Actions Artifacts

以下操作会执行构建和静态检查：

- 向 `main` 提交 Pull Request；
- 向 `main` 推送提交；
- 推送 `v*` 版本标签；
- 在 GitHub Actions 页面手动运行工作流。

构建成功后，可以在对应工作流运行页面的 **Artifacts** 区域下载三个产物。Actions Artifacts 默认保留 30 天。

## GitHub Releases

以下三种情况会发布 GitHub Release：

1. 推送 `v1.2.3` 格式的版本标签；
2. 在 Actions 页面手动运行，并填写版本标签；
3. `main` 分支提交信息以 `release:` 开头。该方式只用于首次发布和明确的版本发布提交。

首个自动发布版本为 `v0.1.0`。

推荐的后续发布流程：

```powershell
git checkout main
git pull
git tag v0.2.0
git push origin v0.2.0
```

工作流会在三个平台构建完成后创建 Release、生成发行说明并上传安装包。

## Android 签名说明

当前 MVP 的 Android Release APK 使用 Flutter 平台模板中的开发签名配置，适合内部测试和局域网验证，不适合应用商店正式分发。

正式发布前，应配置独立的 Android keystore，并把密钥内容和密码保存为 GitHub Actions Secrets。不要把 keystore 或密码直接提交到仓库。

## FFmpeg 说明

Go 服务端压缩包不包含 FFmpeg。用户需要自行将兼容的 `ffmpeg.exe` 放入：

```text
LocalLens-Server-Windows-x64/
└── bin/
    └── ffmpeg.exe
```

未安装 FFmpeg 时，图片查看和视频原文件播放仍然可用，但视频缩略图无法生成。

## 校验下载文件

Windows PowerShell：

```powershell
Get-FileHash .\LocalLens-Android-universal.apk -Algorithm SHA256
Get-Content .\SHA256SUMS.txt
```

比较两处 SHA-256 值是否一致。
