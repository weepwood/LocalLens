class LibraryInfo {
  const LibraryInfo({
    required this.id,
    required this.name,
    required this.recursive,
    required this.enabled,
    this.lastScannedAt,
  });

  factory LibraryInfo.fromJson(Map<String, dynamic> json) {
    return LibraryInfo(
      id: json['id'] as String,
      name: json['name'] as String,
      recursive: json['recursive'] as bool? ?? true,
      enabled: json['enabled'] as bool? ?? true,
      lastScannedAt: _parseDate(json['lastScannedAt']),
    );
  }

  final String id;
  final String name;
  final bool recursive;
  final bool enabled;
  final DateTime? lastScannedAt;
}

class ScanStatus {
  const ScanStatus({
    required this.running,
    required this.discovered,
    required this.indexed,
    required this.failed,
    this.startedAt,
    this.finishedAt,
    this.current,
    this.errorMessage,
  });

  factory ScanStatus.fromJson(Map<String, dynamic> json) {
    return ScanStatus(
      running: json['running'] as bool? ?? false,
      startedAt: _parseDate(json['startedAt']),
      finishedAt: _parseDate(json['finishedAt']),
      current: _stringOrNull(json['current']),
      discovered: (json['discovered'] as num? ?? 0).toInt(),
      indexed: (json['indexed'] as num? ?? 0).toInt(),
      failed: (json['failed'] as num? ?? 0).toInt(),
      errorMessage: _stringOrNull(json['errorMessage']),
    );
  }

  final bool running;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final String? current;
  final int discovered;
  final int indexed;
  final int failed;
  final String? errorMessage;

  double? get progress {
    if (discovered <= 0) return null;
    return (indexed / discovered).clamp(0, 1).toDouble();
  }
}

DateTime? _parseDate(Object? value) {
  if (value is! String || value.trim().isEmpty) return null;
  return DateTime.tryParse(value)?.toLocal();
}

String? _stringOrNull(Object? value) {
  if (value is! String || value.trim().isEmpty) return null;
  return value.trim();
}
