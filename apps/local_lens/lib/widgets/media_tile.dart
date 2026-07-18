import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../models/media_item.dart';

class MediaTile extends StatefulWidget {
  const MediaTile({
    required this.item,
    required this.imageUrl,
    required this.headers,
    required this.onTap,
    required this.onFavoriteToggle,
    required this.onManage,
    this.favoritePending = false,
    super.key,
  });

  final MediaItem item;
  final String imageUrl;
  final Map<String, String> headers;
  final VoidCallback onTap;
  final VoidCallback onFavoriteToggle;
  final VoidCallback onManage;
  final bool favoritePending;

  @override
  State<MediaTile> createState() => _MediaTileState();
}

class _MediaTileState extends State<MediaTile> {
  int _retry = 0;
  Timer? _retryTimer;
  bool _hovered = false;

  @override
  void didUpdateWidget(covariant MediaTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _retry = 0;
      _retryTimer?.cancel();
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final imageUrl = widget.imageUrl.contains('?')
        ? '${widget.imageUrl}&clientRetry=$_retry'
        : '${widget.imageUrl}?clientRetry=$_retry';
    final mobile = MediaQuery.sizeOf(context).width < 760;
    final showActions = _hovered || mobile || widget.item.favorite;
    final scheme = Theme.of(context).colorScheme;

    return Tooltip(
      message: [
        widget.item.relativePath.isEmpty
            ? widget.item.fileName
            : widget.item.relativePath,
        '${_formatBytes(widget.item.sizeBytes)} · ${_formatDate(widget.item.capturedAt)}',
        if (widget.item.width > 0 && widget.item.height > 0)
          '${widget.item.width} × ${widget.item.height}',
        if (widget.item.codec.isNotEmpty) widget.item.codec,
      ].join('\n'),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _hovered
                  ? scheme.primary.withValues(alpha: 0.65)
                  : Theme.of(context).dividerColor,
            ),
            boxShadow: _hovered
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.14),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ]
                : const [],
          ),
          child: Material(
            clipBehavior: Clip.antiAlias,
            borderRadius: BorderRadius.circular(11),
            color: scheme.surfaceContainerHighest,
            child: InkWell(
              onTap: widget.onTap,
              onLongPress: widget.onManage,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.network(
                    imageUrl,
                    key: ValueKey(imageUrl),
                    headers: widget.headers,
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.medium,
                    loadingBuilder: (context, child, progress) {
                      if (progress == null) return child;
                      return _LoadingThumbnail(progress: progress);
                    },
                    errorBuilder: (context, error, stackTrace) {
                      _scheduleRetry();
                      return _ThumbnailError(
                        retry: _retry,
                        pending: widget.item.metadataStatus == 'pending',
                      );
                    },
                  ),
                  AnimatedOpacity(
                    duration: const Duration(milliseconds: 150),
                    opacity: _hovered ? 1 : 0,
                    child: const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x33000000), Colors.transparent, Color(0xB8000000)],
                          stops: [0, 0.48, 1],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 140),
                      opacity: showActions ? 1 : 0,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _GlassIconButton(
                            tooltip: widget.item.favorite ? '取消收藏' : '收藏',
                            onPressed: widget.favoritePending
                                ? null
                                : widget.onFavoriteToggle,
                            child: widget.favoritePending
                                ? const SizedBox.square(
                                    dimension: 15,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : Icon(
                                    LucideIcons.heart,
                                    size: 17,
                                    color: widget.item.favorite
                                        ? const Color(0xFFFF6B7A)
                                        : Colors.white,
                                  ),
                          ),
                          const SizedBox(width: 6),
                          _GlassIconButton(
                            tooltip: '管理媒体',
                            onPressed: widget.onManage,
                            child: const Icon(
                              LucideIcons.moreHorizontal,
                              size: 18,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (widget.item.isVideo || widget.item.rating > 0)
                    Positioned(
                      left: 8,
                      bottom: 8,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.item.isVideo)
                            _OverlayBadge(
                              icon: LucideIcons.play,
                              label: widget.item.durationMs > 0
                                  ? _formatDuration(widget.item.durationMs)
                                  : '视频',
                            ),
                          if (widget.item.isVideo && widget.item.rating > 0)
                            const SizedBox(width: 5),
                          if (widget.item.rating > 0)
                            _OverlayBadge(
                              icon: LucideIcons.star,
                              label: '${widget.item.rating}',
                            ),
                        ],
                      ),
                    ),
                  Positioned(
                    left: 10,
                    right: 10,
                    bottom: 10,
                    child: IgnorePointer(
                      child: AnimatedSlide(
                        duration: const Duration(milliseconds: 170),
                        offset: _hovered ? Offset.zero : const Offset(0, 0.35),
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 150),
                          opacity: _hovered ? 1 : 0,
                          child: Padding(
                            padding: EdgeInsets.only(
                              left: widget.item.isVideo || widget.item.rating > 0 ? 0 : 0,
                              bottom: widget.item.isVideo || widget.item.rating > 0 ? 30 : 0,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.item.fileName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    shadows: [Shadow(blurRadius: 8, color: Colors.black87)],
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${_formatDate(widget.item.capturedAt)} · ${_formatBytes(widget.item.sizeBytes)}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 10,
                                    shadows: [Shadow(blurRadius: 8, color: Colors.black87)],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _scheduleRetry() {
    if (_retry >= 5 || _retryTimer != null) return;
    _retryTimer = Timer(Duration(seconds: 2 + _retry), () {
      _retryTimer = null;
      if (mounted) setState(() => _retry++);
    });
  }
}

class _LoadingThumbnail extends StatelessWidget {
  const _LoadingThumbnail({required this.progress});

  final ImageChunkEvent progress;

  @override
  Widget build(BuildContext context) {
    final total = progress.expectedTotalBytes;
    final value = total == null || total == 0
        ? null
        : progress.cumulativeBytesLoaded / total;
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: LinearProgressIndicator(value: value, minHeight: 3),
        ),
      ],
    );
  }
}

class _ThumbnailError extends StatelessWidget {
  const _ThumbnailError({required this.retry, required this.pending});

  final int retry;
  final bool pending;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              pending ? LucideIcons.clock : LucideIcons.imageOff,
              size: 30,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 8),
            Text(
              retry < 5 ? '正在准备缩略图' : '缩略图暂不可用',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _GlassIconButton extends StatelessWidget {
  const _GlassIconButton({
    required this.tooltip,
    required this.onPressed,
    required this.child,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.black.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(9),
          child: SizedBox(width: 32, height: 32, child: Center(child: child)),
        ),
      ),
    );
  }
}

class _OverlayBadge extends StatelessWidget {
  const _OverlayBadge({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: Colors.white),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
  final gb = mb / 1024;
  return '${gb.toStringAsFixed(gb < 10 ? 1 : 0)} GB';
}

String _formatDate(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)}';
}

String _formatDuration(int milliseconds) {
  final duration = Duration(milliseconds: milliseconds);
  String two(int number) => number.toString().padLeft(2, '0');
  if (duration.inHours > 0) {
    return '${duration.inHours}:${two(duration.inMinutes.remainder(60))}:${two(duration.inSeconds.remainder(60))}';
  }
  return '${duration.inMinutes}:${two(duration.inSeconds.remainder(60))}';
}
