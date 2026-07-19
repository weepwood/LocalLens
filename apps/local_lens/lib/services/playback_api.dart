import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/playback_manifest.dart';
import 'api_client.dart';

extension PlaybackApi on ApiClient {
  Future<PlaybackManifest> requestPlaybackManifest(
    String mediaId, {
    int? preferredHeight,
    bool forceTranscode = false,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..idleTimeout = const Duration(seconds: 15)
      ..userAgent = 'LocalLens Flutter Client/0.5';
    try {
      final request = await client
          .postUrl(resolve('/api/v1/media/$mediaId/playback-manifest'))
          .timeout(const Duration(seconds: 10));
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${settings.token}',
      );
      request.write(jsonEncode(_playbackCapabilities(
        preferredHeight: preferredHeight,
        forceTranscode: forceTranscode,
      )));

      final response = await request.close().timeout(const Duration(seconds: 30));
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.accepted) {
        throw ApiException(
          body.trim().isEmpty ? '无法准备视频播放' : body.trim(),
          statusCode: response.statusCode,
        );
      }
      if (body.trim().isEmpty) {
        throw const ApiException('服务器没有返回播放信息');
      }
      return PlaybackManifest.fromJson(
        jsonDecode(body) as Map<String, dynamic>,
      );
    } on SocketException catch (error) {
      throw ApiException('无法连接服务器：${error.message}');
    } on TimeoutException {
      throw const ApiException('准备视频超时，请检查服务器转码状态');
    } on FormatException {
      throw const ApiException('服务器返回了无法解析的播放信息');
    } finally {
      client.close(force: true);
    }
  }

  Map<String, dynamic> _playbackCapabilities({
    required int? preferredHeight,
    required bool forceTranscode,
  }) {
    final platform = Platform.isWindows
        ? 'windows'
        : Platform.isAndroid
            ? 'android'
            : Platform.operatingSystem;
    return <String, dynamic>{
      'platform': platform,
      'videoCodecs': Platform.isWindows
          ? const ['h264', 'hevc', 'vp9', 'av1', 'mpeg4']
          : const ['h264', 'hevc', 'vp9'],
      'containers': Platform.isWindows
          ? const ['mp4', 'mkv', 'webm', 'avi']
          : const ['mp4', 'mkv', 'webm'],
      'supportsHls': true,
      'maxWidth': Platform.isAndroid ? 3840 : 7680,
      'maxHeight': Platform.isAndroid ? 2160 : 4320,
      if (preferredHeight != null) 'preferredHeight': preferredHeight,
      'forceTranscode': forceTranscode,
    };
  }
}
