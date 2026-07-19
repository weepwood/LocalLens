class PlaybackSubtitle {
  const PlaybackSubtitle({
    required this.id,
    required this.name,
    required this.language,
    required this.format,
    required this.url,
  });

  factory PlaybackSubtitle.fromJson(Map<String, dynamic> json) {
    return PlaybackSubtitle(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      language: json['language'] as String? ?? 'und',
      format: json['format'] as String? ?? '',
      url: json['url'] as String? ?? '',
    );
  }

  final String id;
  final String name;
  final String language;
  final String format;
  final String url;
}

class PlaybackManifest {
  const PlaybackManifest({
    required this.mode,
    required this.status,
    required this.url,
    required this.mimeType,
    required this.profile,
    required this.codec,
    required this.width,
    required this.height,
    required this.progress,
    required this.retryAfter,
    required this.error,
    required this.subtitles,
  });

  factory PlaybackManifest.fromJson(Map<String, dynamic> json) {
    return PlaybackManifest(
      mode: json['mode'] as String? ?? 'direct',
      status: json['status'] as String? ?? 'failed',
      url: json['url'] as String? ?? '',
      mimeType: json['mimeType'] as String? ?? '',
      profile: json['profile'] as String? ?? '',
      codec: json['codec'] as String? ?? '',
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
      progress: (json['progress'] as num?)?.toDouble() ?? 0,
      retryAfter: (json['retryAfter'] as num?)?.toInt() ?? 2,
      error: json['error'] as String? ?? '',
      subtitles: (json['subtitles'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(PlaybackSubtitle.fromJson)
          .toList(growable: false),
    );
  }

  final String mode;
  final String status;
  final String url;
  final String mimeType;
  final String profile;
  final String codec;
  final int width;
  final int height;
  final double progress;
  final int retryAfter;
  final String error;
  final List<PlaybackSubtitle> subtitles;

  bool get ready => status == 'ready' && url.isNotEmpty;
  bool get preparing => status == 'preparing';
  bool get failed => status == 'failed';
  bool get transcoded => mode == 'transcode';

  String get qualityLabel {
    if (!transcoded) return '原始画质';
    if (height > 0) return '${height}p';
    return profile.isEmpty ? '兼容模式' : profile;
  }
}
