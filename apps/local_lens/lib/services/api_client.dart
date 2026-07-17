import 'dart:convert';
import 'dart:io';

import '../models/media_item.dart';
import '../models/server_settings.dart';

class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => statusCode == null
      ? message
      : 'HTTP $statusCode: $message';
}

class ApiClient {
  ApiClient(this.settings);

  final ServerSettings settings;
  final HttpClient _client = HttpClient();

  Map<String, String> get authorizationHeaders => <String, String>{
        HttpHeaders.authorizationHeader: 'Bearer ${settings.token}',
      };

  Uri resolve(String path) {
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return Uri.parse(path);
    }
    return Uri.parse('${settings.normalizedBaseUrl}$path');
  }

  Future<void> verify() async {
    final json = await _getJson('/api/v1/server', authenticated: false);
    if (json['apiVersion'] != 'v1') {
      throw const ApiException('服务器 API 版本不受支持');
    }
    await listMedia(limit: 1);
  }

  Future<MediaPage> listMedia({
    String? type,
    String? search,
    int limit = 100,
    int offset = 0,
  }) async {
    final query = <String, String>{
      'limit': '$limit',
      'offset': '$offset',
      if (type != null && type.isNotEmpty) 'type': type,
      if (search != null && search.trim().isNotEmpty) 'q': search.trim(),
    };
    final uri = Uri.parse('${settings.normalizedBaseUrl}/api/v1/media')
        .replace(queryParameters: query);
    final json = await _getJson(uri.toString());
    return MediaPage.fromJson(json);
  }

  Future<Map<String, dynamic>> _getJson(
    String url, {
    bool authenticated = true,
  }) async {
    final request = await _client.getUrl(resolve(url));
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (authenticated) {
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${settings.token}',
      );
    }
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        body.trim().isEmpty ? '请求失败' : body.trim(),
        statusCode: response.statusCode,
      );
    }
    return jsonDecode(body) as Map<String, dynamic>;
  }

  void close() => _client.close(force: true);
}
