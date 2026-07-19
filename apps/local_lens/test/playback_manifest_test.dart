import 'package:flutter_test/flutter_test.dart';
import 'package:local_lens/models/playback_manifest.dart';

void main() {
  test('parses preparing HLS manifest and external subtitles', () {
    final manifest = PlaybackManifest.fromJson(<String, dynamic>{
      'mode': 'transcode',
      'status': 'preparing',
      'profile': 'h264-720p',
      'codec': 'h264',
      'width': 1920,
      'height': 720,
      'progress': 0.42,
      'retryAfter': 2,
      'subtitles': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'movie.zh-CN.srt',
          'name': 'movie.zh-CN.srt',
          'language': 'zh-CN',
          'format': 'srt',
          'url': '/api/v1/media/media-1/subtitle/movie.zh-CN.srt',
        },
      ],
    });

    expect(manifest.preparing, isTrue);
    expect(manifest.transcoded, isTrue);
    expect(manifest.qualityLabel, '720p');
    expect(manifest.progress, closeTo(0.42, 0.001));
    expect(manifest.subtitles.single.language, 'zh-CN');
  });

  test('parses direct playback manifest', () {
    final manifest = PlaybackManifest.fromJson(<String, dynamic>{
      'mode': 'direct',
      'status': 'ready',
      'url': '/api/v1/media/media-1/stream',
      'mimeType': 'video/mp4',
      'codec': 'h264',
      'width': 1920,
      'height': 1080,
    });

    expect(manifest.ready, isTrue);
    expect(manifest.transcoded, isFalse);
    expect(manifest.qualityLabel, '原始画质');
  });
}
