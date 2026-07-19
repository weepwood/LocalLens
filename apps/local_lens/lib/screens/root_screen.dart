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
  ServerSettings? _activeSettings;

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

  Future<void> _disconnect() async {
    final wasLocal = _activeSettings?.isLocal == true;
    if (wasLocal) await _supervisor.stop();
    await _store.clear();
    if (!mounted) return;
    setState(() {
      _activeSettings = null;
      _editingLocalServer = false;
      _editingConnection = wasLocal;
      _useRemoteSetup = wasLocal;
      _settingsFuture = Future<ServerSettings?>.value();
    });
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
                  Text(state.lastError!, style: Theme.of(context).textTheme.bodySmall),
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
    required this.onUseRemote,
  });

  final Object error;
  final LocalServerSupervisor supervisor;
  final VoidCallback onRetry;
  final VoidCallback onUseRemote;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
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
                Text('本机服务器启动失败', style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 10),
                Text('$error', textAlign: TextAlign.center),
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
}
