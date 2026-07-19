enum ServerRuntimeStatus {
  stopped,
  starting,
  running,
  stopping,
  restarting,
  failed,
  portConflict,
  configurationError,
}

class ServerRuntimeState {
  const ServerRuntimeState({
    required this.status,
    required this.port,
    this.processId,
    this.startedAt,
    this.version,
    this.lastError,
    this.restartCount = 0,
  });

  const ServerRuntimeState.stopped({this.port = 9527})
      : status = ServerRuntimeStatus.stopped,
        processId = null,
        startedAt = null,
        version = null,
        lastError = null,
        restartCount = 0;

  final ServerRuntimeStatus status;
  final int? processId;
  final int port;
  final DateTime? startedAt;
  final String? version;
  final String? lastError;
  final int restartCount;

  bool get isRunning => status == ServerRuntimeStatus.running;
  bool get isBusy => status == ServerRuntimeStatus.starting ||
      status == ServerRuntimeStatus.stopping ||
      status == ServerRuntimeStatus.restarting;

  ServerRuntimeState copyWith({
    ServerRuntimeStatus? status,
    int? processId,
    bool clearProcessId = false,
    int? port,
    DateTime? startedAt,
    String? version,
    String? lastError,
    bool clearError = false,
    int? restartCount,
  }) {
    return ServerRuntimeState(
      status: status ?? this.status,
      processId: clearProcessId ? null : processId ?? this.processId,
      port: port ?? this.port,
      startedAt: startedAt ?? this.startedAt,
      version: version ?? this.version,
      lastError: clearError ? null : lastError ?? this.lastError,
      restartCount: restartCount ?? this.restartCount,
    );
  }
}

class ServerLogEntry {
  const ServerLogEntry({required this.timestamp, required this.message});

  final DateTime timestamp;
  final String message;
}
