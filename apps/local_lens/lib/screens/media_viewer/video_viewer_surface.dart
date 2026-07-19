import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../models/media_item.dart';
import '../../services/api_client.dart';

class VideoViewerSurface extends StatefulWidget {
  const VideoViewerSurface({
    required this.item,
    required this.url,
    required this.headers,
    required this.api,
    required this.onPrevious,
    required this.onNext,
    required this.onRequestFullscreen,
    required this.onControlsVisibilityChanged,
    super.key,
  });

  final MediaItem item;
  final String url;
  final Map<String, String> headers;
  final ApiClient api;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback onRequestFullscreen;
  final ValueChanged<bool> onControlsVisibilityChanged;

  @override
  State<VideoViewerSurface> createState() => _VideoViewerSurfaceState();
}

class _VideoViewerSurfaceState extends State<VideoViewerSurface>
    with WidgetsBindingObserver {
  late final Player _player;
  late final VideoController _controller;
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  Timer? _saveTimer;
  Timer? _hideTimer;
  Timer? _resumeTimer;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffer = Duration.zero;
  Duration _resumePosition = Duration.zero;
  bool _playing = false;
  bool _buffering = false;
  bool _ready = false;
  bool _restored = false;
  bool _closing = false;
  bool _controlsVisible = true;
  bool _showResumePrompt = false;
  double _volume = 100;
  double _lastAudibleVolume = 100;
  double _rate = 1;
  String? _error;
  Offset? _doubleTapPosition;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _player = Player();
    _controller = VideoController(_player);
    _subscriptions.addAll([
      _player.stream.position.listen((value) {
        if (mounted) setState(() => _position = value);
      }),
      _player.stream.duration.listen((value) {
        if (mounted) setState(() => _duration = value);
      }),
      _player.stream.buffer.listen((value) {
        if (mounted) setState(() => _buffer = value);
      }),
      _player.stream.playing.listen((value) {
        _playing = value;
        if (value) {
          unawaited(WakelockPlus.enable());
          _scheduleControlsHide();
        } else {
          unawaited(WakelockPlus.disable());
          _showControls();
          unawaited(_saveProgress());
        }
        if (mounted) setState(() {});
      }),
      _player.stream.buffering.listen((value) {
        if (mounted) setState(() => _buffering = value);
      }),
      _player.stream.volume.listen((value) {
        _volume = value;
        if (value > 0) _lastAudibleVolume = value;
        if (mounted) setState(() {});
      }),
      _player.stream.rate.listen((value) {
        if (mounted) setState(() => _rate = value);
      }),
      _player.stream.error.listen((value) {
        if (value.trim().isEmpty || !mounted) return;
        setState(() => _error = value.trim());
        _showControls();
      }),
      _player.stream.completed.listen((completed) {
        if (!completed) return;
        unawaited(_saveProgress(force: true, completedOverride: true));
        _showControls();
      }),
    ]);
    _saveTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => unawaited(_saveProgress()),
    );
    unawaited(_open());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_saveProgress(force: true));
    }
  }

  Future<void> _open() async {
    try {
      final progress = await widget.api.getPlaybackProgress(widget.item.id);
      await _player.open(
        Media(widget.url, httpHeaders: widget.headers),
        play: false,
      );
      if (!mounted) return;
      final knownDuration = progress.durationMs > 0
          ? progress.durationMs
          : widget.item.durationMs;
      final remaining = knownDuration - progress.positionMs;
      final shouldPrompt = progress.positionMs >= 10000 &&
          !progress.completed &&
          (knownDuration <= 0 || remaining > 30000);
      setState(() {
        _ready = true;
        _restored = true;
        _resumePosition = Duration(milliseconds: progress.positionMs);
        _showResumePrompt = shouldPrompt;
      });
      if (shouldPrompt) {
        _resumeTimer = Timer(const Duration(seconds: 5), _continuePlayback);
      } else {
        await _player.play();
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _ready = true;
        _error = _readablePlaybackError(error);
      });
    }
  }

  Future<void> _continuePlayback() async {
    _resumeTimer?.cancel();
    if (_resumePosition > Duration.zero) await _player.seek(_resumePosition);
    if (mounted) setState(() => _showResumePrompt = false);
    await _player.play();
  }

  Future<void> _restartPlayback() async {
    _resumeTimer?.cancel();
    await _player.seek(Duration.zero);
    if (mounted) setState(() => _showResumePrompt = false);
    await _player.play();
  }

  Future<void> _retry() async {
    setState(() {
      _error = null;
      _ready = false;
      _restored = false;
    });
    await _player.stop();
    await _open();
  }

  void _showControls() {
    _hideTimer?.cancel();
    if (!_controlsVisible) {
      _controlsVisible = true;
      widget.onControlsVisibilityChanged(true);
    }
    if (mounted) setState(() {});
  }

  void _scheduleControlsHide() {
    _hideTimer?.cancel();
    if (!_playing || _showResumePrompt || _error != null) return;
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted || !_playing) return;
      setState(() => _controlsVisible = false);
      widget.onControlsVisibilityChanged(false);
    });
  }

  void _toggleControls() {
    _hideTimer?.cancel();
    setState(() => _controlsVisible = !_controlsVisible);
    widget.onControlsVisibilityChanged(_controlsVisible);
    if (_controlsVisible) _scheduleControlsHide();
  }

  Future<void> _seekRelative(Duration delta) async {
    final durationMs = _effectiveDuration.inMilliseconds;
    final target = (_position.inMilliseconds + delta.inMilliseconds)
        .clamp(0, durationMs > 0 ? durationMs : 1 << 31);
    await _player.seek(Duration(milliseconds: target));
    await _saveProgress(force: true);
    _showControls();
    _scheduleControlsHide();
  }

  Future<void> _seekTo(double milliseconds) async {
    await _player.seek(Duration(milliseconds: milliseconds.round()));
    await _saveProgress(force: true);
    _scheduleControlsHide();
  }

  Future<void> _toggleMute() async {
    if (_volume <= 0) {
      await _player.setVolume(_lastAudibleVolume.clamp(5, 100));
    } else {
      _lastAudibleVolume = _volume;
      await _player.setVolume(0);
    }
  }

  Future<void> _saveProgress({
    bool force = false,
    bool? completedOverride,
  }) async {
    if (!_restored || (_closing && !force)) return;
    final durationMs = _effectiveDuration.inMilliseconds;
    final positionMs = _position.inMilliseconds;
    if (!force && positionMs < 1000) return;
    final completionWindow = durationMs <= 0
        ? 10000
        : (durationMs * 0.02).round().clamp(10000, 60000);
    final completed = completedOverride ??
        (durationMs > 0 && positionMs >= durationMs - completionWindow);
    try {
      await widget.api.savePlaybackProgress(
        widget.item.id,
        positionMs: completed ? 0 : positionMs,
        durationMs: durationMs,
        completed: completed,
      );
    } catch (_) {
      // Progress synchronization must never interrupt playback.
    }
  }

  Duration get _effectiveDuration => _duration > Duration.zero
      ? _duration
      : Duration(milliseconds: widget.item.durationMs);

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (key == LogicalKeyboardKey.space) {
      unawaited(_player.playOrPause());
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      unawaited(_seekRelative(Duration(seconds: shift ? -30 : -5)));
    } else if (key == LogicalKeyboardKey.arrowRight) {
      unawaited(_seekRelative(Duration(seconds: shift ? 30 : 5)));
    } else if (key == LogicalKeyboardKey.arrowUp) {
      unawaited(_player.setVolume((_volume + 5).clamp(0, 100)));
    } else if (key == LogicalKeyboardKey.arrowDown) {
      unawaited(_player.setVolume((_volume - 5).clamp(0, 100)));
    } else if (key == LogicalKeyboardKey.keyM) {
      unawaited(_toggleMute());
    } else if (key == LogicalKeyboardKey.keyF ||
        key == LogicalKeyboardKey.f11) {
      widget.onRequestFullscreen();
    } else if (key == LogicalKeyboardKey.keyN) {
      widget.onNext?.call();
    } else if (key == LogicalKeyboardKey.keyP) {
      widget.onPrevious?.call();
    } else if (key == LogicalKeyboardKey.bracketLeft) {
      unawaited(_player.setRate((_rate - 0.25).clamp(0.5, 2)));
    } else if (key == LogicalKeyboardKey.bracketRight) {
      unawaited(_player.setRate((_rate + 0.25).clamp(0.5, 2)));
    } else {
      final number = int.tryParse(event.character ?? '');
      if (number == null || number < 0 || number > 9) {
        return KeyEventResult.ignored;
      }
      final durationMs = _effectiveDuration.inMilliseconds;
      if (durationMs > 0) {
        unawaited(_seekTo(durationMs * number / 10));
      }
    }
    _showControls();
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _closing = true;
    WidgetsBinding.instance.removeObserver(this);
    _saveTimer?.cancel();
    _hideTimer?.cancel();
    _resumeTimer?.cancel();
    unawaited(_saveProgress(force: true));
    unawaited(WakelockPlus.disable());
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final duration = _effectiveDuration;
    final durationMs = duration.inMilliseconds.toDouble();
    final positionMs = _position.inMilliseconds
        .clamp(0, duration.inMilliseconds > 0 ? duration.inMilliseconds : 0)
        .toDouble();
    final bufferValue = duration.inMilliseconds <= 0
        ? 0.0
        : (_buffer.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);

    return Focus(
      autofocus: true,
      onKeyEvent: _handleKey,
      child: MouseRegion(
        onHover: (_) {
          _showControls();
          _scheduleControlsHide();
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggleControls,
          onDoubleTapDown: (details) => _doubleTapPosition = details.localPosition,
          onDoubleTap: () {
            final width = MediaQuery.sizeOf(context).width;
            final x = _doubleTapPosition?.dx ?? width / 2;
            if (x < width * 0.4) {
              unawaited(_seekRelative(const Duration(seconds: -10)));
            } else if (x > width * 0.6) {
              unawaited(_seekRelative(const Duration(seconds: 10)));
            } else {
              unawaited(_player.playOrPause());
            }
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              Center(
                child: AspectRatio(
                  aspectRatio: widget.item.aspectRatio == null ||
                          widget.item.aspectRatio! <= 0
                      ? 16 / 9
                      : widget.item.aspectRatio!,
                  child: Video(
                    controller: _controller,
                    controls: NoVideoControls,
                    wakelock: false,
                  ),
                ),
              ),
              if (!_ready)
                const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: Colors.white),
                      SizedBox(height: 12),
                      Text('正在准备视频…', style: TextStyle(color: Colors.white)),
                    ],
                  ),
                ),
              if (_buffering && _ready && _error == null)
                const Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Color(0x88000000),
                      shape: BoxShape.circle,
                    ),
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
                  ),
                ),
              if (_error != null) _buildError(),
              if (_showResumePrompt && _error == null) _buildResumePrompt(),
              IgnorePointer(
                ignoring: !_controlsVisible,
                child: AnimatedOpacity(
                  opacity: _controlsVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: _buildControls(
                    durationMs: durationMs,
                    positionMs: positionMs,
                    bufferValue: bufferValue,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildControls({
    required double durationMs,
    required double positionMs,
    required double bufferValue,
  }) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x22000000), Colors.transparent, Color(0xCC000000)],
              stops: [0, 0.58, 1],
            ),
          ),
        ),
        Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _RoundControlButton(
                tooltip: '后退 10 秒',
                icon: LucideIcons.rotateCcw,
                onPressed: () => unawaited(
                  _seekRelative(const Duration(seconds: -10)),
                ),
              ),
              const SizedBox(width: 16),
              _RoundControlButton(
                tooltip: _playing ? '暂停' : '播放',
                icon: _playing ? LucideIcons.pause : LucideIcons.play,
                prominent: true,
                onPressed: () => unawaited(_player.playOrPause()),
              ),
              const SizedBox(width: 16),
              _RoundControlButton(
                tooltip: '前进 10 秒',
                icon: LucideIcons.rotateCw,
                onPressed: () => unawaited(
                  _seekRelative(const Duration(seconds: 10)),
                ),
              ),
            ],
          ),
        ),
        Positioned(
          left: 20,
          right: 20,
          bottom: 14,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                alignment: Alignment.center,
                children: [
                  LinearProgressIndicator(
                    value: bufferValue,
                    minHeight: 3,
                    color: Colors.white30,
                    backgroundColor: Colors.white12,
                  ),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      activeTrackColor: Colors.white,
                      inactiveTrackColor: Colors.transparent,
                      thumbColor: Colors.white,
                      overlayColor: Colors.white24,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                    ),
                    child: Slider(
                      value: durationMs <= 0 ? 0 : positionMs.clamp(0, durationMs),
                      max: durationMs <= 0 ? 1 : durationMs,
                      onChangeStart: (_) => _showControls(),
                      onChanged: durationMs <= 0
                          ? null
                          : (value) => setState(
                                () => _position = Duration(milliseconds: value.round()),
                              ),
                      onChangeEnd: durationMs <= 0 ? null : _seekTo,
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  IconButton(
                    tooltip: _playing ? '暂停' : '播放',
                    onPressed: () => unawaited(_player.playOrPause()),
                    color: Colors.white,
                    icon: Icon(_playing ? LucideIcons.pause : LucideIcons.play),
                  ),
                  IconButton(
                    tooltip: _volume <= 0 ? '取消静音' : '静音',
                    onPressed: () => unawaited(_toggleMute()),
                    color: Colors.white,
                    icon: Icon(
                      _volume <= 0 ? LucideIcons.volumeX : LucideIcons.volume2,
                    ),
                  ),
                  SizedBox(
                    width: 90,
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 2,
                        activeTrackColor: Colors.white,
                        inactiveTrackColor: Colors.white24,
                        thumbColor: Colors.white,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                      ),
                      child: Slider(
                        value: _volume.clamp(0, 100),
                        max: 100,
                        onChanged: (value) => unawaited(_player.setVolume(value)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${_formatDuration(_position)} / ${_formatDuration(_effectiveDuration)}',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                  const Spacer(),
                  PopupMenuButton<double>(
                    tooltip: '播放速度',
                    initialValue: _rate,
                    color: const Color(0xFF202124),
                    onSelected: (value) => unawaited(_player.setRate(value)),
                    itemBuilder: (context) => [
                      for (final value in const [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0])
                        PopupMenuItem(
                          value: value,
                          child: Text(
                            '${value.toStringAsFixed(value == value.roundToDouble() ? 0 : 2)}×',
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      child: Text(
                        '${_rate.toStringAsFixed(_rate == _rate.roundToDouble() ? 0 : 2)}×',
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '全屏',
                    onPressed: widget.onRequestFullscreen,
                    color: Colors.white,
                    icon: const Icon(LucideIcons.maximize),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildResumePrompt() {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 360),
        margin: const EdgeInsets.all(24),
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          color: const Color(0xE61A1B1E),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(LucideIcons.history, color: Colors.white, size: 28),
            const SizedBox(height: 12),
            const Text(
              '继续上次播放？',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '上次播放到 ${_formatDuration(_resumePosition)}，5 秒后自动继续。',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => unawaited(_restartPlayback()),
                    style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
                    child: const Text('从头播放'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: () => unawaited(_continuePlayback()),
                    child: const Text('继续播放'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 440),
        margin: const EdgeInsets.all(24),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: const Color(0xEE191A1D),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(LucideIcons.circleAlert, color: Colors.white, size: 32),
            const SizedBox(height: 12),
            const Text(
              '无法播放此视频',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _readablePlaybackError(_error),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: () => unawaited(_retry()),
              icon: const Icon(LucideIcons.refreshCw, size: 17),
              label: const Text('重新尝试'),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundControlButton extends StatelessWidget {
  const _RoundControlButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.prominent = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: prominent ? Colors.white : Colors.black54,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: SizedBox.square(
            dimension: prominent ? 62 : 48,
            child: Icon(
              icon,
              color: prominent ? Colors.black : Colors.white,
              size: prominent ? 28 : 22,
            ),
          ),
        ),
      ),
    );
  }
}

String _formatDuration(Duration value) {
  final total = value.inSeconds.clamp(0, 1 << 31);
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  String two(int number) => number.toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${two(minutes)}:${two(seconds)}'
      : '${two(minutes)}:${two(seconds)}';
}

String _readablePlaybackError(Object? error) {
  final text = error?.toString().trim() ?? '未知播放错误';
  final lower = text.toLowerCase();
  if (lower.contains('401') || lower.contains('403')) {
    return '连接令牌已经失效，请返回连接设置重新配对。';
  }
  if (lower.contains('404')) return '视频文件可能已经移动或删除。';
  if (lower.contains('timeout') || lower.contains('超时')) {
    return '局域网连接超时，请检查服务器和无线网络。';
  }
  if (lower.contains('codec') || lower.contains('decode')) {
    return '当前设备可能不支持该视频编码。';
  }
  return text.length > 260 ? '${text.substring(0, 260)}…' : text;
}