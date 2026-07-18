import 'package:flutter/material.dart';

import '../models/server_settings.dart';
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
  late Future<ServerSettings?> _settingsFuture;
  bool _editingConnection = false;

  @override
  void initState() {
    super.initState();
    _settingsFuture = _store.load();
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
