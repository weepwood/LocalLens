class LocalLibraryConfig {
  const LocalLibraryConfig({
    required this.id,
    required this.name,
    required this.path,
    this.recursive = true,
    this.enabled = true,
  });

  factory LocalLibraryConfig.fromJson(Map<String, dynamic> json) {
    return LocalLibraryConfig(
      id: json['id'] as String? ?? 'main',
      name: json['name'] as String? ?? '媒体库',
      path: json['path'] as String? ?? '',
      recursive: json['recursive'] as bool? ?? true,
      enabled: json['enabled'] as bool? ?? true,
    );
  }

  final String id;
  final String name;
  final String path;
  final bool recursive;
  final bool enabled;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'path': path,
        'recursive': recursive,
        'enabled': enabled,
      };

  LocalLibraryConfig copyWith({
    String? id,
    String? name,
    String? path,
    bool? recursive,
    bool? enabled,
  }) {
    return LocalLibraryConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      path: path ?? this.path,
      recursive: recursive ?? this.recursive,
      enabled: enabled ?? this.enabled,
    );
  }
}

class LocalServerConfig {
  const LocalServerConfig({
    required this.listenAddress,
    required this.publicUrl,
    required this.serverName,
    required this.dataDir,
    required this.apiToken,
    required this.ffmpegPath,
    required this.ffprobePath,
    required this.autoScan,
    required this.watchFiles,
    required this.thumbnailWorkers,
    required this.metadataWorkers,
    required this.transcodeWorkers,
    required this.transcodeCacheGB,
    required this.transcodeHardware,
    required this.pairingTTLMinutes,
    required this.libraries,
  });

  factory LocalServerConfig.fromJson(Map<String, dynamic> json) {
    final libraries = (json['libraries'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .map(LocalLibraryConfig.fromJson)
        .toList(growable: false);
    return LocalServerConfig(
      listenAddress: json['listen_address'] as String? ?? '127.0.0.1:9527',
      publicUrl: json['public_url'] as String? ?? '',
      serverName: json['server_name'] as String? ?? 'LocalLens',
      dataDir: json['data_dir'] as String? ?? '',
      apiToken: json['api_token'] as String? ?? '',
      ffmpegPath: json['ffmpeg_path'] as String? ?? '',
      ffprobePath: json['ffprobe_path'] as String? ?? '',
      autoScan: json['auto_scan'] as bool? ?? true,
      watchFiles: json['watch_files'] as bool? ?? true,
      thumbnailWorkers: (json['thumbnail_workers'] as num? ?? 2).toInt(),
      metadataWorkers: (json['metadata_workers'] as num? ?? 2).toInt(),
      transcodeWorkers: (json['transcode_workers'] as num? ?? 1).toInt(),
      transcodeCacheGB: (json['transcode_cache_gb'] as num? ?? 20).toInt(),
      transcodeHardware: json['transcode_hardware'] as String? ?? 'software',
      pairingTTLMinutes: (json['pairing_ttl_minutes'] as num? ?? 5).toInt(),
      libraries: libraries,
    );
  }

  final String listenAddress;
  final String publicUrl;
  final String serverName;
  final String dataDir;
  final String apiToken;
  final String ffmpegPath;
  final String ffprobePath;
  final bool autoScan;
  final bool watchFiles;
  final int thumbnailWorkers;
  final int metadataWorkers;
  final int transcodeWorkers;
  final int transcodeCacheGB;
  final String transcodeHardware;
  final int pairingTTLMinutes;
  final List<LocalLibraryConfig> libraries;

  int get port {
    final index = listenAddress.lastIndexOf(':');
    return int.tryParse(index < 0 ? '' : listenAddress.substring(index + 1)) ?? 9527;
  }

  bool get allowLan => listenAddress.startsWith('0.0.0.0:');

  String get localBaseUrl => 'http://127.0.0.1:$port';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'listen_address': listenAddress,
        'public_url': publicUrl,
        'server_name': serverName,
        'data_dir': dataDir,
        'api_token': apiToken,
        'ffmpeg_path': ffmpegPath,
        'ffprobe_path': ffprobePath,
        'auto_scan': autoScan,
        'watch_files': watchFiles,
        'thumbnail_workers': thumbnailWorkers,
        'metadata_workers': metadataWorkers,
        'transcode_workers': transcodeWorkers,
        'transcode_cache_gb': transcodeCacheGB,
        'transcode_hardware': transcodeHardware,
        'pairing_ttl_minutes': pairingTTLMinutes,
        'libraries': libraries.map((item) => item.toJson()).toList(),
      };

  LocalServerConfig copyWith({
    String? listenAddress,
    String? publicUrl,
    String? serverName,
    String? dataDir,
    String? apiToken,
    String? ffmpegPath,
    String? ffprobePath,
    bool? autoScan,
    bool? watchFiles,
    int? thumbnailWorkers,
    int? metadataWorkers,
    int? transcodeWorkers,
    int? transcodeCacheGB,
    String? transcodeHardware,
    int? pairingTTLMinutes,
    List<LocalLibraryConfig>? libraries,
  }) {
    return LocalServerConfig(
      listenAddress: listenAddress ?? this.listenAddress,
      publicUrl: publicUrl ?? this.publicUrl,
      serverName: serverName ?? this.serverName,
      dataDir: dataDir ?? this.dataDir,
      apiToken: apiToken ?? this.apiToken,
      ffmpegPath: ffmpegPath ?? this.ffmpegPath,
      ffprobePath: ffprobePath ?? this.ffprobePath,
      autoScan: autoScan ?? this.autoScan,
      watchFiles: watchFiles ?? this.watchFiles,
      thumbnailWorkers: thumbnailWorkers ?? this.thumbnailWorkers,
      metadataWorkers: metadataWorkers ?? this.metadataWorkers,
      transcodeWorkers: transcodeWorkers ?? this.transcodeWorkers,
      transcodeCacheGB: transcodeCacheGB ?? this.transcodeCacheGB,
      transcodeHardware: transcodeHardware ?? this.transcodeHardware,
      pairingTTLMinutes: pairingTTLMinutes ?? this.pairingTTLMinutes,
      libraries: libraries ?? this.libraries,
    );
  }
}
