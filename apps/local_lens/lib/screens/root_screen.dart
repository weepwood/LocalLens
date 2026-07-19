import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../models/server_settings.dart';
import '../services/local_server_supervisor.dart';
import '../services/settings_store.dart';
import 'library_screen.dart';
import 'local_server_settings_screen.dart';
import 'local_server_setup_screen.dart';
import 'setup_screen.dart';

class RootScreen extends StatefulWidget {
  const RootScreen({super.key});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  final SettingsStore _store = SettingsStore();
  final LocalServerSupervisor _supervisor = LocalServerSupervisor.instance;
  late Future<ServerSettings?> _settingsFuture;
  bool _editingConnection = false;
  bool _editingLocalServer = false;
  bool _useRemoteSetup = false;
  bool _requiresConnectionModeSelection = false;
  ServerSettings? _activeSettings;
  ServerSettings? _legacySettings;

  bool get _supportsIntegratedServer => Platform.isWindows;

  @override
  void initState() {
    super.initState();
    _settingsFuture = _bootstrap();
  }

  @override
  void dispose() {
    if (_activeSettings?.isLocal == true) {
      unawaited(_supervisor.dispose());
    }
    super.dispose();
  }

  Future<ServerSettings?> _bootstrap() async {
    var settings = await _store.load();
    if (!_supportsIntegratedServer) return settings;

    final hasExplicitMode = await _store.hasExplicitMode();
    if (settings != null &&
        !hasExplicitMode &&
        _supervisor.hasBundledServer) {
      _legacySettings = settings;
      _requiresConnectionModeSelection = true;
      _activeSettings = null;
      return null;
    }

    // The user may remove the selected LocalLens data directory outside the
    // application. In that case SharedPreferences can still say "local" even
    // though server.json no longer exists. Treat it as an uninitialized local
    // installation instead of trapping the user on the startup error screen.
    // The storage pointer is intentionally preserved: reconnecting an external
    // drive and restarting the app can restore the old configuration.
    if (settings?.isLocal == true && !_supervisor.hasConfiguration) {
      await _store.clear();
      settings = null;
    }

    if (settings?.isLocal == true ||
        (settings == null && _supervisor.hasConfiguration)) {
      settings = await _supervisor.ensureRunning();
      await _store.save(settings);
    }
    _activeSettings = settings;
    return settings;
  }

  @override
  Widget build(BuildContext context) {
    if (_editingLocalServer) {
      return LocalServerSettingsScreen(
        supervisor: _supervisor,
        onSaved: _saveSettings,
        onClose: _cancelEditing,
      );
    }

    if (_requiresConnectionModeSelection && _legacySettings != null) {
      return _LegacyConnectionModeScreen(
        previousServer: _legacySettings!.normalizedBaseUrl,
        onUseLocal: _switchLegacyUserToLocal,
        onKeepRemote: _keepLegacyRemoteConnection,
      );
    }

    return FutureBuilder<ServerSettings?>(
      future: _settingsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _StartupScreen(supervisor: _supervisor);
        }
        if (snapshot.hasError) {
          return _StartupErrorScreen(
            error: snapshot.error!,
            supervisor: _supervisor,
            onRetry: _retryBootstrap,
            onResetLocal: _resetLocalInitialization,
            onUseRemote: _showRemoteSetup,
          );
        }

        final settings = snapshot.data;
        _activeSettings = settings;
        if (settings == null || _editingConnection) {
          if (_supportsIntegratedServer &&
              !_useRemoteSetup &&
              settings == null) {
            return LocalServerSetupScreen(
              supervisor: _supervisor,
              onCompleted: _saveSettings,
              onUseRemote: _showRemoteSetup,
            );
          }
          return SetupScreen(
            initialSettings: settings?.isLocal == true ? null : settings,
            onSaved: _saveRemoteSettings,
            onCancel: settings == null ? _cancelRemoteSetup : _cancelEditing,
          );
        }

        return LibraryScreen(
          key: ValueKey('${settings.mode.name}:${settings.normalizedBaseUrl}'),
          settings: settings,
          localServerSupervisor: settings.isLocal ? _supervisor : null,
          onEditConnection: _editConnection,
          onDisconnect: _disconnect,
        );
      },
    );
  }

  Future<void> _saveSettings(ServerSettings settings) async {
    await _store.save(settings);
    if (!mounted) return;
    setState(() {
      _activeSettings = settings;
      _legacySettings = null;
      _requiresConnectionModeSelection = false;
      _editingConnection = false;
      _editingLocalServer = false;
      _useRemoteSetup = false;
      _settingsFuture = Future<ServerSettings?>.value(settings);
    });
  }

  Future<void> _saveRemoteSettings(ServerSettings settings) async {
    await _saveSettings(ServerSettings(
      baseUrl: settings.baseUrl,
      token: settings.token,
      mode: ServerConnectionMode.remote,
    ));
  }

  Future<void> _switchLegacyUserToLocal() async {
    await _store.clear();
    if (!mounted) return;
    setState(() {
      _legacySettings = null;
      _activeSettings = null;
      _requiresConnectionModeSelection = false;
      _editingConnection = false;
      _editingLocalServer = false;
      _useRemoteSetup = false;
      _settingsFuture = Future<ServerSettings?>.value();
    });
  }

  Future<void> _keepLegacyRemoteConnection() async {
    final settings = _legacySettings;
    if (settings == null) return;
    await _saveRemoteSettings(settings);
  }

  void _editConnection() {
    if (_activeSettings?.isLocal == true) {
      setState(() => _editingLocalServer = true);
    } else {
      setState(() => _editingConnection = true);
    }
  }

  void _cancelEditing() {
    setState(() {
      _editingConnection = false;
      _editingLocalServer = false;
    });
  }

  void _showRemoteSetup() {
    setState(() {
      _requiresConnectionModeSelection = false;
      _useRemoteSetup = true;
      _editingConnection = true;
    });
  }

  void _cancelRemoteSetup() {
    setState(() {
      _useRemoteSetup = false;
      _editingConnection = false;
    });
  }

  void _retryBootstrap() {
    setState(() => _settingsFuture = _bootstrap());
  }

  Future<void> _resetLocalInitialization() async {
    await _supervisor.clearDataAndRestoreDefaults();
    await _store.clear();
    if (!mounted) return;
    setState(() {
      _activeSettings = null;
      _legacySettings = null;
      _requiresConnectionModeSelection = false;
      _editingLocalServer = false;
      _editingConnection = false;
      _useRemoteSetup = false;
      _settingsFuture = Future<ServerSettings?>.value();
    });
  }

  Future<void> _disconnect() async {
    final wasLocal = _activeSettings?.isLocal == true;
    if (wasLocal) await _supervisor.stop();
    await _store.clear();
    if (!mounted) return;
    setState(() {
      _activeSettings = null;
      _legacySettings = null;
      _requiresConnectionModeSelection = false;
      _editingLocalServer = false;
      _editingConnection = wasLocal;
      _useRemoteSetup = wasLocal;
      _settingsFuture = Future<ServerSettings?>.value();
    });
  }
}

class _LegacyConnectionModeScreen extends StatelessWidget {
  const _LegacyConnectionModeScreen({
    required this.previousServer,
    required this.onUseLocal,
    required this.onKeepRemote,
  });

  final String previousServer;
  final Future<void> Function() onUseLocal;
  final Future<void> Function() onKeepRemote;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        alignment: Alignment.center,
                        child: const Icon(LucideIcons.serverCog, size: 28),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        '选择 Windows 运行方式',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '新版 Windows 安装包已经包含 LocalLens 服务端。旧版本只保存了服务器地址，无法判断你希望使用本机一体化模式，还是继续连接原来的远程服务器。',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 18),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            const Icon(LucideIcons.link, size: 19),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                '旧服务器：$previousServer',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        onPressed: onUseLocal,
                        icon: const Icon(LucideIcons.monitorCog, size: 18),
                        label: const Text('使用本机内置服务器'),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: onKeepRemote,
                        icon: const Icon(LucideIcons.network, size: 18),
                        label: const Text('继续连接原来的服务器'),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        '选择本机模式后会进入媒体目录设置向导；不会删除原服务器上的任何数据。',
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
}

class _StartupScreen extends StatelessWidget {
  const _StartupScreen({required this.supervisor});

  final LocalServerSupervisor supervisor;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: StreamBuilder(
          stream: supervisor.states,
          initialData: supervisor.state,
          builder: (context, snapshot) {
            final state = snapshot.data!;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox.square(
                  dimension: 36,
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
                const SizedBox(height: 18),
                Text(
                  state.status.name == 'starting'
                      ? '正在启动本机 LocalLens 服务器…'
                      : '正在准备 LocalLens…',
                ),
                if (state.lastError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    state.lastError!,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _StartupErrorScreen extends StatelessWidget {
  const _StartupErrorScreen({
    required this.error,
    required this.supervisor,
    required this.onRetry,
    required this.onResetLocal,
    required this.onUseRemote,
  });

  final Object error;
  final LocalServerSupervisor supervisor;
  final VoidCallback onRetry;
  final Future<void> Function() onResetLocal;
  final VoidCallback onUseRemote;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  LucideIcons.serverCrash,
                  size: 44,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text(
                  '本机服务器启动失败',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 10),
                Text('$error', textAlign: TextAlign.center),
                const SizedBox(height: 10),
                Text(
                  '若你曾手动删除 LocalLens 数据目录，可以重新初始化本机服务器。该操作不会删除媒体目录中的原始图片和视频。',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 22),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  alignment: WrapAlignment.center,
                  children: [
                    FilledButton.icon(
                      onPressed: onRetry,
                      icon: const Icon(LucideIcons.refreshCw, size: 18),
                      label: const Text('重试启动'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _confirmReset(context),
                      icon: const Icon(LucideIcons.rotateCcw, size: 18),
                      label: const Text('清除本机配置并重新设置'),
                    ),
                    OutlinedButton.icon(
                      onPressed: supervisor.openLogDirectory,
                      icon: const Icon(LucideIcons.fileText, size: 18),
                      label: const Text('打开日志目录'),
                    ),
                    TextButton.icon(
                      onPressed: onUseRemote,
                      icon: const Icon(LucideIcons.link, size: 18),
                      label: const Text('连接远程服务器'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmReset(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重新初始化本机服务器？'),
        content: const Text(
          '将清除本机服务配置、SQLite 索引、缩略图、缓存和日志，然后返回首次设置页面。媒体目录中的原始图片和视频不会被删除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认重新初始化'),
          ),
        ],
      ),
    );
    if (confirmed == true) await onResetLocal();
  }
}
