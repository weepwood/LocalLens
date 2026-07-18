import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/media_item.dart';
import '../models/server_settings.dart';
import '../models/server_state.dart';

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
  ApiClient(this.settings) {
    _client.connectionTimeout = const Duration(seconds: 8);
    _client.idleTimeout = const Duration(seconds: 30);
    _client.userAgent = 'LocalLens Flutter Client';
  }

  static const _requestTimeout = Duration(seconds: 20);

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
    final json = await _requestJson(
      'GET',
      '/api/v1/server',
      authenticated: false,
    );
    if (json['apiVersion'] != 'v1') {
      throw const ApiException('服务器 API 版本不受支持');
    }
    await listMedia(limit: 1);
  }

  Future<List<LibraryInfo>> listLibraries() async {
    final json = await _requestJson('GET', '/api/v1/libraries');
    final rawItems = json['items'] as List<dynamic>? ?? const [];
    return rawItems
        .map((item) => LibraryInfo.fromJson(item as Map<String, dynamic>))
        .toList(growable: false);
  }

  Future<ScanStatus> getScanStatus() async {
    final json = await _requestJson('GET', '/api/v1/scan');
    return ScanStatus.fromJson(json);
  }

  Future<ScanStatus> startScan() async {
    final json = await _requestJson('POST', '/api/v1/scan');
    return ScanStatus.fromJson(json);
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
    final json = await _requestJson('GET', uri.toString());
    return MediaPage.fromJson(json);
  }

  Future<Map<String, dynamic>> _requestJson(
    String method,
    String url, {
    bool authenticated = true,
  }) async {
    try {
      final request = await _client
          .openUrl(method, resolve(url))
          .timeout(_requestTimeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (authenticated) {
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer ${settings.token}',
        );
      }

      final response = await request.close().timeout(_requestTimeout);
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(_requestTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ApiException(
          body.trim().isEmpty ? '请求失败' : body.trim(),
          statusCode: response.statusCode,
        );
      }
      if (body.trim().isEmpty) return <String, dynamic>{};
      return jsonDecode(body) as Map<String, dynamic>;
    } on SocketException catch (error) {
      throw ApiException('无法连接服务器：${error.message}');
    } on HandshakeException {
      throw const ApiException('TLS 握手失败，请检查服务器证书和地址');
    } on HttpException catch (error) {
      throw ApiException('HTTP 请求失败：${error.message}');
    } on TimeoutException {
      throw const ApiException('请求超时，请检查局域网连接和服务器状态');
    } on FormatException {
      throw const ApiException('服务器返回了无法解析的数据');
    }
  }

  void close() => _client.close(force: true);
}
