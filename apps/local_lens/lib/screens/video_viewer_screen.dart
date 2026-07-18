import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../models/media_item.dart';
import '../services/api_client.dart';

class VideoViewerScreen extends StatefulWidget {
  const VideoViewerScreen({
    required this.item,
    required this.url,
    required this.headers,
    required this.api,
    super.key,
  });

  final MediaItem item;
  final String url;
  final Map<String, String> headers;
  final ApiClient api;

  @override
  State<VideoViewerScreen> createState() => _VideoViewerScreenState();
}

class _VideoViewerScreenState extends State<VideoViewerScreen> {
  late final Player _player;
  late final VideoController _controller;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  Timer? _saveTimer;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _restored = false;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    _positionSubscription = _player.stream.position.listen((position) {
      _position = position;
    });
    _durationSubscription = _player.stream.duration.listen((duration) {
      _duration = duration;
    });
    _saveTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => unawaited(_saveProgress()),
    );
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      final progress = await widget.api.getPlaybackProgress(widget.item.id);
      await _player.open(
        Media(widget.url, httpHeaders: widget.headers),
        play: false,
      );
      if (progress.positionMs > 3000 && !progress.completed) {
        await _player.seek(Duration(milliseconds: progress.positionMs));
      }
      _restored = true;
      await _player.play();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('播放初始化失败：$error')),
      );
    }
  }

  @override
  void dispose() {
    _closing = true;
    _saveTimer?.cancel();
    unawaited(_saveProgress(force: true));
    unawaited(_positionSubscription?.cancel());
    unawaited(_durationSubscription?.cancel());
    _player.dispose();
    super.dispose();
  }

  Future<void> _saveProgress({bool force = false}) async {
    if (!_restored || (_closing && !force)) return;
    final durationMs = _duration.inMilliseconds > 0
        ? _duration.inMilliseconds
        : widget.item.durationMs;
    final positionMs = _position.inMilliseconds;
    if (!force && positionMs < 1000) return;
    final completed = durationMs > 0 && positionMs >= durationMs - 5000;
    try {
      await widget.api.savePlaybackProgress(
        widget.item.id,
        positionMs: completed ? 0 : positionMs,
        durationMs: durationMs,
        completed: completed,
      );
    } catch (_) {
      // 播放进度保存失败不应打断视频播放。
    }
  }

  @override
  Widget build(BuildContext context) {
    final ratio = widget.item.aspectRatio;
    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) unawaited(_saveProgress(force: true));
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          title: Text(widget.item.fileName),
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
        ),
        body: Center(
          child: AspectRatio(
            aspectRatio: ratio == null || ratio <= 0 ? 16 / 9 : ratio,
            child: Video(controller: _controller),
          ),
        ),
      ),
    );
  }
}
