import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:window_manager/window_manager.dart';

import '../../models/media_item.dart';
import '../../models/media_viewer_session.dart';
import '../../services/api_client.dart';
import 'image_viewer_surface.dart';
import 'video_viewer_surface.dart';

class MediaViewerScreen extends StatefulWidget {
  const MediaViewerScreen({
    required this.items,
    required this.initialIndex,
    required this.api,
    this.onItemUpdated,
    super.key,
  });

  final List<MediaItem> items;
  final int initialIndex;
  final ApiClient api;
  final ValueChanged<MediaItem>? onItemUpdated;

  @override
  State<MediaViewerScreen> createState() => _MediaViewerScreenState();
}

class _MediaViewerScreenState extends State<MediaViewerScreen> {
  late final MediaViewerSession _session;
  final ImageViewerController _imageController = ImageViewerController();
  final ScrollController _filmstripController = ScrollController();
  Timer? _controlsTimer;
  bool _controlsVisible = true;
  bool _infoVisible = false;
  bool _favoritePending = false;
  bool _isFullscreen = false;
  bool _mobileSystemUiHidden = false;
  double _imageScale = 1;

  MediaItem get _item => _session.current;

  @override
  void initState() {
    super.initState();
    _session = MediaViewerSession(
      items: widget.items,
      initialIndex: widget.initialIndex,
    )..addListener(_handleSessionChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_enterMobileImmersiveMode());
      unawaited(_preloadAroundCurrent());
      _scheduleControlsHide();
    });
  }

  @override
  void dispose() {
    _controlsTimer?.cancel();
    _session
      ..removeListener(_handleSessionChanged)
      ..dispose();
    _filmstripController.dispose();
    unawaited(_restoreViewerMode());
    super.dispose();
  }

  void _handleSessionChanged() {
    _imageScale = 1;
    if (mounted) setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollFilmstripToCurrent();
      unawaited(_preloadAroundCurrent());
    });
  }

  Future<void> _enterMobileImmersiveMode() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _mobileSystemUiHidden = true;
  }

  Future<void> _restoreViewerMode() async {
    if (_isFullscreen &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      await windowManager.setFullScreen(false);
    }
    if (_mobileSystemUiHidden && (Platform.isAndroid || Platform.isIOS)) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  Future<void> _toggleFullscreen() async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final next = !await windowManager.isFullScreen();
      await windowManager.setFullScreen(next);
      if (mounted) setState(() => _isFullscreen = next);
      return;
    }
    _mobileSystemUiHidden = !_mobileSystemUiHidden;
    await SystemChrome.setEnabledSystemUIMode(
      _mobileSystemUiHidden
          ? SystemUiMode.immersiveSticky
          : SystemUiMode.edgeToEdge,
    );
    if (mounted) setState(() => _isFullscreen = _mobileSystemUiHidden);
  }

  void _showControls() {
    _controlsTimer?.cancel();
    if (!_controlsVisible && mounted) setState(() => _controlsVisible = true);
    _scheduleControlsHide();
  }

  void _toggleControls() {
    _controlsTimer?.cancel();
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleControlsHide();
  }

  void _scheduleControlsHide() {
    _controlsTimer?.cancel();
    if (_infoVisible) return;
    _controlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _previous() {
    if (_session.movePrevious()) _showControls();
  }

  void _next() {
    if (_session.moveNext()) _showControls();
  }

  Future<void> _toggleFavorite() async {
    if (_favoritePending) return;
    setState(() => _favoritePending = true);
    try {
      final updated = await widget.api.setFavorite(_item.id, !_item.favorite);
      _session.replace(updated);
      widget.onItemUpdated?.call(updated);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('收藏状态更新失败：$error')),
      );
    } finally {
      if (mounted) setState(() => _favoritePending = false);
    }
  }

  Future<void> _setRating(int rating) async {
    try {
      final updated = await widget.api.setRating(_item.id, rating);
      _session.replace(updated);
      widget.onItemUpdated?.call(updated);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('评分更新失败：$error')),
      );
    }
  }

  Future<void> _preloadAroundCurrent() async {
    if (!mounted) return;
    final indexes = <int>{
      _session.index,
      _session.index - 1,
      _session.index + 1,
    }.where((index) => index >= 0 && index < _session.length);
    for (final index in indexes) {
      final item = _session.items[index];
      final thumbnail = NetworkImage(
        widget.api.resolve(item.thumbnailUrl).toString(),
        headers: widget.api.authorizationHeaders,
      );
      unawaited(precacheImage(thumbnail, context).catchError((_) {}));
      if (!item.isVideo && (index - _session.index).abs() <= 1) {
        final original = ResizeImage(
          NetworkImage(
            widget.api.resolve(item.originalUrl).toString(),
            headers: widget.api.authorizationHeaders,
          ),
          width: 1920,
        );
        unawaited(precacheImage(original, context).catchError((_) {}));
      }
    }
  }

  void _scrollFilmstripToCurrent() {
    if (!_filmstripController.hasClients) return;
    const itemExtent = 78.0;
    final viewport = _filmstripController.position.viewportDimension;
    final target = (_session.index * itemExtent - viewport / 2 + itemExtent / 2)
        .clamp(0.0, _filmstripController.position.maxScrollExtent);
    unawaited(
      _filmstripController.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      if (_isFullscreen) {
        unawaited(_toggleFullscreen());
      } else {
        Navigator.of(context).maybePop();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f11) {
      unawaited(_toggleFullscreen());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyI) {
      setState(() => _infoVisible = !_infoVisible);
      _showControls();
      return KeyEventResult.handled;
    }
    if (_item.isVideo) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.arrowLeft) {
      _previous();
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _next();
    } else if (key == LogicalKeyboardKey.add ||
        key == LogicalKeyboardKey.equal) {
      _imageController.zoomIn();
    } else if (key == LogicalKeyboardKey.minus) {
      _imageController.zoomOut();
    } else if (key == LogicalKeyboardKey.digit0) {
      _imageController.reset();
    } else if (key == LogicalKeyboardKey.keyR) {
      _imageController.rotateRight();
    } else if (key == LogicalKeyboardKey.keyF) {
      unawaited(_toggleFavorite());
    } else {
      return KeyEventResult.ignored;
    }
    _showControls();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;
    return PopScope(
      canPop: !_isFullscreen,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _isFullscreen) unawaited(_toggleFullscreen());
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          autofocus: true,
          onKeyEvent: _handleKey,
          child: MouseRegion(
            onHover: (_) => _showControls(),
            child: Stack(
              fit: StackFit.expand,
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: item.isVideo
                      ? VideoViewerSurface(
                          key: ValueKey('video:${item.id}'),
                          item: item,
                          url: widget.api.resolve(item.streamUrl).toString(),
                          headers: widget.api.authorizationHeaders,
                          api: widget.api,
                          onPrevious: _session.canMovePrevious ? _previous : null,
                          onNext: _session.canMoveNext ? _next : null,
                          onRequestFullscreen: () => unawaited(_toggleFullscreen()),
                          onControlsVisibilityChanged: (visible) {
                            if (mounted) setState(() => _controlsVisible = visible);
                          },
                        )
                      : ImageViewerSurface(
                          key: ValueKey('image:${item.id}'),
                          item: item,
                          thumbnailUrl: widget.api.resolve(item.thumbnailUrl).toString(),
                          originalUrl: widget.api.resolve(item.originalUrl).toString(),
                          headers: widget.api.authorizationHeaders,
                          controller: _imageController,
                          onPrevious: _session.canMovePrevious ? _previous : null,
                          onNext: _session.canMoveNext ? _next : null,
                          onTap: _toggleControls,
                          onScaleChanged: (scale) => _imageScale = scale,
                        ),
                ),
                if (!item.isVideo) ...[
                  _NavigationButton(
                    left: true,
                    visible: _controlsVisible && _session.canMovePrevious,
                    onPressed: _previous,
                  ),
                  _NavigationButton(
                    left: false,
                    visible: _controlsVisible && _session.canMoveNext,
                    onPressed: _next,
                  ),
                ],
                _buildTopBar(),
                if (!item.isVideo) _buildImageBottomBar(),
                _buildInfoPanel(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    final item = _item;
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: IgnorePointer(
        ignoring: !_controlsVisible,
        child: AnimatedSlide(
          duration: const Duration(milliseconds: 180),
          offset: _controlsVisible ? Offset.zero : const Offset(0, -1),
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 180),
            opacity: _controlsVisible ? 1 : 0,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xD9000000), Color(0x88000000), Colors.transparent],
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 12, 24),
                  child: Row(
                    children: [
                      _ViewerIconButton(
                        tooltip: '返回',
                        icon: LucideIcons.arrowLeft,
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              item.fileName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${_session.index + 1} / ${_session.length} · ${_formatResolution(item)}',
                              style: const TextStyle(color: Colors.white70, fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                      _ViewerIconButton(
                        tooltip: item.favorite ? '取消收藏' : '收藏',
                        icon: LucideIcons.heart,
                        color: item.favorite ? const Color(0xFFFF6B7A) : Colors.white,
                        loading: _favoritePending,
                        onPressed: () => unawaited(_toggleFavorite()),
                      ),
                      _ViewerIconButton(
                        tooltip: '媒体信息',
                        icon: LucideIcons.info,
                        selected: _infoVisible,
                        onPressed: () {
                          setState(() => _infoVisible = !_infoVisible);
                          _showControls();
                        },
                      ),
                      _ViewerIconButton(
                        tooltip: '切换全屏',
                        icon: _isFullscreen ? LucideIcons.minimize : LucideIcons.maximize,
                        onPressed: () => unawaited(_toggleFullscreen()),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildImageBottomBar() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        ignoring: !_controlsVisible,
        child: AnimatedSlide(
          duration: const Duration(milliseconds: 180),
          offset: _controlsVisible ? Offset.zero : const Offset(0, 1),
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 180),
            opacity: _controlsVisible ? 1 : 0,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Color(0xE6000000), Color(0x99000000), Colors.transparent],
                ),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 28, 14, 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _ViewerIconButton(
                            tooltip: '缩小',
                            icon: LucideIcons.zoomOut,
                            onPressed: _imageController.zoomOut,
                          ),
                          _ViewerIconButton(
                            tooltip: '适应窗口（0）',
                            icon: LucideIcons.scan,
                            onPressed: _imageController.reset,
                          ),
                          Container(
                            constraints: const BoxConstraints(minWidth: 58),
                            alignment: Alignment.center,
                            child: Text(
                              '${(_imageScale * 100).round()}%',
                              style: const TextStyle(color: Colors.white, fontSize: 12),
                            ),
                          ),
                          _ViewerIconButton(
                            tooltip: '放大',
                            icon: LucideIcons.zoomIn,
                            onPressed: _imageController.zoomIn,
                          ),
                          const SizedBox(width: 8),
                          _ViewerIconButton(
                            tooltip: '向左旋转',
                            icon: LucideIcons.rotateCcw,
                            onPressed: _imageController.rotateLeft,
                          ),
                          _ViewerIconButton(
                            tooltip: '向右旋转（R）',
                            icon: LucideIcons.rotateCw,
                            onPressed: _imageController.rotateRight,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 68,
                        child: ListView.builder(
                          controller: _filmstripController,
                          scrollDirection: Axis.horizontal,
                          itemCount: _session.length,
                          itemBuilder: (context, index) => _FilmstripItem(
                            item: _session.items[index],
                            selected: index == _session.index,
                            imageUrl: widget.api
                                .resolve(_session.items[index].thumbnailUrl)
                                .toString(),
                            headers: widget.api.authorizationHeaders,
                            onTap: () => _session.moveTo(index),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInfoPanel() {
    final width = math.min(380.0, MediaQuery.sizeOf(context).width * 0.9);
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      top: 0,
      bottom: 0,
      right: _infoVisible ? 0 : -width - 16,
      width: width,
      child: Material(
        color: const Color(0xF218191C),
        elevation: 18,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 10, 8, 10),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '媒体信息',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭信息面板',
                      onPressed: () => setState(() => _infoVisible = false),
                      color: Colors.white,
                      icon: const Icon(LucideIcons.x),
                    ),
                  ],
                ),
              ),
              const Divider(color: Colors.white12),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(18),
                  children: [
                    _InfoSection(
                      title: _item.fileName,
                      rows: [
                        _InfoRow('类型', _item.isVideo ? '视频' : '图片'),
                        _InfoRow('分辨率', _formatResolution(_item)),
                        _InfoRow('大小', _formatBytes(_item.sizeBytes)),
                        _InfoRow('格式', _item.mimeType),
                        if (_item.codec.isNotEmpty) _InfoRow('编码', _item.codec),
                      ],
                    ),
                    _InfoSection(
                      title: '拍摄信息',
                      rows: [
                        _InfoRow('拍摄时间', _formatDateTime(_item.capturedAt)),
                        _InfoRow('时间来源', _capturedSourceLabel(_item.capturedAtSource)),
                        if (_item.cameraModel.isNotEmpty)
                          _InfoRow('相机', _item.cameraModel),
                        if (_item.hasLocation)
                          _InfoRow(
                            '位置',
                            '${_item.latitude!.toStringAsFixed(5)}, ${_item.longitude!.toStringAsFixed(5)}',
                          ),
                      ],
                    ),
                    _InfoSection(
                      title: '文件位置',
                      rows: [
                        _InfoRow('目录', _item.folderPath.isEmpty ? '媒体库根目录' : _item.folderPath),
                        _InfoRow('相对路径', _item.relativePath),
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      '评分',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        for (var value = 1; value <= 5; value++)
                          IconButton(
                            tooltip: '$value 星',
                            onPressed: () => unawaited(
                              _setRating(_item.rating == value ? 0 : value),
                            ),
                            icon: Icon(
                              LucideIcons.star,
                              color: value <= _item.rating
                                  ? const Color(0xFFFFC857)
                                  : Colors.white30,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavigationButton extends StatelessWidget {
  const _NavigationButton({
    required this.left,
    required this.visible,
    required this.onPressed,
  });

  final bool left;
  final bool visible;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: left ? 18 : null,
      right: left ? null : 18,
      top: 0,
      bottom: 0,
      child: Center(
        child: IgnorePointer(
          ignoring: !visible,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 160),
            opacity: visible ? 1 : 0,
            child: Material(
              color: Colors.black54,
              shape: const CircleBorder(),
              child: IconButton(
                tooltip: left ? '上一项' : '下一项',
                onPressed: onPressed,
                color: Colors.white,
                icon: Icon(left ? LucideIcons.chevronLeft : LucideIcons.chevronRight),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ViewerIconButton extends StatelessWidget {
  const _ViewerIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.color = Colors.white,
    this.selected = false,
    this.loading = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final Color color;
  final bool selected;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: selected ? Colors.white24 : Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        child: IconButton(
          onPressed: loading ? null : onPressed,
          color: color,
          disabledColor: Colors.white54,
          icon: loading
              ? const SizedBox.square(
                  dimension: 17,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : Icon(icon, size: 20),
        ),
      ),
    );
  }
}

class _FilmstripItem extends StatelessWidget {
  const _FilmstripItem({
    required this.item,
    required this.selected,
    required this.imageUrl,
    required this.headers,
    required this.onTap,
  });

  final MediaItem item;
  final bool selected;
  final String imageUrl;
  final Map<String, String> headers;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 70,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: selected ? const Color(0xFF929BFF) : Colors.white24,
              width: selected ? 2 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.network(
                imageUrl,
                headers: headers,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.low,
                errorBuilder: (context, error, stackTrace) => const ColoredBox(
                  color: Color(0xFF25262A),
                  child: Icon(LucideIcons.imageOff, color: Colors.white38, size: 20),
                ),
              ),
              if (item.isVideo)
                const Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                    child: Padding(
                      padding: EdgeInsets.all(5),
                      child: Icon(LucideIcons.play, color: Colors.white, size: 14),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoSection extends StatelessWidget {
  const _InfoSection({required this.title, required this.rows});

  final String title;
  final List<_InfoRow> rows;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 72,
                    child: Text(
                      row.label,
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ),
                  Expanded(
                    child: SelectableText(
                      row.value,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _InfoRow {
  const _InfoRow(this.label, this.value);

  final String label;
  final String value;
}

String _formatResolution(MediaItem item) => item.width > 0 && item.height > 0
    ? '${item.width} × ${item.height}'
    : '分辨率未知';

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  return '${(mb / 1024).toStringAsFixed(2)} GB';
}

String _formatDateTime(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

String _capturedSourceLabel(String value) => switch (value) {
      'exif' => '图片 EXIF',
      'container' => '视频容器时间',
      _ => '文件修改时间',
    };