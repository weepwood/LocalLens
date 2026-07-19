enum ServerRuntimeStatus {
  unsupported,
  stopped,
  starting,
  running,
  stopping,
  failed,
  portConflict,
  configurationError,
}

class ServerRuntimeState {
  const ServerRuntimeState({
    required this.status,
    this.processId,
    this.startedAt,
    this.version,
    this.lastError,
    this.restartCount = 0,
  });

  const ServerRuntimeState.unsupported()
      : status = ServerRuntimeStatus.unsupported,
        processId = null,
        startedAt = null,
        version = null,
        lastError = null,
        restartCount = 0;

  final ServerRuntimeStatus status;
  final int? processId;
  final DateTime? startedAt;
  final String? version;
  final String? lastError;
  final int restartCount;

  bool get isRunning => status == ServerRuntimeStatus.running;

  ServerRuntimeState copyWith({
    ServerRuntimeStatus? status,
    int? processId,
    DateTime? startedAt,
    String? version,
    String? lastError,
    int? restartCount,
    bool clearProcessId = false,
    bool clearError = false,
  }) {
    return ServerRuntimeState(
      status: status ?? this.status,
      processId: clearProcessId ? null : processId ?? this.processId,
      startedAt: startedAt ?? this.startedAt,
      version: version ?? this.version,
      lastError: clearError ? null : lastError ?? this.lastError,
      restartCount: restartCount ?? this.restartCount,
    );
  }
}
