class ServerSettings {
  const ServerSettings({required this.baseUrl, required this.token});

  final String baseUrl;
  final String token;

  String get normalizedBaseUrl => baseUrl.endsWith('/')
      ? baseUrl.substring(0, baseUrl.length - 1)
      : baseUrl;
}
