import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../models/local_server_config.dart';
import '../models/server_runtime_state.dart';
import '../models/server_settings.dart';

class LocalServerException implements Exception {
  const LocalServerException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LocalServerSupervisor {
  LocalServerSupervisor._();

  static final LocalServerSupervisor instance = LocalServerSupervisor._();
  static const _storageMarkerName = '.locallens-data-root.json';

  final StreamController<ServerRuntimeState> _stateController =
      StreamController<ServerRuntimeState>.broadcast();
  final StreamController<ServerLogEntry> _logController =
      StreamController<ServerLogEntry>.broadcast();

  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  ServerRuntimeState _state = const ServerRuntimeState.stopped();
  bool _intentionalStop = false;
  bool _disposed = false;

  ServerRuntimeState get state => _state;
  Stream<ServerRuntimeState> get states => _stateController.stream;
  Stream<ServerLogEntry> get logs => _logController.stream;

  String get defaultApplicationDataPath {
    final localAppData = Platform.environment['LOCALAPPDATA']?.trim();
    if (localAppData != null && localAppData.isNotEmpty) {
      return _join(localAppData, 'LocalLens');
    }
    return _join(File(Platform.resolvedExecutable).parent.path, 'LocalLensData');
  }

  String get storagePointerPath {
    final localAppData = Platform.environment['LOCALAPPDATA']?.trim();
    if (localAppData != null && localAppData.isNotEmpty) {
      return _join(localAppData, 'LocalLens.storage.json');
    }
    return _join(
      File(Platform.resolvedExecutable).parent.path,
      'LocalLens.storage.json',
    );
  }

  String get applicationDataPath {
    try {
      final pointer = File(storagePointerPath);
      if (!pointer.existsSync()) return defaultApplicationDataPath;
      final decoded = jsonDecode(pointer.readAsStringSync());
      final root = (decoded as Map<String, dynamic>)['root'] as String?;
      if (root == null || root.trim().isEmpty) {
        return defaultApplicationDataPath;
      }
      return Directory(root).absolute.path;
    } on Object {
      return defaultApplicationDataPath;
    }
  }

  String get configPath => _join(applicationDataPath, 'config', 'server.json');
  String get configBackupPath => '$configPath.backup';
  String get dataPath => _join(applicationDataPath, 'data');
  String get cachePath => _join(applicationDataPath, 'cache');
  String get logPath => _join(applicationDataPath, 'logs', 'server.log');
  String get pidPath => _join(applicationDataPath, 'runtime', 'server.pid');
  String get storageMarkerPath => _join(applicationDataPath, _storageMarkerName);

  String get bundledServerPath => _join(
        File(Platform.resolvedExecutable).parent.path,
        'runtime',
        'LocalLensServer.exe',
      );

  String get bundledFFmpegPath => _join(
        File(Platform.resolvedExecutable).parent.path,
        'runtime',
        'media-tools',
        'ffmpeg.exe',
      );

  String get bundledFFprobePath => _join(
        File(Platform.resolvedExecutable).parent.path,
        'runtime',
        'media-tools',
        'ffprobe.exe',
      );

  bool get isSupported => Platform.isWindows;
  bool get hasConfiguration => File(configPath).existsSync();
  bool get hasBundledServer => File(bundledServerPath).existsSync();
  bool get hasBundledFFmpeg =>
      File(bundledFFmpegPath).existsSync() &&
      File(bundledFFprobePath).existsSync();

  String resolveStorageRoot(String selectedDirectory) {
    final selected = Directory(selectedDirectory).absolute.path;
    if (_basename(selected).toLowerCase() == 'locallensdata') return selected;
    return _join(selected, 'LocalLensData');
  }

  Future<LocalServerConfig?> loadConfig() async {
    final file = File(configPath);
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      var config = LocalServerConfig.fromJson(
        decoded as Map<String, dynamic>,
      );
      final normalized = await _withAvailableMediaTools(config);
      if (normalized.dataDir != config.dataDir ||
          normalized.ffmpegPath != config.ffmpegPath ||
          normalized.ffprobePath != config.ffprobePath) {
        config = normalized;
        await _writeConfig(config, createBackup: false);
      }
      return config;
    } on LocalServerException {
      rethrow;
    } on Object catch (error) {
      throw LocalServerException('本地服务器配置无法读取：$error');
    }
  }

  Future<LocalServerConfig> createDefaultConfig({
    required String libraryPath,
    required String storageRoot,
    String libraryName = '媒体库',
    String serverName = 'LocalLens',
    bool allowLan = true,
    int port = 9527,
  }) async {
    final normalizedLibrary = Directory(libraryPath).absolute.path;
    final normalizedStorage = Directory(storageRoot).absolute.path;
    if (!await Directory(normalizedLibrary).exists()) {
      throw const LocalServerException('所选媒体目录不存在或无法访问');
    }
    if (port < 1024 || port > 65535) {
      throw const LocalServerException('端口必须在 1024 到 65535 之间');
    }

    final library = LocalLibraryConfig(
      id: 'main',
      name: libraryName.trim().isEmpty ? '媒体库' : libraryName.trim(),
      path: normalizedLibrary,
    );
    _validateStorageAgainstLibraries(
      normalizedStorage,
      <LocalLibraryConfig>[library],
    );

    await _activateStorageRoot(
      normalizedStorage,
      requireEmptyTarget: true,
    );
    await _ensureDirectories();
    final lanAddress = allowLan ? await discoverLanIPv4() : null;
    final config = LocalServerConfig(
      listenAddress: '${allowLan ? '0.0.0.0' : '127.0.0.1'}:$port',
      publicUrl: lanAddress == null ? '' : 'http://$lanAddress:$port',
      serverName: serverName.trim().isEmpty ? 'LocalLens' : serverName.trim(),
      dataDir: dataPath,
      apiToken: _createToken(),
      ffmpegPath: await File(bundledFFmpegPath).exists()
          ? bundledFFmpegPath
          : '',
      ffprobePath: await File(bundledFFprobePath).exists()
          ? bundledFFprobePath
          : '',
      autoScan: true,
      watchFiles: true,
      thumbnailWorkers: 2,
      metadataWorkers: 2,
      transcodeWorkers: 1,
      transcodeCacheGB: 20,
      transcodeHardware: 'software',
      pairingTTLMinutes: 5,
      libraries: <LocalLibraryConfig>[library],
    );
    await saveConfig(config);
    return config;
  }

  Future<void> saveConfig(LocalServerConfig config) async {
    _validateConfig(config);
    await _ensureDirectories();
    await _writeConfig(config, createBackup: true);
  }

  Future<void> _writeConfig(
    LocalServerConfig config, {
    required bool createBackup,
  }) async {
    final target = File(configPath);
    final temporary = File('$configPath.tmp');
    final backup = File(configBackupPath);
    await target.parent.create(recursive: true);
    final formatted = const JsonEncoder.withIndent('  ').convert(
      config.toJson(),
    );

    await temporary.writeAsString('$formatted\n', flush: true);
    if (await target.exists()) {
      if (createBackup) await target.copy(backup.path);
      await target.delete();
    }
    await temporary.rename(target.path);
  }

  void _validateConfig(LocalServerConfig config) {
    if (config.apiToken.length < 16) {
      throw const LocalServerException('管理员 Token 至少需要 16 个字符');
    }
    if (config.port < 1024 || config.port > 65535) {
      throw const LocalServerException('端口必须在 1024 到 65535 之间');
    }
    if (config.libraries.isEmpty) {
      throw const LocalServerException('至少需要一个媒体库');
    }
    for (final library in config.libraries) {
      if (library.name.trim().isEmpty || library.path.trim().isEmpty) {
        throw const LocalServerException('媒体库名称和目录不能为空');
      }
    }
    _validateStorageAgainstLibraries(applicationDataPath, config.libraries);
    if (config.thumbnailWorkers < 1 || config.thumbnailWorkers > 8 ||
        config.metadataWorkers < 1 || config.metadataWorkers > 8) {
      throw const LocalServerException('缩略图和元数据 Worker 必须在 1 到 8 之间');
    }
    if (config.transcodeWorkers < 1 || config.transcodeWorkers > 4) {
      throw const LocalServerException('转码 Worker 必须在 1 到 4 之间');
    }
    if (config.transcodeCacheGB < 1 || config.transcodeCacheGB > 500) {
      throw const LocalServerException('转码缓存必须在 1 到 500 GB 之间');
    }
  }

  void _validateStorageAgainstLibraries(
    String storageRoot,
    List<LocalLibraryConfig> libraries,
  ) {
    for (final library in libraries) {
      if (_pathsOverlap(storageRoot, library.path)) {
        throw const LocalServerException(
          'LocalLens 数据目录不能与媒体目录相同，也不能互相包含。请分别选择两个独立目录。',
        );
      }
    }
  }

  Future<ServerSettings> ensureRunning() async {
    if (!isSupported) {
      throw const LocalServerException('内置服务器仅支持 Windows');
    }
    final config = await loadConfig();
    if (config == null) {
      throw const LocalServerException('尚未完成本地服务器初始化');
    }
    final version = await _readServerVersion(config);
    if (version != null) {
      _emitState(ServerRuntimeState(
        status: ServerRuntimeStatus.running,
        processId: await _readPid(),
        port: config.port,
        startedAt: _state.startedAt,
        version: version,
      ));
      return _settingsFor(config);
    }
    await start(config: config);
    return _settingsFor(config);
  }

  Future<void> start({LocalServerConfig? config}) async {
    if (_state.isBusy) return;
    final effectiveConfig = config ?? await loadConfig();
    if (effectiveConfig == null) {
      throw const LocalServerException('尚未创建本地服务器配置');
    }
    if (!await File(bundledServerPath).exists()) {
      _emitState(ServerRuntimeState(
        status: ServerRuntimeStatus.configurationError,
        port: effectiveConfig.port,
        lastError: '安装包缺少内置 LocalLensServer.exe',
      ));
      throw const LocalServerException('安装包缺少内置服务器，请重新安装 LocalLens');
    }

    final existingVersion = await _readServerVersion(effectiveConfig);
    if (existingVersion != null) {
      _emitState(ServerRuntimeState(
        status: ServerRuntimeStatus.running,
        processId: await _readPid(),
        port: effectiveConfig.port,
        startedAt: _state.startedAt,
        version: existingVersion,
      ));
      return;
    }
    if (await _isPortOpen(effectiveConfig.port)) {
      _emitState(ServerRuntimeState(
        status: ServerRuntimeStatus.portConflict,
        port: effectiveConfig.port,
        lastError: '端口 ${effectiveConfig.port} 已被其他程序占用',
      ));
      throw LocalServerException('端口 ${effectiveConfig.port} 已被其他程序占用');
    }

    await _ensureDirectories();
    _intentionalStop = false;
    _emitState(ServerRuntimeState(
      status: ServerRuntimeStatus.starting,
      port: effectiveConfig.port,
      restartCount: _state.restartCount,
    ));

    try {
      final process = await Process.start(
        bundledServerPath,
        <String>['-config', configPath],
        workingDirectory: applicationDataPath,
        mode: ProcessStartMode.normal,
      );
      _process = process;
      await File(pidPath).writeAsString('${process.pid}', flush: true);
      _listenToProcess(process);
      unawaited(
        process.exitCode.then(
          (code) => _handleProcessExit(code, effectiveConfig),
        ),
      );

      final deadline = DateTime.now().add(const Duration(seconds: 20));
      String? version;
      while (DateTime.now().isBefore(deadline)) {
        version = await _readServerVersion(effectiveConfig);
        if (version != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      if (version == null) {
        await _terminateProcess();
        throw const LocalServerException('内置服务器启动超时，请查看服务器日志');
      }
      _emitState(ServerRuntimeState(
        status: ServerRuntimeStatus.running,
        processId: process.pid,
        port: effectiveConfig.port,
        startedAt: DateTime.now(),
        version: version,
        restartCount: _state.restartCount,
      ));
    } on LocalServerException {
      rethrow;
    } on Object catch (error) {
      _emitState(ServerRuntimeState(
        status: ServerRuntimeStatus.failed,
        port: effectiveConfig.port,
        lastError: '启动内置服务器失败：$error',
        restartCount: _state.restartCount,
      ));
      throw LocalServerException('启动内置服务器失败：$error');
    }
  }

  Future<void> stop() async {
    if (_state.status == ServerRuntimeStatus.stopped && _process == null) return;
    _intentionalStop = true;
    _emitState(_state.copyWith(status: ServerRuntimeStatus.stopping));
    await _terminateProcess();

    final pid = await _readPid();
    if (pid != null) {
      await Process.run('taskkill', <String>['/PID', '$pid', '/T', '/F']);
    }
    final pidFile = File(pidPath);
    if (await pidFile.exists()) await pidFile.delete();

    final config = await loadConfig();
    _emitState(ServerRuntimeState.stopped(port: config?.port ?? _state.port));
  }

  Future<void> restart({LocalServerConfig? config}) async {
    final effectiveConfig = config ?? await loadConfig();
    if (effectiveConfig == null) {
      throw const LocalServerException('尚未创建本地服务器配置');
    }
    _emitState(_state.copyWith(status: ServerRuntimeStatus.restarting));
    await stop();
    await start(config: effectiveConfig);
  }

  Future<ServerSettings> applyConfig(
    LocalServerConfig config, {
    String? storageRoot,
  }) async {
    final requestedRoot = storageRoot == null
        ? applicationDataPath
        : Directory(storageRoot).absolute.path;
    _validateStorageAgainstLibraries(requestedRoot, config.libraries);

    late final LocalServerConfig effectiveConfig;
    if (_samePath(requestedRoot, applicationDataPath)) {
      effectiveConfig = await _withAvailableMediaTools(
        config.copyWith(dataDir: dataPath),
      );
      await saveConfig(effectiveConfig);
      await restart(config: effectiveConfig);
    } else {
      effectiveConfig = await _moveStorageAndApplyConfig(
        requestedRoot,
        config,
      );
    }
    return _settingsFor(effectiveConfig);
  }

  Future<LocalServerConfig> _moveStorageAndApplyConfig(
    String newRoot,
    LocalServerConfig config,
  ) async {
    final oldRoot = applicationDataPath;
    if (_pathsOverlap(oldRoot, newRoot)) {
      throw const LocalServerException('新的数据目录不能位于当前数据目录内部或外部');
    }

    await stop();
    await _prepareStorageRoot(newRoot, requireEmptyTarget: true);
    await _copyDirectoryContents(Directory(oldRoot), Directory(newRoot));
    await _writeStoragePointer(newRoot);

    var migratedConfig = config.copyWith(dataDir: dataPath);
    migratedConfig = await _withAvailableMediaTools(migratedConfig);
    await saveConfig(migratedConfig);
    await start(config: migratedConfig);
    await _deleteOwnedRoot(oldRoot);
    return migratedConfig;
  }

  Future<void> clearDataAndRestoreDefaults() async {
    final currentRoot = applicationDataPath;
    await stop();
    await _deleteOwnedRoot(currentRoot);

    if (!_samePath(currentRoot, defaultApplicationDataPath)) {
      await _deleteOwnedRoot(defaultApplicationDataPath);
    }
    final pointer = File(storagePointerPath);
    if (await pointer.exists()) await pointer.delete();
    _emitState(const ServerRuntimeState.stopped());
  }

  ServerSettings _settingsFor(LocalServerConfig config) {
    return ServerSettings(
      baseUrl: config.localBaseUrl,
      token: config.apiToken,
      mode: ServerConnectionMode.local,
    );
  }

  Future<String?> discoverLanIPv4() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (_isPrivateIPv4(address.address)) return address.address;
        }
      }
      for (final interface in interfaces) {
        if (interface.addresses.isNotEmpty) {
          return interface.addresses.first.address;
        }
      }
    } on Object {
      return null;
    }
    return null;
  }

  Future<void> openDataDirectory() async {
    await _openDirectory(applicationDataPath);
  }

  Future<void> openLogDirectory() async {
    await _openDirectory(File(logPath).parent.path);
  }

  Future<void> _openDirectory(String path) async {
    await Directory(path).create(recursive: true);
    await Process.run('explorer.exe', <String>[path]);
  }

  void _listenToProcess(Process process) {
    _stdoutSubscription?.cancel();
    _stderrSubscription?.cancel();
    _stdoutSubscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => unawaited(_appendLog(line)));
    _stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => unawaited(_appendLog(line)));
  }

  Future<void> _appendLog(String line) async {
    if (line.trim().isEmpty) return;
    final entry = ServerLogEntry(
      timestamp: DateTime.now(),
      message: line.trim(),
    );
    if (!_logController.isClosed) _logController.add(entry);
    await File(logPath).parent.create(recursive: true);
    await File(logPath).writeAsString(
      '${entry.timestamp.toIso8601String()} ${entry.message}\n',
      mode: FileMode.append,
      flush: false,
    );
  }

  Future<void> _handleProcessExit(int code, LocalServerConfig config) async {
    _process = null;
    if (_intentionalStop || _disposed) return;
    final attempt = _state.restartCount + 1;
    _emitState(ServerRuntimeState(
      status: ServerRuntimeStatus.failed,
      port: config.port,
      lastError: '内置服务器异常退出，退出码 $code',
      restartCount: attempt,
    ));
    if (attempt > 3) return;
    await Future<void>.delayed(
      Duration(seconds: attempt == 1 ? 2 : attempt == 2 ? 5 : 15),
    );
    if (_intentionalStop || _disposed) return;
    try {
      await start(config: config);
    } on Object {
      // start() has already emitted an actionable error state.
    }
  }

  Future<void> _terminateProcess() async {
    final process = _process;
    _process = null;
    if (process == null) return;
    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      await Process.run(
        'taskkill',
        <String>['/PID', '${process.pid}', '/T', '/F'],
      );
    }
  }

  Future<String?> _readServerVersion(LocalServerConfig config) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 700);
    try {
      final request = await client
          .getUrl(Uri.parse('${config.localBaseUrl}/api/v1/server'))
          .timeout(const Duration(milliseconds: 900));
      final response = await request
          .close()
          .timeout(const Duration(milliseconds: 900));
      if (response.statusCode != HttpStatus.ok) return null;
      final body = await response.transform(utf8.decoder).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
      return data['version'] as String? ?? 'unknown';
    } on Object {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> _isPortOpen(int port) async {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(milliseconds: 500),
      );
      await socket.close();
      return true;
    } on Object {
      return false;
    }
  }

  Future<int?> _readPid() async {
    try {
      final file = File(pidPath);
      if (!await file.exists()) return null;
      return int.tryParse((await file.readAsString()).trim());
    } on Object {
      return null;
    }
  }

  Future<LocalServerConfig> _withAvailableMediaTools(
    LocalServerConfig config,
  ) async {
    final ffmpeg = await _resolveToolPath(
      config.ffmpegPath,
      bundledFFmpegPath,
    );
    final ffprobe = await _resolveToolPath(
      config.ffprobePath,
      bundledFFprobePath,
    );
    return config.copyWith(
      dataDir: dataPath,
      ffmpegPath: ffmpeg,
      ffprobePath: ffprobe,
    );
  }

  Future<String> _resolveToolPath(String configured, String bundled) async {
    if (configured.trim().isNotEmpty && await File(configured).exists()) {
      return File(configured).absolute.path;
    }
    if (await File(bundled).exists()) return File(bundled).absolute.path;
    return '';
  }

  Future<void> _activateStorageRoot(
    String root, {
    required bool requireEmptyTarget,
  }) async {
    final normalized = Directory(root).absolute.path;
    await _prepareStorageRoot(
      normalized,
      requireEmptyTarget: requireEmptyTarget,
    );
    if (_samePath(normalized, defaultApplicationDataPath)) {
      final pointer = File(storagePointerPath);
      if (await pointer.exists()) await pointer.delete();
    } else {
      await _writeStoragePointer(normalized);
    }
  }

  Future<void> _prepareStorageRoot(
    String root, {
    required bool requireEmptyTarget,
  }) async {
    final directory = Directory(root);
    if (await directory.exists()) {
      final marker = File(_join(root, _storageMarkerName));
      final entries = await directory.list(followLinks: false).toList();
      final isSafeLegacyDefault = _samePath(root, defaultApplicationDataPath);
      if (requireEmptyTarget &&
          entries.isNotEmpty &&
          !await marker.exists() &&
          !isSafeLegacyDefault) {
        throw const LocalServerException(
          '所选数据目录已经包含其他文件。请选择一个空目录，或选择其上级目录让 LocalLens 创建 LocalLensData。',
        );
      }
    } else {
      await directory.create(recursive: true);
    }
    await File(_join(root, _storageMarkerName)).writeAsString(
      const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
        'owner': 'LocalLens',
        'schema': 1,
      }),
      flush: true,
    );
  }

  Future<void> _writeStoragePointer(String root) async {
    final pointer = File(storagePointerPath);
    await pointer.parent.create(recursive: true);
    final temporary = File('${pointer.path}.tmp');
    final formatted = const JsonEncoder.withIndent('  ').convert(
      <String, dynamic>{'root': root, 'schema': 1},
    );
    await temporary.writeAsString('$formatted\n', flush: true);
    if (await pointer.exists()) await pointer.delete();
    await temporary.rename(pointer.path);
  }

  Future<void> _copyDirectoryContents(
    Directory source,
    Directory destination,
  ) async {
    if (!await source.exists()) return;
    await destination.create(recursive: true);
    await for (final entity in source.list(followLinks: false)) {
      final targetPath = _join(destination.path, _basename(entity.path));
      if (entity is Directory) {
        await _copyDirectoryContents(entity, Directory(targetPath));
      } else if (entity is File) {
        await entity.copy(targetPath);
      }
    }
  }

  Future<void> _deleteOwnedRoot(String root) async {
    final directory = Directory(root);
    if (!await directory.exists()) return;
    final isDefault = _samePath(root, defaultApplicationDataPath);
    final marker = File(_join(root, _storageMarkerName));
    if (!isDefault && !await marker.exists()) {
      throw const LocalServerException(
        '拒绝清除未标记为 LocalLens 专用的数据目录，以避免误删其他文件。',
      );
    }
    await directory.delete(recursive: true);
  }

  Future<void> _ensureDirectories() async {
    for (final path in <String>[
      applicationDataPath,
      File(configPath).parent.path,
      dataPath,
      cachePath,
      File(logPath).parent.path,
      File(pidPath).parent.path,
    ]) {
      await Directory(path).create(recursive: true);
    }
    final marker = File(storageMarkerPath);
    if (!await marker.exists()) {
      await marker.writeAsString(
        const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
          'owner': 'LocalLens',
          'schema': 1,
        }),
        flush: true,
      );
    }
  }

  String _createToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  bool _isPrivateIPv4(String value) {
    final parts = value.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((item) => item == null)) return false;
    final a = parts[0]!;
    final b = parts[1]!;
    return a == 10 ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168);
  }

  bool _samePath(String first, String second) {
    return _comparablePath(first) == _comparablePath(second);
  }

  bool _pathsOverlap(String first, String second) {
    final a = _comparablePath(first);
    final b = _comparablePath(second);
    if (a == b) return true;
    final separator = Platform.pathSeparator;
    return a.startsWith('$b$separator') || b.startsWith('$a$separator');
  }

  String _comparablePath(String path) {
    var normalized = Directory(path).absolute.path;
    normalized = normalized.replaceAll('/', Platform.pathSeparator);
    normalized = normalized.replaceAll(RegExp(r'[\\/]+$'), '');
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  String _basename(String path) {
    final normalized = path.replaceAll(RegExp(r'[\\/]+$'), '');
    return normalized.split(RegExp(r'[\\/]')).last;
  }

  String _join(String first, String second, [String? third, String? fourth]) {
    final separator = Platform.pathSeparator;
    return <String>[
      first,
      second,
      if (third != null) third,
      if (fourth != null) fourth,
    ]
        .where((part) => part.isNotEmpty)
        .map((part) => part.replaceAll(RegExp(r'[\\/]+$'), ''))
        .join(separator);
  }

  void _emitState(ServerRuntimeState next) {
    _state = next;
    if (!_stateController.isClosed) _stateController.add(next);
  }

  Future<void> dispose({bool stopServer = true}) async {
    _disposed = true;
    if (stopServer) await stop();
    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
  }
}
