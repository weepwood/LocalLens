import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../models/server_settings.dart';
import '../services/local_server_supervisor.dart';
import '../widgets/app_components.dart';

class LocalServerSetupScreen extends StatefulWidget {
  const LocalServerSetupScreen({
    required this.supervisor,
    required this.onCompleted,
    this.onUseRemote,
    super.key,
  });

  final LocalServerSupervisor supervisor;
  final Future<void> Function(ServerSettings settings) onCompleted;
  final VoidCallback? onUseRemote;

  @override
  State<LocalServerSetupScreen> createState() => _LocalServerSetupScreenState();
}

class _LocalServerSetupScreenState extends State<LocalServerSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _serverNameController = TextEditingController(text: 'LocalLens');
  final _libraryNameController = TextEditingController(text: '媒体库');
  final _mediaPathController = TextEditingController();
  final _dataPathController = TextEditingController();
  final _portController = TextEditingController(text: '9527');
  bool _allowLan = true;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _dataPathController.text = widget.supervisor.defaultApplicationDataPath;
  }

  @override
  void dispose() {
    _serverNameController.dispose();
    _libraryNameController.dispose();
    _mediaPathController.dispose();
    _dataPathController.dispose();
    _portController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 700),
              child: AppSurface(
                padding: const EdgeInsets.all(30),
                radius: 20,
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 54,
                            height: 54,
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            alignment: Alignment.center,
                            child: const Icon(LucideIcons.serverCog, size: 26),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '设置本机 LocalLens',
                                  style: Theme.of(context).textTheme.headlineSmall,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Windows 应用会自动运行内置服务端和 FFmpeg，无需另外安装。',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodyMedium
                                      ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant,
                                      ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 28),
                      TextFormField(
                        controller: _serverNameController,
                        decoration: const InputDecoration(
                          labelText: '服务器名称',
                          prefixIcon: Icon(LucideIcons.monitorCog, size: 19),
                        ),
                        validator: _required,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _libraryNameController,
                        decoration: const InputDecoration(
                          labelText: '媒体库名称',
                          prefixIcon: Icon(LucideIcons.library, size: 19),
                        ),
                        validator: _required,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _mediaPathController,
                        readOnly: true,
                        decoration: InputDecoration(
                          labelText: '图片和视频目录',
                          hintText: r'D:\Media',
                          helperText: '只读取和索引原始媒体；重置 LocalLens 时不会删除这里的文件。',
                          prefixIcon: const Icon(LucideIcons.images, size: 19),
                          suffixIcon: TextButton(
                            onPressed: _submitting ? null : _chooseMediaDirectory,
                            child: const Text('选择目录'),
                          ),
                        ),
                        validator: _required,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _dataPathController,
                        readOnly: true,
                        decoration: InputDecoration(
                          labelText: 'LocalLens 数据目录',
                          helperText: '保存配置、SQLite 数据库、缩略图、转码缓存和日志。',
                          prefixIcon: const Icon(LucideIcons.database, size: 19),
                          suffixIcon: TextButton(
                            onPressed: _submitting ? null : _chooseDataDirectory,
                            child: const Text('更换目录'),
                          ),
                        ),
                        validator: _required,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '选择上级目录后，LocalLens 会创建独立的 LocalLensData 子目录，避免清理数据时影响其他文件。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _portController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '服务端口',
                          helperText: '默认使用 9527；端口被占用时可以修改',
                          prefixIcon: Icon(LucideIcons.network, size: 19),
                        ),
                        validator: (value) {
                          final port = int.tryParse(value?.trim() ?? '');
                          if (port == null || port < 1024 || port > 65535) {
                            return '端口必须在 1024 到 65535 之间';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 18),
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        value: _allowLan,
                        onChanged: _submitting
                            ? null
                            : (value) => setState(() => _allowLan = value),
                        title: const Text('允许手机和局域网设备访问'),
                        subtitle: const Text(
                          '开启后监听局域网；本机客户端仍通过 127.0.0.1 连接。',
                        ),
                        secondary: const Icon(LucideIcons.smartphone),
                      ),
                      if (!widget.supervisor.hasBundledServer) ...[
                        const SizedBox(height: 14),
                        const _MessagePanel(
                          error: true,
                          message:
                              '当前目录不是完整的一体化安装包：缺少 runtime\\LocalLensServer.exe。请重新下载 LocalLens-Windows-x64.zip 并完整解压。',
                        ),
                      ] else if (!widget.supervisor.hasBundledFFmpeg) ...[
                        const SizedBox(height: 14),
                        const _MessagePanel(
                          error: true,
                          message:
                              '安装包缺少内置 FFmpeg。视频缩略图、元数据和转码功能可能不可用，请重新下载安装包。',
                        ),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: 14),
                        _MessagePanel(error: true, message: _error!),
                      ],
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        onPressed: _submitting ||
                                !widget.supervisor.hasBundledServer ||
                                !widget.supervisor.hasBundledFFmpeg
                            ? null
                            : _submit,
                        icon: _submitting
                            ? const SizedBox.square(
                                dimension: 17,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(LucideIcons.play, size: 18),
                        label: Text(
                          _submitting ? '正在创建并启动…' : '创建媒体库并启动',
                        ),
                      ),
                      if (widget.onUseRemote != null) ...[
                        const SizedBox(height: 10),
                        TextButton.icon(
                          onPressed: _submitting ? null : widget.onUseRemote,
                          icon: const Icon(LucideIcons.link, size: 18),
                          label: const Text('改为连接另一台 LocalLens 服务器'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String? _required(String? value) {
    return value == null || value.trim().isEmpty ? '此项不能为空' : null;
  }

  Future<void> _chooseMediaDirectory() async {
    final path = await getDirectoryPath();
    if (path == null || !mounted) return;
    setState(() => _mediaPathController.text = path);
  }

  Future<void> _chooseDataDirectory() async {
    final path = await getDirectoryPath();
    if (path == null || !mounted) return;
    setState(() {
      _dataPathController.text = widget.supervisor.resolveStorageRoot(path);
    });
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final config = await widget.supervisor.createDefaultConfig(
        libraryPath: _mediaPathController.text.trim(),
        storageRoot: _dataPathController.text.trim(),
        libraryName: _libraryNameController.text.trim(),
        serverName: _serverNameController.text.trim(),
        allowLan: _allowLan,
        port: int.parse(_portController.text.trim()),
      );
      await widget.supervisor.start(config: config);
      await widget.onCompleted(ServerSettings(
        baseUrl: config.localBaseUrl,
        token: config.apiToken,
        mode: ServerConnectionMode.local,
      ));
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }
}

class _MessagePanel extends StatelessWidget {
  const _MessagePanel({required this.error, required this.message});

  final bool error;
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: error ? scheme.errorContainer : scheme.primaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            error ? LucideIcons.circleAlert : LucideIcons.circleCheck,
            size: 18,
            color: error ? scheme.onErrorContainer : scheme.onPrimaryContainer,
          ),
          const SizedBox(width: 9),
          Expanded(child: Text(message)),
        ],
      ),
    );
  }
}
