import 'package:flutter_test/flutter_test.dart';
import 'package:local_lens/models/local_server_config.dart';

void main() {
  test('local server config round-trips and derives local URL', () {
    const config = LocalServerConfig(
      listenAddress: '0.0.0.0:9527',
      publicUrl: 'http://192.168.1.20:9527',
      serverName: 'LocalLens Home',
      dataDir: r'C:\Users\tester\AppData\Local\LocalLens\data',
      apiToken: '1234567890abcdef1234567890abcdef',
      ffmpegPath: r'C:\Program Files\LocalLens\runtime\media-tools\ffmpeg.exe',
      ffprobePath: r'C:\Program Files\LocalLens\runtime\media-tools\ffprobe.exe',
      autoScan: true,
      watchFiles: true,
      thumbnailWorkers: 2,
      metadataWorkers: 2,
      transcodeWorkers: 1,
      transcodeCacheGB: 20,
      transcodeHardware: 'software',
      pairingTTLMinutes: 5,
      libraries: [
        LocalLibraryConfig(
          id: 'main',
          name: '媒体库',
          path: r'D:\Media',
        ),
      ],
    );

    final restored = LocalServerConfig.fromJson(config.toJson());
    expect(restored.serverName, 'LocalLens Home');
    expect(restored.port, 9527);
    expect(restored.allowLan, isTrue);
    expect(restored.localBaseUrl, 'http://127.0.0.1:9527');
    expect(restored.libraries.single.path, r'D:\Media');
  });

  test('copyWith preserves token while updating runtime settings', () {
    const config = LocalServerConfig(
      listenAddress: '127.0.0.1:9527',
      publicUrl: '',
      serverName: 'LocalLens',
      dataDir: 'data',
      apiToken: '1234567890abcdef',
      ffmpegPath: '',
      ffprobePath: '',
      autoScan: true,
      watchFiles: true,
      thumbnailWorkers: 2,
      metadataWorkers: 2,
      transcodeWorkers: 1,
      transcodeCacheGB: 20,
      transcodeHardware: 'software',
      pairingTTLMinutes: 5,
      libraries: [
        LocalLibraryConfig(id: 'main', name: 'Main', path: r'D:\Media'),
      ],
    );

    final changed = config.copyWith(
      listenAddress: '0.0.0.0:9800',
      transcodeWorkers: 2,
      transcodeHardware: 'qsv',
    );
    expect(changed.apiToken, config.apiToken);
    expect(changed.port, 9800);
    expect(changed.transcodeWorkers, 2);
    expect(changed.transcodeHardware, 'qsv');
  });
}
