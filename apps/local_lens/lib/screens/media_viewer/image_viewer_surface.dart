import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../models/media_item.dart';

class ImageViewerController {
  VoidCallback? _reset;
  VoidCallback? _zoomIn;
  VoidCallback? _zoomOut;
  VoidCallback? _rotateLeft;
  VoidCallback? _rotateRight;

  void reset() => _reset?.call();
  void zoomIn() => _zoomIn?.call();
  void zoomOut() => _zoomOut?.call();
  void rotateLeft() => _rotateLeft?.call();
  void rotateRight() => _rotateRight?.call();
}

class ImageViewerSurface extends StatefulWidget {
  const ImageViewerSurface({
    required this.item,
    required this.thumbnailUrl,
    required this.originalUrl,
    required this.headers,
    required this.controller,
    required this.onPrevious,
    required this.onNext,
    required this.onTap,
    required this.onScaleChanged,
    super.key,
  });

  final MediaItem item;
  final String thumbnailUrl;
  final String originalUrl;
  final Map<String, String> headers;
  final ImageViewerController controller;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback onTap;
  final ValueChanged<double> onScaleChanged;

  @override
  State<ImageViewerSurface> createState() => _ImageViewerSurfaceState();
}

class _ImageViewerSurfaceState extends State<ImageViewerSurface> {
  final TransformationController _transform = TransformationController();
  TapDownDetails? _doubleTapDetails;
  double _scale = 1;
  int _quarterTurns = 0;
  bool _originalReady = false;
  bool _originalFailed = false;

  @override
  void initState() {
    super.initState();
    _bindController();
  }

  @override
  void didUpdateWidget(covariant ImageViewerSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    _bindController();
    if (oldWidget.item.id != widget.item.id) {
      _transform.value = Matrix4.identity();
      _scale = 1;
      _quarterTurns = 0;
      _originalReady = false;
      _originalFailed = false;
      widget.onScaleChanged(1);
    }
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _bindController() {
    widget.controller._reset = _reset;
    widget.controller._zoomIn = () {
      _setScale((_scale * 1.35).clamp(0.5, 8).toDouble());
    };
    widget.controller._zoomOut = () {
      _setScale((_scale / 1.35).clamp(0.5, 8).toDouble());
    };
    widget.controller._rotateLeft = () {
      setState(() => _quarterTurns = (_quarterTurns + 3) % 4);
    };
    widget.controller._rotateRight = () {
      setState(() => _quarterTurns = (_quarterTurns + 1) % 4);
    };
  }

  void _reset() {
    _transform.value = Matrix4.identity();
    setState(() => _scale = 1);
    widget.onScaleChanged(1);
  }

  void _setScale(double scale) {
    _transform.value = Matrix4.identity()..scaleByDouble(scale, scale, 1, 1);
    setState(() => _scale = scale);
    widget.onScaleChanged(scale);
  }

  void _handleDoubleTap() {
    final next = _scale > 1.15 ? 1.0 : 2.5;
    if (next == 1) {
      _reset();
      return;
    }
    final position = _doubleTapDetails?.localPosition;
    if (position == null) {
      _setScale(next);
      return;
    }
    _transform.value = Matrix4.identity()
      ..translateByDouble(
        -position.dx * (next - 1),
        -position.dy * (next - 1),
        0,
        1,
      )
      ..scaleByDouble(next, next, 1, 1);
    setState(() => _scale = next);
    widget.onScaleChanged(next);
  }

  void _handleScroll(PointerScrollEvent event) {
    final factor = event.scrollDelta.dy < 0 ? 1.15 : 1 / 1.15;
    _setScale((_scale * factor).clamp(0.5, 8).toDouble());
  }

  @override
  Widget build(BuildContext context) {
    final view = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = math.min(4096, (view.width * dpr * 2.2).round());

    return Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) _handleScroll(event);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onDoubleTapDown: (details) => _doubleTapDetails = details,
        onDoubleTap: _handleDoubleTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            InteractiveViewer(
              transformationController: _transform,
              minScale: 0.5,
              maxScale: 8,
              boundaryMargin: const EdgeInsets.all(180),
              clipBehavior: Clip.none,
              onInteractionUpdate: (details) {
                final scale = _transform.value.getMaxScaleOnAxis();
                if ((scale - _scale).abs() > 0.01) {
                  _scale = scale;
                  widget.onScaleChanged(scale);
                }
              },
              onInteractionEnd: (details) {
                if (_scale > 1.04) return;
                final dx = details.velocity.pixelsPerSecond.dx;
                if (dx > 700) widget.onPrevious?.call();
                if (dx < -700) widget.onNext?.call();
              },
              child: Center(
                child: RotatedBox(
                  quarterTurns: _quarterTurns,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Image.network(
                        widget.thumbnailUrl,
                        headers: widget.headers,
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.medium,
                        errorBuilder: (context, error, stackTrace) =>
                            const SizedBox.shrink(),
                      ),
                      AnimatedOpacity(
                        duration: const Duration(milliseconds: 220),
                        opacity: _originalReady ? 1 : 0,
                        child: Image.network(
                          widget.originalUrl,
                          key: ValueKey(widget.originalUrl),
                          headers: widget.headers,
                          fit: BoxFit.contain,
                          filterQuality: FilterQuality.high,
                          cacheWidth: cacheWidth,
                          frameBuilder: (context, child, frame, synchronous) {
                            if ((frame != null || synchronous) && !_originalReady) {
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (mounted) setState(() => _originalReady = true);
                              });
                            }
                            return child;
                          },
                          errorBuilder: (context, error, stackTrace) {
                            if (!_originalFailed) {
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (mounted) setState(() => _originalFailed = true);
                              });
                            }
                            return const SizedBox.shrink();
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (!_originalReady && !_originalFailed)
              const Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: LinearProgressIndicator(
                  minHeight: 2,
                  backgroundColor: Colors.transparent,
                ),
              ),
            if (_originalFailed)
              Positioned(
                left: 24,
                right: 24,
                bottom: 24,
                child: Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.72),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                      child: Text(
                        '原图加载失败，当前显示缩略图',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
