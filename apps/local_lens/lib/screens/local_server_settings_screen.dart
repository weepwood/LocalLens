import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../models/local_server_config.dart';
import '../models/server_runtime_state.dart';
import '../models/server_settings.dart';
import '../services/local_server_supervisor.dart';
import '../widgets/app_components.dart';

class LocalServerSettingsScreen extends StatefulWidget {
  const LocalServerSettingsScreen({
    required this.supervisor,
    required this.onSaved,
    required this.onClose,
    super.key,
  });

  final LocalServerSupervisor supervisor;
  final Future<void> Function(ServerSettings settings) onSaved;
  final VoidCallback onClose;

  @override
  State<LocalServerSettingsScreen> createState() =>
      _LocalServerSettingsScreenState();
}

class _LocalServerSettingsScreenState
    extends State<LocalServerSettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _serverNameController = TextEditingController();
  final _libraryNameController = TextEditingController();
  final _libraryPathController = TextEditingController();
  final _portController = TextEditingController();
  final _cacheController = TextEditingController();

  LocalServerConfig? _config;
  bool _loading = true;
  bool _saving = false;
  bool _allowLan = true;
  bool _autoScan = true;
  bool _watchFiles = true;
  int _thumbnailWorkers = 2;
  int _metadataWorkers = 2;
  int _transcodeWorkers = 1;
  String _transcodeHardware = 'software';
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _serverNameController.dispose();
    _libraryNameController.dispose();
    _libraryPathController.dispose();
    _portController.dispose();
    _cacheController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final config = await widget.supervisor.loadConfig();
      if (config == null) {
        throw const LocalServerException('本地服务器配置不存在');
      }
      final library = config.libraries.first;
      if (!mounted) return;
      setState(() {
        _config = config;
        _serverNameController.text = config.serverName;
        _libraryNameController.text = library.name;
        _libraryPathController.text = library.path;
        _portController.text = '${config.port}';
        _cacheController.text = '${config.transcodeCacheGB}';
        _allowLan = config.allowLan;
        _autoScan = config.autoScan;
        _watchFiles = config.watchFiles;
        _thumbnailWorkers = config.thumbnailWorkers;
        _metadataWorkers = config.metadataWorkers;
        _transcodeWorkers = config.transcodeWorkers;
        _transcodeHardware = config.transcodeHardware;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('本机服务器设置'),
        leading: IconButton(
          tooltip: '返回',
          onPressed: _saving ? null : widget.onClose,
          icon: const Icon(LucideIcons.arrowLeft),
        ),
        actions: [
          TextButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(LucideIcons.save, size: 18),
            label: const Text('保存并重启'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _runtimeCard(),
            const SizedBox(height: 16),
            _Section(
              title: '基本设置',
              description: '修改服务器名称、端口和局域网访问。',
              icon: LucideIcons.serverCog,
              child: Column(
                children: [
                  TextFormField(
                    controller: _serverNameController,
                    decoration: const InputDecoration(labelText: '服务器名称'),
                    validator: _required,
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _portController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '服务端口',
                      helperText: '允许范围 1024～65535',
                    ),
                    validator: (value) {
                      final port = int.tryParse(value?.trim() ?? '');
                      return port == null || port < 1024 || port > 65535
                          ? '请输入有效端口'
                          : null;
                    },
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    value: _allowLan,
                    onChanged: _saving
                        ? null
                        : (value) => setState(() => _allowLan = value),
                    title: const Text('允许手机和局域网设备访问'),
                    subtitle: const Text('关闭后服务端只监听 127.0.0.1。'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _Section(
              title: '媒体库',
              description: '管理主媒体库目录和自动扫描策略。',
              icon: LucideIcons.library,
              child: Column(
                children: [
                  TextFormField(
                    controller: _libraryNameController,
                    decoration: const InputDecoration(labelText: '媒体库名称'),
                    validator: _required,
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _libraryPathController,
                    readOnly: true,
                    decoration: InputDecoration(
                      labelText: '媒体目录',
                      suffixIcon: TextButton(
                        onPressed: _saving ? null : _chooseDirectory,
                        child: const Text('更换目录'),
                      ),
                    ),
                    validator: _required,
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    value: _autoScan,
                    onChanged: _saving
                        ? null
                        : (value) => setState(() => _autoScan = value),
                    title: const Text('启动时自动扫描'),
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    value: _watchFiles,
                    onChanged: _saving
                        ? null
                        : (value) => setState(() => _watchFiles = value),
                    title: const Text('实时监听文件变化'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _Section(
              title: '后台任务',
              description: 'Worker 越多处理越快，但会增加 CPU、磁盘和 SQLite 压力。',
              icon: LucideIcons.gauge,
              child: Column(
                children: [
                  _WorkerSlider(
                    label: '缩略图 Worker',
                    value: _thumbnailWorkers,
                    max: 8,
                    enabled: !_saving,
                    onChanged: (value) =>
                        setState(() => _thumbnailWorkers = value),
                  ),
                  _WorkerSlider(
                    label: '元数据 Worker',
                    value: _metadataWorkers,
                    max: 8,
                    enabled: !_saving,
                    onChanged: (value) =>
                        setState(() => _metadataWorkers = value),
                  ),
                  _WorkerSlider(
                    label: '视频转码 Worker',
                    value: _transcodeWorkers,
                    max: 4,
                    enabled: !_saving,
                    onChanged: (value) =>
                        setState(() => _transcodeWorkers = value),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _Section(
              title: '视频转码',
              description: '选择转码方式并限制 HLS 缓存空间。',
              icon: LucideIcons.clapperboard,
              child: Column(
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: _transcodeHardware,
                    decoration: const InputDecoration(labelText: '转码方式'),
                    items: const [
                      DropdownMenuItem(
                        value: 'software',
                        child: Text('CPU 软件编码'),
                      ),
                      DropdownMenuItem(
                        value: 'nvenc',
                        child: Text('NVIDIA NVENC'),
                      ),
                      DropdownMenuItem(
                        value: 'qsv',
                        child: Text('Intel Quick Sync'),
                      ),
                      DropdownMenuItem(
                        value: 'amf',
                        child: Text('AMD AMF'),
                      ),
                    ],
                    onChanged: _saving
                        ? null
                        : (value) => setState(
                              () => _transcodeHardware = value ?? 'software',
                            ),
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _cacheController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '转码缓存上限（GB）',
                      helperText: '允许范围 1～500 GB',
                    ),
                    validator: (value) {
                      final size = int.tryParse(value?.trim() ?? '');
                      return size == null || size < 1 || size > 500
                          ? '请输入 1 到 500'
                          : null;
                    },
                  ),
                  const SizedBox(height: 12),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      _config?.ffmpegPath.isNotEmpty == true
                          ? LucideIcons.circleCheck
                          : LucideIcons.circleAlert,
                    ),
                    title: Text(
                      _config?.ffmpegPath.isNotEmpty == true
                          ? 'FFmpeg 已配置'
                          : 'FFmpeg 未安装',
                    ),
                    subtitle: Text(
                      _config?.ffmpegPath.isNotEmpty == true
                          ? _config!.ffmpegPath
                          : r'将 ffmpeg.exe 和 ffprobe.exe 放入 runtime\media-tools。',
                    ),
                  ),
                ],
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(_error!),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: const Icon(LucideIcons.save, size: 18),
              label: const Text('保存配置并重启本机服务器'),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _runtimeCard() {
    return StreamBuilder<ServerRuntimeState>(
      stream: widget.supervisor.states,
      initialData: widget.supervisor.state,
      builder: (context, snapshot) {
        final state = snapshot.data ?? widget.supervisor.state;
        final color = switch (state.status) {
          ServerRuntimeStatus.running => const Color(0xFF2B9B66),
          ServerRuntimeStatus.starting ||
          ServerRuntimeStatus.stopping ||
          ServerRuntimeStatus.restarting => const Color(0xFFD58A18),
          ServerRuntimeStatus.failed ||
          ServerRuntimeStatus.portConflict ||
          ServerRuntimeStatus.configurationError =>
            Theme.of(context).colorScheme.error,
          ServerRuntimeStatus.stopped => Theme.of(context).colorScheme.outline,
        };
        return AppSurface(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 10,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  AppStatusPill(
                    label: _statusLabel(state.status),
                    icon: state.isRunning
                        ? LucideIcons.circleCheck
                        : LucideIcons.server,
                    color: color,
                  ),
                  Text('端口 ${state.port}'),
                  if (state.processId != null) Text('PID ${state.processId}'),
                  if (state.version != null) Text('v${state.version}'),
                ],
              ),
              if (state.lastError != null) ...[
                const SizedBox(height: 10),
                Text(
                  state.lastError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  OutlinedButton.icon(
                    onPressed: state.isBusy
                        ? null
                        : () {
                            if (state.isRunning) {
                              unawaited(widget.supervisor.stop());
                            } else {
                              unawaited(widget.supervisor.start());
                            }
                          },
                    icon: Icon(
                      state.isRunning ? LucideIcons.square : LucideIcons.play,
                      size: 17,
                    ),
                    label: Text(state.isRunning ? '停止' : '启动'),
                  ),
                  OutlinedButton.icon(
                    onPressed: state.isBusy
                        ? null
                        : () => unawaited(widget.supervisor.restart()),
                    icon: const Icon(LucideIcons.refreshCw, size: 17),
                    label: const Text('重启'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => unawaited(
                      widget.supervisor.openDataDirectory(),
                    ),
                    icon: const Icon(LucideIcons.folderOpen, size: 17),
                    label: const Text('数据目录'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => unawaited(
                      widget.supervisor.openLogDirectory(),
                    ),
                    icon: const Icon(LucideIcons.fileText, size: 17),
                    label: const Text('日志目录'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _chooseDirectory() async {
    final path = await getDirectoryPath();
    if (path == null || !mounted) return;
    setState(() => _libraryPathController.text = path);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate() || _config == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final port = int.parse(_portController.text.trim());
      final lanAddress =
          _allowLan ? await widget.supervisor.discoverLanIPv4() : null;
      final currentLibrary = _config!.libraries.first;
      final config = _config!.copyWith(
        serverName: _serverNameController.text.trim(),
        listenAddress: '${_allowLan ? '0.0.0.0' : '127.0.0.1'}:$port',
        publicUrl: lanAddress == null ? '' : 'http://$lanAddress:$port',
        autoScan: _autoScan,
        watchFiles: _watchFiles,
        thumbnailWorkers: _thumbnailWorkers,
        metadataWorkers: _metadataWorkers,
        transcodeWorkers: _transcodeWorkers,
        transcodeCacheGB: int.parse(_cacheController.text.trim()),
        transcodeHardware: _transcodeHardware,
        libraries: <LocalLibraryConfig>[
          currentLibrary.copyWith(
            name: _libraryNameController.text.trim(),
            path: _libraryPathController.text.trim(),
          ),
        ],
      );
      final settings = await widget.supervisor.applyConfig(config);
      await widget.onSaved(settings);
      if (!mounted) return;
      setState(() => _config = config);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('本机服务器配置已保存并重启')),
      );
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? _required(String? value) {
    return value == null || value.trim().isEmpty ? '此项不能为空' : null;
  }

  String _statusLabel(ServerRuntimeStatus status) => switch (status) {
        ServerRuntimeStatus.stopped => '已停止',
        ServerRuntimeStatus.starting => '启动中',
        ServerRuntimeStatus.running => '运行中',
        ServerRuntimeStatus.stopping => '停止中',
        ServerRuntimeStatus.restarting => '重启中',
        ServerRuntimeStatus.failed => '运行失败',
        ServerRuntimeStatus.portConflict => '端口冲突',
        ServerRuntimeStatus.configurationError => '配置错误',
      };
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.description,
    required this.icon,
    required this.child,
  });

  final String title;
  final String description;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AppSurface(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 21),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 3),
                    Text(
                      description,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          child,
        ],
      ),
    );
  }
}

class _WorkerSlider extends StatelessWidget {
  const _WorkerSlider({
    required this.label,
    required this.value,
    required this.max,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final int value;
  final int max;
  final bool enabled;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 160, child: Text(label)),
        Expanded(
          child: Slider(
            value: value.toDouble(),
            min: 1,
            max: max.toDouble(),
            divisions: max - 1,
            label: '$value',
            onChanged: enabled ? (next) => onChanged(next.round()) : null,
          ),
        ),
        SizedBox(
          width: 32,
          child: Text('$value', textAlign: TextAlign.end),
        ),
      ],
    );
  }
}
