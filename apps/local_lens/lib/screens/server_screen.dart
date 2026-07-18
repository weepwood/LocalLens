import 'dart:async';

import 'package:flutter/material.dart';

import '../models/collections.dart';
import '../models/server_state.dart';
import '../services/api_client.dart';

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
  List<LibraryInfo> _libraries = const [];
  MediaStats? _stats;
  ScanStatus? _scan;
  List<DeviceInfo> _devices = const [];
  PairingSessionInfo? _pairing;
  Timer? _pollTimer;
  bool _loading = true;
  bool _adminAvailable = true;
  bool _startingScan = false;
  bool _creatingPair = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
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
      if (!mounted) return;
      if (error.statusCode == 403) {
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
                    Text(
                      '服务器与设备',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    Text(
                      '查看索引、后台任务、扫码配对和已授权设备。',
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
                  if (value == 'disconnect') {
                    unawaited(widget.onDisconnect());
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'disconnect',
                    child: Text('断开服务器'),
                  ),
                ],
              ),
            ],
          ),
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
          Text('媒体库', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                for (final library in _libraries)
                  ListTile(
                    leading: Icon(
                      library.enabled
                          ? Icons.folder_open_outlined
                          : Icons.folder_off_outlined,
                    ),
                    title: Text(library.name),
                    subtitle: Text(
                      '${library.recursive ? '递归扫描' : '仅当前目录'} · ${library.lastScannedAt == null ? '尚未扫描' : '上次 ${_dateTime(library.lastScannedAt!)}'}',
                    ),
                    trailing: Text('${library.mediaCount}'),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (_adminAvailable) ...[
            _buildPairingCard(),
            const SizedBox(height: 16),
            _buildDevicesCard(),
          ] else
            Card(
              child: ListTile(
                leading: const Icon(Icons.verified_user_outlined),
                title: const Text('当前为已配对设备'),
                subtitle: const Text(
                  '设备令牌可以浏览和管理媒体，但创建配对码、全量扫描和撤销设备需要 Windows 管理端使用管理员 Token。',
                ),
              ),
            ),
          const SizedBox(height: 40),
        ],
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
                    scan?.running == true
                        ? '正在扫描${scan?.current == null ? '' : '：${scan!.current}'}'
                        : '媒体索引',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                FilledButton.icon(
                  onPressed: !_adminAvailable || scan?.running == true || _startingScan
                      ? null
                      : _startScan,
                  icon: _startingScan
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow_rounded),
                  label: const Text('重新扫描'),
                ),
              ],
            ),
            if (scan?.running == true) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: scan?.progress),
              const SizedBox(height: 8),
              Text('发现 ${scan?.discovered ?? 0} · 索引 ${scan?.indexed ?? 0} · 失败 ${scan?.failed ?? 0}'),
            ] else if ((scan?.errorMessage ?? '').isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                scan!.errorMessage!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ] else ...[
              const SizedBox(height: 8),
              const Text('fsnotify 会持续监听文件变化；全量扫描用于校验漏失事件。'),
            ],
          ],
        ),
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
                  child: Text(
                    '手机扫码配对',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                FilledButton.icon(
                  onPressed: _creatingPair ? null : _createPairing,
                  icon: _creatingPair
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.qr_code_rounded),
                  label: const Text('生成二维码'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text('二维码短时有效，只能领取一次。手机领取后会获得独立令牌。'),
            if (_pairing != null) ...[
              const SizedBox(height: 16),
              Center(
                child: Image.network(
                  widget.api.resolve(_pairing!.qrUrl).toString(),
                  headers: widget.api.authorizationHeaders,
                  width: 260,
                  height: 260,
                  errorBuilder: (_, error, __) => Text('二维码加载失败：$error'),
                ),
              ),
              Center(child: Text('有效期至 ${_dateTime(_pairing!.expiresAt)}')),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDevicesCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.devices_outlined),
                const SizedBox(width: 10),
                Text('已配对设备', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                IconButton(
                  tooltip: '刷新设备',
                  onPressed: _loadDevices,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            if (_devices.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(child: Text('暂无已配对设备')),
              )
            else
              for (final device in _devices)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(_platformIcon(device.platform)),
                  title: Text(device.name),
                  subtitle: Text(
                    '${device.platform.isEmpty ? '未知平台' : device.platform} · ${device.lastSeenAt == null ? '尚未连接' : '最近 ${_dateTime(device.lastSeenAt!)}'}${device.revokedAt == null ? '' : ' · 已撤销'}',
                  ),
                  trailing: device.revokedAt != null
                      ? const Icon(Icons.block, color: Colors.grey)
                      : IconButton(
                          tooltip: '撤销设备',
                          onPressed: () => _revoke(device),
                          icon: const Icon(Icons.delete_outline),
                        ),
                ),
          ],
        ),
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
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _startingScan = false;
        if (error.statusCode == 403) _adminAvailable = false;
      });
      _showError(error);
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
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _creatingPair = false;
        if (error.statusCode == 403) _adminAvailable = false;
      });
      _showError(error);
    } catch (error) {
      if (mounted) setState(() => _creatingPair = false);
      _showError(error);
    }
  }

  Future<void> _revoke(DeviceInfo device) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('撤销 ${device.name}？'),
            content: const Text('该设备的令牌会立即失效，需要重新扫码才能连接。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('撤销'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
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
  const _MetricCard({
    required this.label,
    required this.value,
    required this.icon,
  });

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
                    Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
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
  switch (platform.toLowerCase()) {
    case 'android':
      return Icons.android;
    case 'ios':
      return Icons.phone_iphone;
    case 'windows':
      return Icons.desktop_windows_outlined;
    default:
      return Icons.devices_other_outlined;
  }
}
