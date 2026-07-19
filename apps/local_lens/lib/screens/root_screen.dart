import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../models/server_runtime_state.dart';
import '../models/server_settings.dart';
import '../services/embedded_server_supervisor.dart';
import '../services/settings_store.dart';
import 'library_screen.dart';
import 'setup_screen.dart';

class RootScreen extends StatefulWidget {
  const RootScreen({super.key});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  final SettingsStore _store = SettingsStore();
  final EmbeddedServerSupervisor _supervisor =
      EmbeddedServerSupervisor.instance;
  late Future<ServerSettings?> _settingsFuture;
  StreamSubscription<ServerRuntimeState>? _runtimeSubscription;
  ServerRuntimeState _runtime = Platform.isWindows
      ? const ServerRuntimeState(status: ServerRuntimeStatus.starting)
      : const ServerRuntimeState.unsupported();
  bool _editingConnection = false;
  Object? _bootstrapError;

  @override
  void initState() {
    super.initState();
    _runtimeSubscription = _supervisor.states.listen((state) {
      if (mounted) setState(() => _runtime = state);
    });
    _settingsFuture = _initialize();
  }

  Future<ServerSettings?> _initialize() async {
    final existing = await _store.load();
    if (!Platform.isWindows || existing != null) return existing;
    try {
      final bootstrap = await _supervisor.ensureBootstrap();
      await _store.save(bootstrap.settings);
      unawaited(_supervisor.start(configPath: bootstrap.configPath));
      return bootstrap.settings;
    } catch (error) {
      _bootstrapError = error;
      return null;
    }
  }

  @override
  void dispose() {
    unawaited(_runtimeSubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ServerSettings?>(
      future: _settingsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final settings = snapshot.data;
        if (_bootstrapError != null && settings == null) {
          return _BootstrapErrorScreen(
            error: _bootstrapError!,
            onRetry: () {
              setState(() {
                _bootstrapError = null;
                _settingsFuture = _initialize();
              });
            },
            onRemote: () => setState(() => _editingConnection = true),
          );
        }
        if (settings == null || _editingConnection) {
          return SetupScreen(
            initialSettings: settings,
            onSaved: _saveSettings,
            onCancel: settings == null ? null : _cancelEditing,
          );
        }
        return LibraryScreen(
          settings: settings,
          onEditConnection: _editConnection,
          onDisconnect: _disconnect,
          embeddedServerSupervisor: Platform.isWindows ? _supervisor : null,
          embeddedRuntimeState: _runtime,
        );
      },
    );
  }

  Future<void> _saveSettings(ServerSettings settings) async {
    await _store.save(settings);
    if (!mounted) return;
    setState(() {
      _editingConnection = false;
      _settingsFuture = Future.value(settings);
    });
  }

  void _editConnection() {
    setState(() => _editingConnection = true);
  }

  void _cancelEditing() {
    setState(() => _editingConnection = false);
  }

  Future<void> _disconnect() async {
    await _store.clear();
    if (!mounted) return;
    setState(() {
      _editingConnection = false;
      _settingsFuture = Future<ServerSettings?>.value();
    });
  }
}

class _BootstrapErrorScreen extends StatelessWidget {
  const _BootstrapErrorScreen({
    required this.error,
    required this.onRetry,
    required this.onRemote,
  });

  final Object error;
  final VoidCallback onRetry;
  final VoidCallback onRemote;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('无法启动本机 LocalLens 服务',
                      style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 12),
                  Text('$error'),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      FilledButton.icon(
                        onPressed: onRetry,
                        icon: const Icon(Icons.refresh),
                        label: const Text('重新尝试'),
                      ),
                      OutlinedButton.icon(
                        onPressed: onRemote,
                        icon: const Icon(Icons.lan_outlined),
                        label: const Text('连接远程服务器'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
