class MediaItem {
  const MediaItem({
    required this.id,
    required this.libraryId,
    required this.fileName,
    required this.type,
    required this.mimeType,
    required this.sizeBytes,
    required this.modifiedAt,
    required this.favorite,
    required this.thumbnailUrl,
    required this.originalUrl,
    required this.streamUrl,
  });

  factory MediaItem.fromJson(Map<String, dynamic> json) {
    return MediaItem(
      id: json['id'] as String,
      libraryId: json['libraryId'] as String? ?? '',
      fileName: json['fileName'] as String,
      type: json['type'] as String,
      mimeType: json['mimeType'] as String? ?? 'application/octet-stream',
      sizeBytes: (json['sizeBytes'] as num).toInt(),
      modifiedAt: DateTime.parse(json['modifiedAt'] as String),
      favorite: json['favorite'] as bool? ?? false,
      thumbnailUrl: json['thumbnailUrl'] as String,
      originalUrl: json['originalUrl'] as String,
      streamUrl: json['streamUrl'] as String,
    );
  }

  final String id;
  final String libraryId;
  final String fileName;
  final String type;
  final String mimeType;
  final int sizeBytes;
  final DateTime modifiedAt;
  final bool favorite;
  final String thumbnailUrl;
  final String originalUrl;
  final String streamUrl;

  bool get isVideo => type == 'video';

  MediaItem copyWith({bool? favorite}) {
    return MediaItem(
      id: id,
      libraryId: libraryId,
      fileName: fileName,
      type: type,
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      modifiedAt: modifiedAt,
      favorite: favorite ?? this.favorite,
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
