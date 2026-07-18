import 'dart:async';

import 'package:flutter/material.dart';

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
      child: Material(
        clipBehavior: Clip.antiAlias,
        borderRadius: BorderRadius.circular(12),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
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
                filterQuality: FilterQuality.low,
                loadingBuilder: (context, child, progress) {
                  if (progress == null) return child;
                  final total = progress.expectedTotalBytes;
                  final value = total == null || total == 0
                      ? null
                      : progress.cumulativeBytesLoaded / total;
                  return Center(
                    child: SizedBox.square(
                      dimension: 28,
                      child: CircularProgressIndicator(
                        value: value,
                        strokeWidth: 2,
                      ),
                    ),
                  );
                },
                errorBuilder: (context, error, stackTrace) {
                  _scheduleRetry();
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          widget.item.metadataStatus == 'pending'
                              ? Icons.hourglass_top_rounded
                              : Icons.broken_image_outlined,
                          size: 34,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _retry < 4 ? '正在生成缩略图' : '缩略图不可用',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  );
                },
              ),
              Positioned(
                top: 8,
                left: 8,
                child: Material(
                  color: Colors.black.withValues(alpha: 0.68),
                  shape: const CircleBorder(),
                  child: IconButton(
                    tooltip: widget.item.favorite ? '取消收藏' : '收藏',
                    onPressed: widget.favoritePending
                        ? null
                        : widget.onFavoriteToggle,
                    visualDensity: VisualDensity.compact,
                    iconSize: 19,
                    color: Colors.white,
                    disabledColor: Colors.white54,
                    icon: widget.favoritePending
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Icon(
                            widget.item.favorite
                                ? Icons.favorite_rounded
                                : Icons.favorite_border_rounded,
                          ),
                  ),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.item.rating > 0)
                      _Badge(
                        icon: Icons.star_rounded,
                        label: '${widget.item.rating}',
                      ),
                    if (widget.item.rating > 0) const SizedBox(width: 5),
                    _Badge(
                      icon: widget.item.isVideo
                          ? Icons.play_arrow_rounded
                          : Icons.image_outlined,
                      label: widget.item.isVideo && widget.item.durationMs > 0
                          ? _formatDuration(widget.item.durationMs)
                          : _formatBytes(widget.item.sizeBytes),
                    ),
                  ],
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Colors.black87],
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 30, 6, 7),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                widget.item.fileName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                _formatDate(widget.item.capturedAt),
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 10,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: '管理媒体',
                          onPressed: widget.onManage,
                          visualDensity: VisualDensity.compact,
                          color: Colors.white,
                          iconSize: 19,
                          icon: const Icon(Icons.more_horiz_rounded),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _scheduleRetry() {
    if (_retry >= 4 || _retryTimer != null) return;
    _retryTimer = Timer(Duration(seconds: 2 + _retry), () {
      _retryTimer = null;
      if (mounted) setState(() => _retry++);
    });
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.68),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: Colors.white),
            const SizedBox(width: 3),
            Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 10),
            ),
          ],
        ),
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
