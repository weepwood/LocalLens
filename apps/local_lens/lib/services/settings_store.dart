import 'package:shared_preferences/shared_preferences.dart';

import '../models/server_settings.dart';

class SettingsStore {
  static const _baseUrlKey = 'server.baseUrl';
  static const _tokenKey = 'server.token';
  static const _modeKey = 'server.mode';

  final SharedPreferencesAsync _preferences = SharedPreferencesAsync();

  Future<ServerSettings?> load() async {
    final baseUrl = await _preferences.getString(_baseUrlKey);
    final token = await _preferences.getString(_tokenKey);
    if (baseUrl == null || token == null || baseUrl.isEmpty || token.isEmpty) {
      return null;
    }
    final storedMode = await _preferences.getString(_modeKey);
    final mode = storedMode == ServerConnectionMode.local.name
        ? ServerConnectionMode.local
        : ServerConnectionMode.remote;
    return ServerSettings(baseUrl: baseUrl, token: token, mode: mode);
  }

  Future<bool> hasExplicitMode() async {
    final storedMode = await _preferences.getString(_modeKey);
    return storedMode == ServerConnectionMode.local.name ||
        storedMode == ServerConnectionMode.remote.name;
  }

  Future<void> save(ServerSettings settings) async {
    await _preferences.setString(_baseUrlKey, settings.normalizedBaseUrl);
    await _preferences.setString(_tokenKey, settings.token);
    await _preferences.setString(_modeKey, settings.mode.name);
  }

  Future<void> clear() async {
    await _preferences.remove(_baseUrlKey);
    await _preferences.remove(_tokenKey);
    await _preferences.remove(_modeKey);
  }
}
