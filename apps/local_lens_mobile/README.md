# LocalLens React Native 移动端

该目录是 LocalLens 的新移动端实现，使用 Expo + React Native + TypeScript，直接复用现有 Go 服务端的 `/api/v1` 接口。

现有 `apps/local_lens` Flutter 工程继续承担 Windows 统一管理端；Android/iOS 新功能优先在本目录实现。

## 当前功能

- 手动填写服务地址和管理员/设备 Token；
- 使用摄像头扫描 Windows 管理端的一次性配对二维码；
- Token 写入 Android Keystore / iOS Keychain 对应的 SecureStore；
- 时间线媒体网格、下拉刷新和游标分页；
- 文件名或相对路径搜索；
- 全部、图片、视频、收藏筛选；
- 图片原图查看；
- 带 Bearer Header 的视频流播放；
- 收藏与取消收藏；
- 浅色、深色系统主题和手机/平板自适应列数。

## 环境

- Node.js 22.13 或更高版本；
- Android Studio 与 Android SDK；
- iOS 构建需要 macOS 和 Xcode；
- Expo SDK 57 / React Native 0.86。

## 本地开发

```bash
cd apps/local_lens_mobile
npm install
npm run typecheck
npm start
```

生成 Android 原生工程并运行：

```bash
npx expo prebuild --platform android --clean
npm run android
```

## 连接方式

### 扫码配对

1. Windows LocalLens 客户端进入“服务器与设备”；
2. 生成一次性配对二维码；
3. 移动端点击“扫描二维码配对”；
4. 服务端签发只属于该设备的 Token。

### 手动连接

填写手机能够访问的局域网地址，例如：

```text
http://192.168.1.20:9527
```

不要填写 `localhost` 或 `127.0.0.1`，它们在手机上指向手机自身。

## 安全边界

- 当前局域网 HTTP 模式通过 Android `usesCleartextTraffic` 支持；
- 不建议将 9527 端口直接暴露到公网；
- 远程访问应使用 Tailscale、WireGuard 等可信 VPN；
- 移动端只接收媒体 ID、相对路径和媒体 URL，不接收 Windows 绝对路径；
- 断开服务器会清除本机安全存储中的地址和 Token。

## 后续迁移

下一阶段计划补齐：

- 跨端视频续播进度；
- 相册、标签和星级评分管理；
- 文件夹树与拍摄日期分组；
- HLS 播放能力协商和字幕选择；
- iOS GitHub Actions 构建；
- 正式签名、版本升级与应用商店发布流程。
