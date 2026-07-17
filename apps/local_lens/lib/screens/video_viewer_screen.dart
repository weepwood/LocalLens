import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../models/media_item.dart';

class VideoViewerScreen extends StatefulWidget {
  const VideoViewerScreen({
    required this.item,
    required this.url,
    required this.headers,
    super.key,
  });

  final MediaItem item;
  final String url;
  final Map<String, String> headers;

  @override
  State<VideoViewerScreen> createState() => _VideoViewerScreenState();
}

class _VideoViewerScreenState extends State<VideoViewerScreen> {
  late final Player _player;
  late final VideoController _controller;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    _player.open(
      Media(widget.url, httpHeaders: widget.headers),
      play: true,
    );
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(widget.item.fileName),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Video(controller: _controller),
        ),
      ),
    );
  }
}
