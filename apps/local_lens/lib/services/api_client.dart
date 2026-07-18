import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/collections.dart';
import '../models/media_item.dart';
import '../models/server_settings.dart';
import '../models/server_state.dart';

class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() =>
      statusCode == null ? message : 'HTTP $statusCode: $message';
}

class ApiClient {
  ApiClient(this.settings) {
    _client.connectionTimeout = const Duration(seconds: 8);
    _client.idleTimeout = const Duration(seconds: 30);
    _client.userAgent = 'LocalLens Flutter Client/0.3';
  }

  static const _requestTimeout = Duration(seconds: 25);

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

  Future<MediaStats> getStats() async {
    final json = await _requestJson('GET', '/api/v1/stats');
    return MediaStats.fromJson(json);
  }

  Future<ScanStatus> getScanStatus() async {
    final json = await _requestJson('GET', '/api/v1/scan');
    return ScanStatus.fromJson(json);
  }

  Future<ScanStatus> startScan() async {
    final json = await _requestJson('POST', '/api/v1/scan');
    return ScanStatus.fromJson(json);
  }

  Future<List<FolderInfo>> listFolders({
    required String libraryId,
    String parent = '',
  }) async {
    final uri = resolve('/api/v1/folders').replace(queryParameters: <String, String>{
      'libraryId': libraryId,
      'parent': parent,
    });
    final json = await _requestJson('GET', uri.toString());
    return (json['items'] as List<dynamic>? ?? const [])
        .map((item) => FolderInfo.fromJson(item as Map<String, dynamic>))
        .toList(growable: false);
  }

  Future<MediaPage> listMedia({
    String? type,
    String? search,
    String? libraryId,
    String? folder,
    bool recursive = false,
    bool favorite = false,
    String? albumId,
    String? tagId,
    int minRating = 0,
    String sort = 'timeline',
    int limit = 100,
    int offset = 0,
    String? cursor,
  }) async {
    final query = <String, String>{
      'limit': '$limit',
      'sort': sort,
      if (cursor == null || cursor.isEmpty) 'offset': '$offset',
      if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
      if (type != null && type.isNotEmpty) 'type': type,
      if (search != null && search.trim().isNotEmpty) 'q': search.trim(),
      if (libraryId != null && libraryId.isNotEmpty) 'libraryId': libraryId,
      if (folder != null) 'folder': folder,
      if (recursive) 'recursive': 'true',
      if (favorite) 'favorite': 'true',
      if (albumId != null && albumId.isNotEmpty) 'albumId': albumId,
      if (tagId != null && tagId.isNotEmpty) 'tagId': tagId,
      if (minRating > 0) 'minRating': '$minRating',
    };
    final uri = resolve('/api/v1/media').replace(queryParameters: query);
    final json = await _requestJson('GET', uri.toString());
    return MediaPage.fromJson(json);
  }

  Future<MediaItem> setFavorite(String mediaId, bool favorite) async {
    final json = await _requestJson(
      favorite ? 'PUT' : 'DELETE',
      '/api/v1/media/$mediaId/favorite',
    );
    return MediaItem.fromJson(json);
  }

  Future<MediaItem> setRating(String mediaId, int rating) async {
    final json = await _requestJson(
      rating == 0 ? 'DELETE' : 'PUT',
      '/api/v1/media/$mediaId/rating',
      body: rating == 0 ? null : <String, dynamic>{'rating': rating},
    );
    return MediaItem.fromJson(json);
  }

  Future<void> retryMetadata(String mediaId) async {
    await _requestJson('POST', '/api/v1/media/$mediaId/metadata');
  }

  Future<MediaCollectionState> getMediaCollections(String mediaId) async {
    final json =
        await _requestJson('GET', '/api/v1/media/$mediaId/collections');
    return MediaCollectionState.fromJson(json);
  }

  Future<PlaybackProgress> getPlaybackProgress(String mediaId) async {
    final json = await _requestJson('GET', '/api/v1/media/$mediaId/progress');
    return PlaybackProgress.fromJson(json);
  }

  Future<void> savePlaybackProgress(
    String mediaId, {
    required int positionMs,
    required int durationMs,
    required bool completed,
  }) async {
    await _requestJson(
      'PUT',
      '/api/v1/media/$mediaId/progress',
      body: <String, dynamic>{
        'positionMs': positionMs,
        'durationMs': durationMs,
        'completed': completed,
      },
    );
  }

  Future<List<AlbumInfo>> listAlbums() async {
    final json = await _requestJson('GET', '/api/v1/albums');
    return (json['items'] as List<dynamic>? ?? const [])
        .map((item) => AlbumInfo.fromJson(item as Map<String, dynamic>))
        .toList(growable: false);
  }

  Future<AlbumInfo> createAlbum(String name, {String description = ''}) async {
    final json = await _requestJson(
      'POST',
      '/api/v1/albums',
      body: <String, dynamic>{'name': name, 'description': description},
    );
    return AlbumInfo.fromJson(json);
  }

  Future<void> deleteAlbum(String id) =>
      _requestEmpty('DELETE', '/api/v1/albums/$id');

  Future<void> setAlbumItem(String albumId, String mediaId, bool selected) =>
      _requestEmpty(
        selected ? 'PUT' : 'DELETE',
        '/api/v1/albums/$albumId/items/$mediaId',
      );

  Future<List<TagInfo>> listTags() async {
    final json = await _requestJson('GET', '/api/v1/tags');
    return (json['items'] as List<dynamic>? ?? const [])
        .map((item) => TagInfo.fromJson(item as Map<String, dynamic>))
        .toList(growable: false);
  }

  Future<TagInfo> createTag(String name, {String color = ''}) async {
    final json = await _requestJson(
      'POST',
      '/api/v1/tags',
      body: <String, dynamic>{'name': name, 'color': color},
    );
    return TagInfo.fromJson(json);
  }

  Future<void> deleteTag(String id) =>
      _requestEmpty('DELETE', '/api/v1/tags/$id');

  Future<void> setMediaTag(String mediaId, String tagId, bool selected) =>
      _requestEmpty(
        selected ? 'PUT' : 'DELETE',
        '/api/v1/media/$mediaId/tags/$tagId',
      );

  Future<PairingSessionInfo> createPairingSession() async {
    final json = await _requestJson('POST', '/api/v1/pairing/session');
    return PairingSessionInfo.fromJson(json);
  }

  Future<List<DeviceInfo>> listDevices() async {
    final json = await _requestJson('GET', '/api/v1/devices');
    return (json['items'] as List<dynamic>? ?? const [])
        .map((item) => DeviceInfo.fromJson(item as Map<String, dynamic>))
        .toList(growable: false);
  }

  Future<void> revokeDevice(String id) =>
      _requestEmpty('DELETE', '/api/v1/devices/$id');

  static Future<ServerSettings> claimPairing(
    PairingPayload payload, {
    required String deviceName,
    required String platform,
  }) async {
    final temporary = ApiClient(ServerSettings(baseUrl: payload.baseUrl, token: ''));
    try {
      final json = await temporary._requestJson(
        'POST',
        '/api/v1/pairing/claim',
        authenticated: false,
        body: <String, dynamic>{
          'pairingId': payload.pairingId,
          'secret': payload.secret,
          'deviceName': deviceName,
          'platform': platform,
        },
      );
      return ServerSettings(
        baseUrl: payload.baseUrl,
        token: json['token'] as String,
      );
    } finally {
      temporary.close();
    }
  }

  Future<void> _requestEmpty(String method, String url) async {
    await _requestJson(method, url);
  }

  Future<Map<String, dynamic>> _requestJson(
    String method,
    String url, {
    bool authenticated = true,
    Map<String, dynamic>? body,
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
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }

      final response = await request.close().timeout(_requestTimeout);
      final responseBody = await response
          .transform(utf8.decoder)
          .join()
          .timeout(_requestTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ApiException(
          responseBody.trim().isEmpty ? '请求失败' : responseBody.trim(),
          statusCode: response.statusCode,
        );
      }
      if (responseBody.trim().isEmpty) return <String, dynamic>{};
      return jsonDecode(responseBody) as Map<String, dynamic>;
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
