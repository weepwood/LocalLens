import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../models/media_item.dart';
import '../../models/playback_manifest.dart';
import '../../services/api_client.dart';
import '../../services/playback_api.dart';

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
  Timer? _manifestTimer;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffer = Duration.zero;
  Duration _resumePosition = Duration.zero;

  PlaybackManifest? _manifest;
  int _selectedHeight = 0;
  double _prepareProgress = 0;
  bool _preparingPlayback = true;
  bool _switchingQuality = false;
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
        if (value.trim().isEmpty || !mounted || _preparingPlayback) return;
        setState(() => _error = _readablePlaybackError(value));
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
    unawaited(_initialize());
  }

  @override
  void didUpdateWidget(covariant VideoViewerSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id) {
      _manifestTimer?.cancel();
      _resumeTimer?.cancel();
      _manifest = null;
      _selectedHeight = 0;
      _position = Duration.zero;
      _duration = Duration.zero;
      _buffer = Duration.zero;
      _restored = false;
      _showResumePrompt = false;
      _error = null;
      _ready = false;
      _preparingPlayback = true;
      unawaited(_player.stop().then((_) => _initialize()));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_saveProgress(force: true));
    }
  }

  Future<void> _initialize() async {
    try {
      final progress = await widget.api.getPlaybackProgress(widget.item.id);
      if (!mounted) return;
      _resumePosition = Duration(milliseconds: progress.positionMs);
      await _negotiate(
        initial: true,
        progress: progress,
        preferredHeight: null,
        forceTranscode: false,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _preparingPlayback = false;
        _ready = true;
        _error = _readablePlaybackError(error);
      });
    }
  }

  Future<void> _negotiate({
    required bool initial,
    PlaybackProgress? progress,
    required int? preferredHeight,
    required bool forceTranscode,
    Duration? resumeAt,
    bool resumePlaying = false,
  }) async {
    _manifestTimer?.cancel();
    if (mounted) {
      setState(() {
        _error = null;
        _preparingPlayback = true;
        _prepareProgress = 0;
        _switchingQuality = !initial;
      });
    }
    try {
      final manifest = await widget.api.requestPlaybackManifest(
        widget.item.id,
        preferredHeight: preferredHeight,
        forceTranscode: forceTranscode,
      );
      if (!mounted) return;
      if (manifest.preparing) {
        setState(() {
          _prepareProgress = manifest.progress.clamp(0, 1).toDouble();
          _manifest = manifest;
        });
        final retryAfter = manifest.retryAfter.clamp(1, 10);
        _manifestTimer = Timer(Duration(seconds: retryAfter), () {
          unawaited(_negotiate(
            initial: initial,
            progress: progress,
            preferredHeight: preferredHeight,
            forceTranscode: forceTranscode,
            resumeAt: resumeAt,
            resumePlaying: resumePlaying,
          ));
        });
        return;
      }
      if (manifest.failed || !manifest.ready) {
        throw ApiException(
          manifest.error.isEmpty ? '服务器无法准备该视频' : manifest.error,
        );
      }
      await _openManifest(
        manifest,
        initial: initial,
        progress: progress,
        resumeAt: resumeAt,
        resumePlaying: resumePlaying,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _preparingPlayback = false;
        _switchingQuality = false;
        _ready = true;
        _error = _readablePlaybackError(error);
      });
      _showControls();
    }
  }

  Future<void> _openManifest(
    PlaybackManifest manifest, {
    required bool initial,
    PlaybackProgress? progress,
    Duration? resumeAt,
    bool resumePlaying = false,
  }) async {
    final resolved = widget.api.resolve(manifest.url).toString();
    await _player.open(
      Media(resolved, httpHeaders: widget.headers),
      play: false,
    );
    if (!mounted) return;
    setState(() {
      _manifest = manifest;
      _preparingPlayback = false;
      _switchingQuality = false;
      _ready = true;
      _error = null;
    });

    if (!initial) {
      final target = resumeAt ?? Duration.zero;
      if (target > Duration.zero) await _player.seek(target);
      if (resumePlaying) await _player.play();
      return;
    }

    final saved = progress ??
        PlaybackProgress(
          deviceId: '',
          mediaId: widget.item.id,
          positionMs: 0,
          durationMs: widget.item.durationMs,
          completed: false,
          updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
        );
    final knownDuration = saved.durationMs > 0
        ? saved.durationMs
        : widget.item.durationMs;
    final remaining = knownDuration - saved.positionMs;
    final shouldPrompt = saved.positionMs >= 10000 &&
        !saved.completed &&
        (knownDuration <= 0 || remaining > 30000);
    setState(() {
      _restored = true;
      _resumePosition = Duration(milliseconds: saved.positionMs);
      _showResumePrompt = shouldPrompt;
    });
    if (shouldPrompt) {
      _resumeTimer = Timer(const Duration(seconds: 5), _continuePlayback);
    } else {
      await _player.play();
    }
  }

  Future<void> _changeQuality(int height) async {
    if (_selectedHeight == height || _preparingPlayback) return;
    final wasPlaying = _playing;
    final resumeAt = _position;
    await _saveProgress(force: true);
    _selectedHeight = height;
    await _negotiate(
      initial: false,
      preferredHeight: height == 0 ? null : height,
      forceTranscode: height != 0,
      resumeAt: resumeAt,
      resumePlaying: wasPlaying,
    );
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
    final resumeAt = _position;
    final resumePlaying = _playing;
    await _player.stop();
    await _negotiate(
      initial: !_restored,
      preferredHeight: _selectedHeight == 0 ? null : _selectedHeight,
      forceTranscode: _selectedHeight != 0,
      resumeAt: resumeAt,
      resumePlaying: resumePlaying,
    );
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
    if (!_playing ||
        _showResumePrompt ||
        _error != null ||
        _preparingPlayback) {
      return;
    }
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
        .clamp(0, durationMs > 0 ? durationMs : 1 << 31)
        .toInt();
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
      await _player.setVolume(_lastAudibleVolume.clamp(5, 100).toDouble());
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
        : (durationMs * 0.02).round().clamp(10000, 60000).toInt();
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
      unawaited(_player.setVolume((_volume + 5).clamp(0, 100).toDouble()));
    } else if (key == LogicalKeyboardKey.arrowDown) {
      unawaited(_player.setVolume((_volume - 5).clamp(0, 100).toDouble()));
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
      unawaited(_player.setRate((_rate - 0.25).clamp(0.5, 2).toDouble()));
    } else if (key == LogicalKeyboardKey.bracketRight) {
      unawaited(_player.setRate((_rate + 0.25).clamp(0.5, 2).toDouble()));
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
    _manifestTimer?.cancel();
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
              if (_preparingPlayback) _buildPreparingState(),
              if (_buffering && _ready && _error == null && !_preparingPlayback)
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

  Widget _buildPreparingState() {
    final percent = (_prepareProgress * 100).round();
    final hasProgress = _manifest?.transcoded == true || _prepareProgress > 0;
    return ColoredBox(
      color: _switchingQuality ? const Color(0xAA000000) : Colors.black,
      child: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 380),
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
              const CircularProgressIndicator(color: Colors.white),
              const SizedBox(height: 16),
              Text(
                _switchingQuality ? '正在切换清晰度…' : '正在准备视频…',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                hasProgress
                    ? '服务器正在生成兼容版本 · $percent%'
                    : '正在检查原始视频与当前设备的兼容性',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
              if (hasProgress) ...[
                const SizedBox(height: 14),
                LinearProgressIndicator(
                  value: _prepareProgress <= 0 ? null : _prepareProgress,
                  minHeight: 4,
                  backgroundColor: Colors.white12,
                  color: Colors.white,
                ),
              ],
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
        if (!_preparingPlayback)
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
                      onChanged: durationMs <= 0 || _preparingPlayback
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
                    onPressed: _preparingPlayback
                        ? null
                        : () => unawaited(_player.playOrPause()),
                    color: Colors.white,
                    disabledColor: Colors.white38,
                    icon: Icon(_playing ? LucideIcons.pause : LucideIcons.play),
                  ),
                  IconButton(
                    tooltip: _volume <= 0 ? '取消静音' : '静音',
                    onPressed: _preparingPlayback
                        ? null
                        : () => unawaited(_toggleMute()),
                    color: Colors.white,
                    disabledColor: Colors.white38,
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
                        onChanged: _preparingPlayback
                            ? null
                            : (value) => unawaited(_player.setVolume(value)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${_formatDuration(_position)} / ${_formatDuration(_effectiveDuration)}',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                  const Spacer(),
                  if ((_manifest?.subtitles.length ?? 0) > 0)
                    PopupMenuButton<PlaybackSubtitle>(
                      tooltip: '已发现 ${_manifest!.subtitles.length} 个外挂字幕',
                      color: const Color(0xFF202124),
                      itemBuilder: (context) => [
                        for (final subtitle in _manifest!.subtitles)
                          PopupMenuItem<PlaybackSubtitle>(
                            value: subtitle,
                            enabled: false,
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.subtitles_outlined,
                                  color: Colors.white70,
                                  size: 18,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    '${subtitle.name} · ${subtitle.language}',
                                    style: const TextStyle(color: Colors.white70),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                        child: Icon(Icons.subtitles_outlined, color: Colors.white),
                      ),
                    ),
                  PopupMenuButton<int>(
                    tooltip: '播放清晰度',
                    initialValue: _selectedHeight,
                    color: const Color(0xFF202124),
                    onSelected: (value) => unawaited(_changeQuality(value)),
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 0, child: _QualityMenuText('自动 / 原始画质')),
                      PopupMenuItem(value: 1080, child: _QualityMenuText('1080p 兼容模式')),
                      PopupMenuItem(value: 720, child: _QualityMenuText('720p 兼容模式')),
                      PopupMenuItem(value: 480, child: _QualityMenuText('480p 兼容模式')),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.high_quality, color: Colors.white, size: 19),
                          const SizedBox(width: 5),
                          Text(
                            _manifest?.qualityLabel ?? '自动',
                            style: const TextStyle(color: Colors.white, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ),
                  PopupMenuButton<double>(
                    tooltip: '播放速度',
                    initialValue: _rate,
                    color: const Color(0xFF202124),
                    onSelected: (value) => unawaited(_player.setRate(value)),
                    itemBuilder: (context) => [
                      for (final value
                          in const [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0])
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
          color: const Color(0xF21A1B1E),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(LucideIcons.triangleAlert, color: Color(0xFFFFB45E), size: 34),
            const SizedBox(height: 14),
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
              _error ?? '未知错误',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, height: 1.45),
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              alignment: WrapAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: () => unawaited(_retry()),
                  icon: const Icon(LucideIcons.refreshCw, size: 18),
                  label: const Text('重试'),
                ),
                if (_selectedHeight == 0)
                  OutlinedButton.icon(
                    onPressed: () => unawaited(_changeQuality(720)),
                    style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
                    icon: const Icon(Icons.high_quality, size: 18),
                    label: const Text('使用 720p 兼容模式'),
                  ),
              ],
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
        color: prominent ? Colors.white : const Color(0x99000000),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox(
            width: prominent ? 68 : 52,
            height: prominent ? 68 : 52,
            child: Icon(
              icon,
              color: prominent ? Colors.black : Colors.white,
              size: prominent ? 32 : 24,
            ),
          ),
        ),
      ),
    );
  }
}

class _QualityMenuText extends StatelessWidget {
  const _QualityMenuText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(text, style: const TextStyle(color: Colors.white));
  }
}

String _formatDuration(Duration value) {
  final totalSeconds = value.inSeconds < 0 ? 0 : value.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }
  return '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}';
}

String _readablePlaybackError(Object error) {
  final value = error.toString().replaceFirst('ApiException: ', '').trim();
  final lower = value.toLowerCase();
  if (lower.contains('401') || lower.contains('403') || lower.contains('unauthorized')) {
    return '服务器连接令牌已失效，请重新配置服务器连接。';
  }
  if (lower.contains('404') || lower.contains('not found')) {
    return '视频文件已经移动、删除，或转码缓存尚未准备完成。';
  }
  if (lower.contains('ffmpeg is not configured') ||
      lower.contains('ffmpeg unavailable')) {
    return '该视频需要兼容转码，但服务端没有正确配置 FFmpeg。';
  }
  if (lower.contains('timeout') || lower.contains('超时')) {
    return '准备视频超时，请检查局域网连接和服务端转码任务。';
  }
  if (lower.contains('codec') || lower.contains('decode')) {
    return '当前设备无法直接解码该视频，可切换到兼容清晰度重试。';
  }
  return value.isEmpty ? '播放器遇到未知错误，请重试。' : value;
}
