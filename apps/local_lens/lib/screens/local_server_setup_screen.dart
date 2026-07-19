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
    required this.onUseRemote,
    super.key,
  });

  final LocalServerSupervisor supervisor;
  final Future<void> Function(ServerSettings settings) onCompleted;
  final VoidCallback onUseRemote;

  @override
  State<LocalServerSetupScreen> createState() => _LocalServerSetupScreenState();
}

class _LocalServerSetupScreenState extends State<LocalServerSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _serverNameController = TextEditingController(text: 'LocalLens');
  final _libraryNameController = TextEditingController(text: '媒体库');
  final _pathController = TextEditingController();
  final _portController = TextEditingController(text: '9527');
  bool _allowLan = true;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _serverNameController.dispose();
    _libraryNameController.dispose();
    _pathController.dispose();
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
              constraints: const BoxConstraints(maxWidth: 680),
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
                                  'Windows 客户端会自动运行内置服务器，不再需要单独启动服务端程序。',
                                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                        color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                        validator: (value) => value == null || value.trim().isEmpty
                            ? '请输入服务器名称'
                            : null,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _libraryNameController,
                        decoration: const InputDecoration(
                          labelText: '媒体库名称',
                          prefixIcon: Icon(LucideIcons.library, size: 19),
                        ),
                        validator: (value) => value == null || value.trim().isEmpty
                            ? '请输入媒体库名称'
                            : null,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _pathController,
                        readOnly: true,
                        decoration: InputDecoration(
                          labelText: '图片和视频目录',
                          hintText: r'D:\Media',
                          prefixIcon: const Icon(LucideIcons.folderOpen, size: 19),
                          suffixIcon: TextButton(
                            onPressed: _submitting ? null : _chooseDirectory,
                            child: const Text('选择目录'),
                          ),
                        ),
                        validator: (value) => value == null || value.trim().isEmpty
                            ? '请选择媒体目录'
                            : null,
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
                        subtitle: const Text('开启后监听局域网；本机客户端仍通过 127.0.0.1 安全连接。'),
                        secondary: const Icon(LucideIcons.smartphone),
                      ),
                      if (!widget.supervisor.hasBundledServer) ...[
                        const SizedBox(height: 14),
                        _MessagePanel(
                          error: true,
                          message: '当前安装目录没有找到内置服务器。请使用新版统一 Windows 安装包。',
                        ),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: 14),
                        _MessagePanel(error: true, message: _error!),
                      ],
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        onPressed: _submitting || !widget.supervisor.hasBundledServer
                            ? null
                            : _submit,
                        icon: _submitting
                            ? const SizedBox.square(
                                dimension: 17,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(LucideIcons.play, size: 18),
                        label: Text(_submitting ? '正在启动本机服务器…' : '创建媒体库并启动'),
                      ),
                      const SizedBox(height: 10),
                      TextButton.icon(
                        onPressed: _submitting ? null : widget.onUseRemote,
                        icon: const Icon(LucideIcons.link, size: 18),
                        label: const Text('改为连接另一台 LocalLens 服务器'),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '配置、数据库、缓存和日志将保存在：\n${widget.supervisor.applicationDataPath}',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
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

  Future<void> _chooseDirectory() async {
    final path = await getDirectoryPath();
    if (path == null || !mounted) return;
    setState(() => _pathController.text = path);
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final config = await widget.supervisor.createDefaultConfig(
        libraryPath: _pathController.text.trim(),
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
