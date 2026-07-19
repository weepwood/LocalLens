import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../models/collections.dart';
import '../models/server_runtime_state.dart';
import '../models/server_state.dart';
import '../services/api_client.dart';
import '../services/embedded_server_supervisor.dart';

class ServerScreen extends StatefulWidget {
  const ServerScreen({
    required this.api,
    required this.onDisconnect,
    super.key,
  });

  final ApiClient api;
  final Future<void> Function() onDisconnect;

  @override
  State<ServerScreen> createState() => _ServerScreenState();
}

class _ServerScreenState extends State<ServerScreen> {
  final EmbeddedServerSupervisor _supervisor =
      EmbeddedServerSupervisor.instance;
  List<LibraryInfo> _libraries = const [];
  MediaStats? _stats;
  ScanStatus? _scan;
  List<DeviceInfo> _devices = const [];
  PairingSessionInfo? _pairing;
  Timer? _pollTimer;
  StreamSubscription<ServerRuntimeState>? _runtimeSubscription;
  ServerRuntimeState _runtime = EmbeddedServerSupervisor.instance.state;
  bool _loading = true;
  bool _adminAvailable = true;
  bool _startingScan = false;
  bool _creatingPair = false;
  Object? _error;

  bool get _isLocalWindows =>
      Platform.isWindows &&
      (widget.api.settings.normalizedBaseUrl.contains('127.0.0.1') ||
          widget.api.settings.normalizedBaseUrl.contains('localhost'));

  @override
  void initState() {
    super.initState();
    _runtimeSubscription = _supervisor.states.listen((state) {
      if (mounted) setState(() => _runtime = state);
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    unawaited(_runtimeSubscription?.cancel());
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait<Object>([
        widget.api.listLibraries(),
        widget.api.getStats(),
        widget.api.getScanStatus(),
      ]);
      if (!mounted) return;
      setState(() {
        _libraries = results[0] as List<LibraryInfo>;
        _stats = results[1] as MediaStats;
        _scan = results[2] as ScanStatus;
        _loading = false;
        _error = null;
      });
      _syncPolling();
      unawaited(_loadDevices());
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error;
      });
    }
  }

  Future<void> _loadDevices() async {
    try {
      final devices = await widget.api.listDevices();
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _adminAvailable = true;
      });
    } on ApiException catch (error) {
      if (mounted && error.statusCode == 403) {
        setState(() => _adminAvailable = false);
      }
    } catch (_) {}
  }

  void _syncPolling() {
    _pollTimer?.cancel();
    if (_scan?.running != true) return;
    _pollTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_poll()),
    );
  }

  Future<void> _poll() async {
    try {
      final scan = await widget.api.getScanStatus();
      final stats = await widget.api.getStats();
      if (!mounted) return;
      final finished = _scan?.running == true && !scan.running;
      setState(() {
        _scan = scan;
        _stats = stats;
      });
      if (finished) {
        _pollTimer?.cancel();
        await _load();
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null && _stats == null) {
      return Center(
        child: FilledButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh),
          label: Text('读取服务器失败：$_error'),
        ),
      );
    }
    final stats = _stats!;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('服务器控制中心',
                        style: Theme.of(context).textTheme.headlineSmall),
                    Text(
                      _isLocalWindows
                          ? '管理本机内置服务、媒体库、扫描任务和已授权设备。'
                          : '查看远程服务器状态、媒体库和已授权设备。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '刷新',
                onPressed: _load,
                icon: const Icon(Icons.refresh),
              ),
              PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'disconnect') unawaited(widget.onDisconnect());
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'disconnect',
                    child: Text('切换服务器'),
                  ),
                ],
              ),
            ],
          ),
          if (_isLocalWindows) ...[
            const SizedBox(height: 16),
            _buildRuntimeCard(),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _MetricCard(label: '媒体', value: '${stats.total}', icon: Icons.photo_library_outlined),
              _MetricCard(label: '图片', value: '${stats.images}', icon: Icons.image_outlined),
              _MetricCard(label: '视频', value: '${stats.videos}', icon: Icons.movie_outlined),
              _MetricCard(label: '收藏', value: '${stats.favorites}', icon: Icons.favorite_outline),
              _MetricCard(label: '总容量', value: _formatBytes(stats.sizeBytes), icon: Icons.storage_outlined),
              _MetricCard(label: '元数据任务', value: '${stats.metadataPending}', icon: Icons.data_object_outlined),
              _MetricCard(label: '缩略图任务', value: '${stats.thumbnailsPending}', icon: Icons.photo_size_select_large_outlined),
            ],
          ),
          const SizedBox(height: 16),
          _buildScanCard(),
          const SizedBox(height: 16),
          _buildLibrariesCard(),
          if (_adminAvailable) ...[
            const SizedBox(height: 16),
            _buildPairingCard(),
            const SizedBox(height: 16),
            _buildDevicesCard(),
          ],
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildRuntimeCard() {
    final status = _runtime.status;
    final running = status == ServerRuntimeStatus.running;
    final label = switch (status) {
      ServerRuntimeStatus.starting => '启动中',
      ServerRuntimeStatus.running => '运行中',
      ServerRuntimeStatus.stopping => '停止中',
      ServerRuntimeStatus.failed => '异常',
      ServerRuntimeStatus.portConflict => '端口冲突',
      ServerRuntimeStatus.configurationError => '配置错误',
      _ => '已停止',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(running ? Icons.cloud_done_outlined : Icons.dns_outlined),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('本机内置服务',
                          style: Theme.of(context).textTheme.titleMedium),
                      Text(
                        '$label · http://127.0.0.1:9527${_runtime.processId == null ? '' : ' · PID ${_runtime.processId}'}',
                      ),
                    ],
                  ),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: running || status == ServerRuntimeStatus.starting
                          ? null
                          : () => unawaited(_supervisor.start()),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('启动'),
                    ),
                    OutlinedButton.icon(
                      onPressed: running
                          ? () => unawaited(_supervisor.stop())
                          : null,
                      icon: const Icon(Icons.stop),
                      label: const Text('停止'),
                    ),
                    FilledButton.icon(
                      onPressed: running
                          ? () => unawaited(_supervisor.restart())
                          : null,
                      icon: const Icon(Icons.restart_alt),
                      label: const Text('重启'),
                    ),
                  ],
                ),
              ],
            ),
            if (_runtime.startedAt != null || _runtime.restartCount > 0) ...[
              const SizedBox(height: 10),
              Text(
                '${_runtime.startedAt == null ? '' : '启动于 ${_dateTime(_runtime.startedAt!)}'}${_runtime.restartCount == 0 ? '' : ' · 自动恢复 ${_runtime.restartCount} 次'}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if ((_runtime.lastError ?? '').isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                _runtime.lastError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildScanCard() {
    final scan = _scan;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(scan?.running == true ? Icons.sync : Icons.manage_search_outlined),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    scan?.running == true ? '正在扫描' : '媒体索引',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                FilledButton.icon(
                  onPressed: !_adminAvailable || scan?.running == true || _startingScan
                      ? null
                      : _startScan,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('重新扫描'),
                ),
              ],
            ),
            if (scan?.running == true) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: scan?.progress),
              const SizedBox(height: 8),
              Text('发现 ${scan?.discovered ?? 0} · 索引 ${scan?.indexed ?? 0} · 失败 ${scan?.failed ?? 0}'),
            ] else ...[
              const SizedBox(height: 8),
              const Text('文件监听会持续同步变化，全量扫描用于校验漏失事件。'),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildLibrariesCard() {
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.folder_copy_outlined),
            title: const Text('媒体库'),
            subtitle: const Text('第一阶段显示现有目录；下一阶段提供添加、编辑与移除。'),
          ),
          const Divider(height: 1),
          for (final library in _libraries)
            ListTile(
              leading: Icon(library.enabled ? Icons.folder_open_outlined : Icons.folder_off_outlined),
              title: Text(library.name),
              subtitle: Text('${library.recursive ? '递归扫描' : '仅当前目录'} · ${library.lastScannedAt == null ? '尚未扫描' : '上次 ${_dateTime(library.lastScannedAt!)}'}'),
              trailing: Text('${library.mediaCount}'),
            ),
        ],
      ),
    );
  }

  Widget _buildPairingCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.qr_code_2_rounded),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('手机扫码配对', style: Theme.of(context).textTheme.titleMedium),
                ),
                FilledButton.icon(
                  onPressed: _creatingPair ? null : _createPairing,
                  icon: const Icon(Icons.qr_code_rounded),
                  label: const Text('生成二维码'),
                ),
              ],
            ),
            if (_pairing != null) ...[
              const SizedBox(height: 16),
              Center(
                child: Image.network(
                  widget.api.resolve(_pairing!.qrUrl).toString(),
                  headers: widget.api.authorizationHeaders,
                  width: 220,
                  height: 220,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDevicesCard() {
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.devices_outlined),
            title: const Text('已配对设备'),
            trailing: IconButton(
              tooltip: '刷新设备',
              onPressed: _loadDevices,
              icon: const Icon(Icons.refresh),
            ),
          ),
          const Divider(height: 1),
          if (_devices.isEmpty)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text('暂无已配对设备'),
            )
          else
            for (final device in _devices)
              ListTile(
                leading: Icon(_platformIcon(device.platform)),
                title: Text(device.name),
                subtitle: Text(device.lastSeenAt == null
                    ? '尚未连接'
                    : '最近 ${_dateTime(device.lastSeenAt!)}'),
                trailing: device.revokedAt != null
                    ? const Icon(Icons.block)
                    : IconButton(
                        tooltip: '撤销设备',
                        onPressed: () => _revoke(device),
                        icon: const Icon(Icons.delete_outline),
                      ),
              ),
        ],
      ),
    );
  }

  Future<void> _startScan() async {
    setState(() => _startingScan = true);
    try {
      final scan = await widget.api.startScan();
      if (!mounted) return;
      setState(() {
        _scan = scan;
        _startingScan = false;
      });
      _syncPolling();
    } catch (error) {
      if (mounted) setState(() => _startingScan = false);
      _showError(error);
    }
  }

  Future<void> _createPairing() async {
    setState(() => _creatingPair = true);
    try {
      final pairing = await widget.api.createPairingSession();
      if (!mounted) return;
      setState(() {
        _pairing = pairing;
        _creatingPair = false;
      });
    } catch (error) {
      if (mounted) setState(() => _creatingPair = false);
      _showError(error);
    }
  }

  Future<void> _revoke(DeviceInfo device) async {
    try {
      await widget.api.revokeDevice(device.id);
      await _loadDevices();
    } catch (error) {
      _showError(error);
    }
  }

  void _showError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error.toString())),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.label, required this.value, required this.icon});

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 170,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(icon),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: Theme.of(context).textTheme.bodySmall),
                    Text(value, style: Theme.of(context).textTheme.titleMedium),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  return '${(mb / 1024).toStringAsFixed(1)} GB';
}

String _dateTime(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}

IconData _platformIcon(String platform) {
  return switch (platform.toLowerCase()) {
    'android' => Icons.android,
    'ios' => Icons.phone_iphone,
    'windows' => Icons.desktop_windows_outlined,
    _ => Icons.devices_other_outlined,
  };
}
