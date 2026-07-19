import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../models/server_runtime_state.dart';
import '../models/server_settings.dart';

class EmbeddedServerBootstrap {
  const EmbeddedServerBootstrap({
    required this.settings,
    required this.configPath,
    required this.dataDir,
    required this.created,
  });

  final ServerSettings settings;
  final String configPath;
  final String dataDir;
  final bool created;
}

class EmbeddedServerSupervisor {
  EmbeddedServerSupervisor._();

  static final EmbeddedServerSupervisor instance = EmbeddedServerSupervisor._();

  final StreamController<ServerRuntimeState> _stateController =
      StreamController<ServerRuntimeState>.broadcast();
  final StreamController<String> _logController =
      StreamController<String>.broadcast();

  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  Timer? _healthTimer;
  ServerRuntimeState _state = Platform.isWindows
      ? const ServerRuntimeState(status: ServerRuntimeStatus.stopped)
      : const ServerRuntimeState.unsupported();
  String? _configPath;
  int _restartCount = 0;
  bool _intentionalStop = false;

  Stream<ServerRuntimeState> get states => _stateController.stream;
  Stream<String> get logs => _logController.stream;
  ServerRuntimeState get state => _state;

  Future<EmbeddedServerBootstrap> ensureBootstrap() async {
    if (!Platform.isWindows) {
      throw UnsupportedError('Embedded server is only available on Windows.');
    }
    final localAppData = Platform.environment['LOCALAPPDATA'];
    final userProfile = Platform.environment['USERPROFILE'];
    if (localAppData == null || localAppData.trim().isEmpty) {
      throw const FileSystemException('LOCALAPPDATA is unavailable');
    }

    final root = Directory(_join(localAppData, 'LocalLens'));
    final configDir = Directory(_join(root.path, 'config'));
    final dataDir = Directory(_join(root.path, 'data'));
    final logsDir = Directory(_join(root.path, 'logs'));
    final cacheDir = Directory(_join(root.path, 'cache'));
    for (final directory in [root, configDir, dataDir, logsDir, cacheDir]) {
      await directory.create(recursive: true);
    }

    final configFile = File(_join(configDir.path, 'server.json'));
    var created = false;
    Map<String, dynamic> config;
    if (await configFile.exists()) {
      config = jsonDecode(await configFile.readAsString()) as Map<String, dynamic>;
    } else {
      created = true;
      final pictures = userProfile == null
          ? _join(root.path, 'Media')
          : _join(userProfile, 'Pictures');
      await Directory(pictures).create(recursive: true);
      final runtimeDir = _runtimeDirectory();
      config = <String, dynamic>{
        'listen_address': '0.0.0.0:9527',
        'public_url': '',
        'server_name': 'LocalLens',
        'data_dir': dataDir.path,
        'api_token': _secureToken(),
        'ffmpeg_path': _join(runtimeDir, 'media-tools\\ffmpeg.exe'),
        'ffprobe_path': _join(runtimeDir, 'media-tools\\ffprobe.exe'),
        'thumbnail_workers': 2,
        'metadata_workers': 2,
        'transcode_workers': 1,
        'transcode_cache_gb': 20,
        'transcode_hardware': 'software',
        'auto_scan': true,
        'watch_files': true,
        'pairing_ttl_minutes': 5,
        'libraries': [
          {
            'id': 'pictures',
            'name': '图片',
            'path': pictures,
            'recursive': true,
            'enabled': true,
          }
        ],
      };
      await _atomicWriteJson(configFile, config);
    }

    final token = config['api_token'] as String? ?? '';
    if (token.length < 16) {
      throw const FormatException('Embedded server token is invalid.');
    }
    _configPath = configFile.path;
    return EmbeddedServerBootstrap(
      settings: ServerSettings(
        baseUrl: 'http://127.0.0.1:9527',
        token: token,
      ),
      configPath: configFile.path,
      dataDir: dataDir.path,
      created: created,
    );
  }

  Future<void> start({String? configPath}) async {
    if (!Platform.isWindows) return;
    if (_state.status == ServerRuntimeStatus.starting || _state.isRunning) return;
    final bootstrap = configPath == null ? await ensureBootstrap() : null;
    final effectiveConfig = configPath ?? bootstrap!.configPath;
    _configPath = effectiveConfig;
    _intentionalStop = false;
    _emit(ServerRuntimeState(
      status: ServerRuntimeStatus.starting,
      restartCount: _restartCount,
    ));

    final executable = _serverExecutable();
    if (!await File(executable).exists()) {
      _emit(ServerRuntimeState(
        status: ServerRuntimeStatus.failed,
        lastError: '未找到内置服务端：$executable',
        restartCount: _restartCount,
      ));
      return;
    }

    try {
      final process = await Process.start(
        executable,
        ['-config', effectiveConfig],
        workingDirectory: _runtimeDirectory(),
        mode: ProcessStartMode.detachedWithStdio,
      );
      _process = process;
      _stdoutSubscription = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_captureLog);
      _stderrSubscription = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_captureLog);
      unawaited(process.exitCode.then(_handleExit));
      _emit(ServerRuntimeState(
        status: ServerRuntimeStatus.starting,
        processId: process.pid,
        startedAt: DateTime.now(),
        restartCount: _restartCount,
      ));
      await _waitForHealth();
      _beginHealthPolling();
    } catch (error) {
      _emit(ServerRuntimeState(
        status: ServerRuntimeStatus.failed,
        lastError: '$error',
        restartCount: _restartCount,
      ));
    }
  }

  Future<void> stop() async {
    if (!Platform.isWindows) return;
    _intentionalStop = true;
    _healthTimer?.cancel();
    final process = _process;
    if (process == null) {
      _emit(const ServerRuntimeState(status: ServerRuntimeStatus.stopped));
      return;
    }
    _emit(_state.copyWith(status: ServerRuntimeStatus.stopping));
    process.kill(ProcessSignal.sigterm);
    try {
      await process.exitCode.timeout(const Duration(seconds: 8));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
    }
    _process = null;
    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    _emit(ServerRuntimeState(
      status: ServerRuntimeStatus.stopped,
      restartCount: _restartCount,
    ));
  }

  Future<void> restart() async {
    await stop();
    _intentionalStop = false;
    await start(configPath: _configPath);
  }

  Future<bool> healthCheck() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final request = await client.getUrl(Uri.parse('http://127.0.0.1:9527/api/v1/health'));
      final response = await request.close().timeout(const Duration(seconds: 2));
      await response.drain<void>();
      return response.statusCode == HttpStatus.ok;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _waitForHealth() async {
    for (var attempt = 0; attempt < 40; attempt++) {
      if (await healthCheck()) {
        _emit(_state.copyWith(
          status: ServerRuntimeStatus.running,
          clearError: true,
        ));
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    _emit(_state.copyWith(
      status: ServerRuntimeStatus.failed,
      lastError: '服务端启动超时，请检查端口占用和配置文件。',
    ));
  }

  void _beginHealthPolling() {
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (_intentionalStop || _process == null) return;
      if (!await healthCheck()) {
        _emit(_state.copyWith(
          status: ServerRuntimeStatus.failed,
          lastError: '服务端健康检查失败。',
        ));
      } else if (!_state.isRunning) {
        _emit(_state.copyWith(status: ServerRuntimeStatus.running, clearError: true));
      }
    });
  }

  Future<void> _handleExit(int exitCode) async {
    _process = null;
    _healthTimer?.cancel();
    if (_intentionalStop) return;
    _restartCount += 1;
    _emit(ServerRuntimeState(
      status: ServerRuntimeStatus.failed,
      lastError: '服务端异常退出，退出码 $exitCode。',
      restartCount: _restartCount,
    ));
    if (_restartCount > 3) return;
    final delays = [2, 5, 15];
    await Future<void>.delayed(Duration(seconds: delays[_restartCount - 1]));
    if (!_intentionalStop) await start(configPath: _configPath);
  }

  void _captureLog(String line) {
    if (line.trim().isNotEmpty) _logController.add(line);
  }

  void _emit(ServerRuntimeState next) {
    _state = next;
    _stateController.add(next);
  }

  String _runtimeDirectory() => _join(File(Platform.resolvedExecutable).parent.path, 'runtime');
  String _serverExecutable() => _join(_runtimeDirectory(), 'LocalLensServer.exe');

  static Future<void> _atomicWriteJson(
    File target,
    Map<String, dynamic> value,
  ) async {
    final temporary = File('${target.path}.tmp');
    final backup = File('${target.path}.backup');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(value),
      flush: true,
    );
    if (await target.exists()) await target.copy(backup.path);
    await temporary.rename(target.path);
  }

  static String _secureToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  static String _join(String left, String right) {
    final separator = Platform.pathSeparator;
    return '${left.replaceAll(RegExp(r'[\\/]+$'), '')}$separator${right.replaceAll(RegExp(r'^[\\/]+'), '')}';
  }
}
