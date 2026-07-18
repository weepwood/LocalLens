class MediaItem {
  const MediaItem({
    required this.id,
    required this.libraryId,
    required this.relativePath,
    required this.folderPath,
    required this.fileName,
    required this.type,
    required this.mimeType,
    required this.sizeBytes,
    required this.modifiedAt,
    required this.capturedAt,
    required this.capturedAtSource,
    required this.width,
    required this.height,
    required this.durationMs,
    required this.codec,
    required this.metadataStatus,
    required this.favorite,
    required this.rating,
    required this.thumbnailUrl,
    required this.originalUrl,
    required this.streamUrl,
    this.latitude,
    this.longitude,
    this.cameraModel = '',
    this.metadataError = '',
  });

  factory MediaItem.fromJson(Map<String, dynamic> json) {
    final modifiedAt = DateTime.parse(json['modifiedAt'] as String).toLocal();
    return MediaItem(
      id: json['id'] as String,
      libraryId: json['libraryId'] as String? ?? '',
      relativePath: json['relativePath'] as String? ?? '',
      folderPath: json['folderPath'] as String? ?? '',
      fileName: json['fileName'] as String,
      type: json['type'] as String,
      mimeType: json['mimeType'] as String? ?? 'application/octet-stream',
      sizeBytes: (json['sizeBytes'] as num).toInt(),
      modifiedAt: modifiedAt,
      capturedAt: DateTime.tryParse(json['capturedAt'] as String? ?? '')
              ?.toLocal() ??
          modifiedAt,
      capturedAtSource: json['capturedAtSource'] as String? ?? 'modified',
      width: (json['width'] as num? ?? 0).toInt(),
      height: (json['height'] as num? ?? 0).toInt(),
      durationMs: (json['durationMs'] as num? ?? 0).toInt(),
      codec: json['codec'] as String? ?? '',
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      cameraModel: json['cameraModel'] as String? ?? '',
      metadataStatus: json['metadataStatus'] as String? ?? 'pending',
      metadataError: json['metadataError'] as String? ?? '',
      favorite: json['favorite'] as bool? ?? false,
      rating: (json['rating'] as num? ?? 0).toInt(),
      thumbnailUrl: json['thumbnailUrl'] as String,
      originalUrl: json['originalUrl'] as String,
      streamUrl: json['streamUrl'] as String,
    );
  }

  final String id;
  final String libraryId;
  final String relativePath;
  final String folderPath;
  final String fileName;
  final String type;
  final String mimeType;
  final int sizeBytes;
  final DateTime modifiedAt;
  final DateTime capturedAt;
  final String capturedAtSource;
  final int width;
  final int height;
  final int durationMs;
  final String codec;
  final double? latitude;
  final double? longitude;
  final String cameraModel;
  final String metadataStatus;
  final String metadataError;
  final bool favorite;
  final int rating;
  final String thumbnailUrl;
  final String originalUrl;
  final String streamUrl;

  bool get isVideo => type == 'video';
  bool get hasLocation => latitude != null && longitude != null;
  double? get aspectRatio => width > 0 && height > 0 ? width / height : null;

  MediaItem copyWith({bool? favorite, int? rating}) {
    return MediaItem(
      id: id,
      libraryId: libraryId,
      relativePath: relativePath,
      folderPath: folderPath,
      fileName: fileName,
      type: type,
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      modifiedAt: modifiedAt,
      capturedAt: capturedAt,
      capturedAtSource: capturedAtSource,
      width: width,
      height: height,
      durationMs: durationMs,
      codec: codec,
      latitude: latitude,
      longitude: longitude,
      cameraModel: cameraModel,
      metadataStatus: metadataStatus,
      metadataError: metadataError,
      favorite: favorite ?? this.favorite,
      rating: rating ?? this.rating,
      thumbnailUrl: thumbnailUrl,
      originalUrl: originalUrl,
      streamUrl: streamUrl,
    );
  }
}

class MediaPage {
  const MediaPage({
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
    required this.hasMore,
    this.nextCursor,
  });

  factory MediaPage.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'] as List<dynamic>? ?? const [];
    final nextCursor = json['nextCursor'] as String?;
    return MediaPage(
      items: rawItems
          .map((item) => MediaItem.fromJson(item as Map<String, dynamic>))
          .toList(growable: false),
      total: (json['total'] as num? ?? 0).toInt(),
      limit: (json['limit'] as num? ?? 100).toInt(),
      offset: (json['offset'] as num? ?? 0).toInt(),
      nextCursor:
          nextCursor == null || nextCursor.isEmpty ? null : nextCursor,
      hasMore: json['hasMore'] as bool? ?? false,
    );
  }

  final List<MediaItem> items;
  final int total;
  final int limit;
  final int offset;
  final String? nextCursor;
  final bool hasMore;
}
