LocalLens 媒体工具目录
======================

正式构建流程会在此目录放入 ffmpeg.exe 与 ffprobe.exe，并将它们作为
Tauri 资源打包。应用首次运行时会把这些文件复制到用户数据目录：

%LOCALAPPDATA%\com.weepwood.locallens.desktop\runtime\media-tools

开发环境可以手动把兼容的 Windows x64 FFmpeg 与 FFprobe 放在这里。
FFmpeg 是独立的第三方程序，发布包必须同时包含相应许可证与来源说明。
