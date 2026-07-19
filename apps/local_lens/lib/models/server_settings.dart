enum ServerConnectionMode { local, remote }

class ServerSettings {
  const ServerSettings({
    required this.baseUrl,
    required this.token,
    this.mode = ServerConnectionMode.remote,
  });

  final String baseUrl;
  final String token;
  final ServerConnectionMode mode;

  bool get isLocal => mode == ServerConnectionMode.local;

  String get normalizedBaseUrl => baseUrl.endsWith('/')
      ? baseUrl.substring(0, baseUrl.length - 1)
      : baseUrl;
}
