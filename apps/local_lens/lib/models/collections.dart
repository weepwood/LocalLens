import 'dart:convert';

class FolderInfo {
  const FolderInfo({
    required this.id,
    required this.libraryId,
    required this.path,
    required this.parentPath,
    required this.name,
    required this.mediaCount,
    required this.childCount,
  });

  factory FolderInfo.fromJson(Map<String, dynamic> json) => FolderInfo(
        id: json['id'] as String,
        libraryId: json['libraryId'] as String,
        path: json['path'] as String? ?? '',
        parentPath: json['parentPath'] as String? ?? '',
        name: json['name'] as String,
        mediaCount: (json['mediaCount'] as num? ?? 0).toInt(),
        childCount: (json['childCount'] as num? ?? 0).toInt(),
      );

  final String id;
  final String libraryId;
  final String path;
  final String parentPath;
  final String name;
  final int mediaCount;
  final int childCount;
}

class AlbumInfo {
  const AlbumInfo({
    required this.id,
    required this.name,
    required this.description,
    required this.itemCount,
    required this.createdAt,
    required this.updatedAt,
  });

  factory AlbumInfo.fromJson(Map<String, dynamic> json) => AlbumInfo(
        id: json['id'] as String,
        name: json['name'] as String,
        description: json['description'] as String? ?? '',
        itemCount: (json['itemCount'] as num? ?? 0).toInt(),
        createdAt: DateTime.parse(json['createdAt'] as String).toLocal(),
        updatedAt: DateTime.parse(json['updatedAt'] as String).toLocal(),
      );

  final String id;
  final String name;
  final String description;
  final int itemCount;
  final DateTime createdAt;
  final DateTime updatedAt;
}

class TagInfo {
  const TagInfo({
    required this.id,
    required this.name,
    required this.color,
    required this.itemCount,
    required this.createdAt,
  });

  factory TagInfo.fromJson(Map<String, dynamic> json) => TagInfo(
        id: json['id'] as String,
        name: json['name'] as String,
        color: json['color'] as String? ?? '',
        itemCount: (json['itemCount'] as num? ?? 0).toInt(),
        createdAt: DateTime.parse(json['createdAt'] as String).toLocal(),
      );

  final String id;
  final String name;
  final String color;
  final int itemCount;
  final DateTime createdAt;
}

class MediaCollectionState {
  const MediaCollectionState({required this.albumIds, required this.tagIds});

  factory MediaCollectionState.fromJson(Map<String, dynamic> json) =>
      MediaCollectionState(
        albumIds: (json['albumIds'] as List<dynamic>? ?? const [])
            .cast<String>()
            .toSet(),
        tagIds: (json['tagIds'] as List<dynamic>? ?? const [])
            .cast<String>()
            .toSet(),
      );

  final Set<String> albumIds;
  final Set<String> tagIds;
}

class PlaybackProgress {
  const PlaybackProgress({
    required this.positionMs,
    required this.durationMs,
    required this.completed,
    this.deviceId = '',
    this.mediaId = '',
    this.updatedAt,
  });

  factory PlaybackProgress.fromJson(Map<String, dynamic> json) =>
      PlaybackProgress(
        positionMs: (json['positionMs'] as num? ?? 0).toInt(),
        durationMs: (json['durationMs'] as num? ?? 0).toInt(),
        completed: json['completed'] as bool? ?? false,
        deviceId: json['deviceId'] as String? ?? '',
        mediaId: json['mediaId'] as String? ?? '',
        updatedAt: _date(json['updatedAt']),
      );

  final int positionMs;
  final int durationMs;
  final bool completed;
  final String deviceId;
  final String mediaId;
  final DateTime? updatedAt;
}

class DeviceInfo {
  const DeviceInfo({
    required this.id,
    required this.name,
    required this.platform,
    required this.scopes,
    required this.createdAt,
    this.lastSeenAt,
    this.revokedAt,
  });

  factory DeviceInfo.fromJson(Map<String, dynamic> json) => DeviceInfo(
        id: json['id'] as String,
        name: json['name'] as String,
        platform: json['platform'] as String? ?? '',
        scopes: json['scopes'] as String? ?? '',
        createdAt: DateTime.parse(json['createdAt'] as String).toLocal(),
        lastSeenAt: _date(json['lastSeenAt']),
        revokedAt: _date(json['revokedAt']),
      );

  final String id;
  final String name;
  final String platform;
  final String scopes;
  final DateTime createdAt;
  final DateTime? lastSeenAt;
  final DateTime? revokedAt;
}

class PairingSessionInfo {
  const PairingSessionInfo({
    required this.id,
    required this.payload,
    required this.expiresAt,
    required this.qrUrl,
  });

  factory PairingSessionInfo.fromJson(Map<String, dynamic> json) =>
      PairingSessionInfo(
        id: json['id'] as String,
        payload: json['payload'] as String,
        expiresAt: DateTime.parse(json['expiresAt'] as String).toLocal(),
        qrUrl: json['qrUrl'] as String,
      );

  final String id;
  final String payload;
  final DateTime expiresAt;
  final String qrUrl;
}

class PairingPayload {
  const PairingPayload({
    required this.baseUrl,
    required this.serverName,
    required this.pairingId,
    required this.secret,
    required this.expiresAt,
  });

  factory PairingPayload.parse(String value) {
    final json = jsonDecode(value) as Map<String, dynamic>;
    if ((json['version'] as num? ?? 0).toInt() != 1) {
      throw const FormatException('不支持的配对二维码版本');
    }
    return PairingPayload(
      baseUrl: json['baseUrl'] as String,
      serverName: json['serverName'] as String? ?? 'LocalLens',
      pairingId: json['pairingId'] as String,
      secret: json['secret'] as String,
      expiresAt: DateTime.parse(json['expiresAt'] as String).toLocal(),
    );
  }

  final String baseUrl;
  final String serverName;
  final String pairingId;
  final String secret;
  final DateTime expiresAt;
}

DateTime? _date(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value)?.toLocal();
}
