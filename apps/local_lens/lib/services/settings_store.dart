import 'package:shared_preferences/shared_preferences.dart';

import '../models/server_settings.dart';

class SettingsStore {
  static const _baseUrlKey = 'server.baseUrl';
  static const _tokenKey = 'server.token';

  final SharedPreferencesAsync _preferences = SharedPreferencesAsync();

  Future<ServerSettings?> load() async {
    final baseUrl = await _preferences.getString(_baseUrlKey);
    final token = await _preferences.getString(_tokenKey);
    if (baseUrl == null || token == null || baseUrl.isEmpty || token.isEmpty) {
      return null;
    }
    return ServerSettings(baseUrl: baseUrl, token: token);
  }

  Future<void> save(ServerSettings settings) async {
    await _preferences.setString(_baseUrlKey, settings.normalizedBaseUrl);
    await _preferences.setString(_tokenKey, settings.token);
  }

  Future<void> clear() async {
    await _preferences.remove(_baseUrlKey);
    await _preferences.remove(_tokenKey);
  }
}
