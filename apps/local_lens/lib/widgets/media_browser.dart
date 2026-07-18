import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/api_client.dart';
import '../screens/image_viewer_screen.dart';
import '../screens/video_viewer_screen.dart';
import 'media_manage_sheet.dart';
import 'media_tile.dart';

class MediaBrowser extends StatefulWidget {
  const MediaBrowser({
    required this.api,
    this.libraryId,
    this.folder,
    this.recursive = false,
    this.albumId,
    this.tagId,
    this.type,
    this.search,
    this.favorite = false,
    this.minRating = 0,
    this.sort = 'timeline',
    this.groupByDate = false,
    this.emptyLabel = '没有找到媒体文件',
    this.header,
    super.key,
  });

  final ApiClient api;
  final String? libraryId;
  final String? folder;
  final bool recursive;
  final String? albumId;
  final String? tagId;
  final String? type;
  final String? search;
  final bool favorite;
  final int minRating;
  final String sort;
  final bool groupByDate;
  final String emptyLabel;
  final Widget? header;

  @override
  State<MediaBrowser> createState() => MediaBrowserState();
}

class MediaBrowserState extends State<MediaBrowser> {
  static const _pageSize = 100;
  final _scrollController = ScrollController();
  final _items = <MediaItem>[];
  final _favoritePending = <String>{};
  bool _loading = true;
  bool _loadingMore = false;
  Object? _error;
  int _total = 0;
  String? _nextCursor;
  bool _hasMore = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
    unawaited(refresh());
  }

  @override
  void didUpdateWidget(covariant MediaBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_querySignature(oldWidget) != _querySignature(widget)) {
      unawaited(refresh());
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    final generation = ++_generation;
    if (mounted) {
      setState(() {
        _loading = true;
        _loadingMore = false;
        _error = null;
        _nextCursor = null;
        _hasMore = false;
      });
    }
    try {
      final page = await _fetchPage();
      if (!mounted || generation != _generation) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page.items);
        _total = page.total;
        _nextCursor = page.nextCursor;
        _hasMore = page.hasMore;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = error;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore) return;
    final generation = _generation;
    setState(() => _loadingMore = true);
    try {
      final page = await _fetchPage(cursor: _nextCursor, offset: _items.length);
      if (!mounted || generation != _generation) return;
      final existing = _items.map((item) => item.id).toSet();
      setState(() {
        _items.addAll(page.items.where((item) => existing.add(item.id)));
        _total = page.total;
        _nextCursor = page.nextCursor;
        _hasMore = page.hasMore;
        _loadingMore = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loadingMore = false;
        _error = error;
      });
    }
  }

  Future<MediaPage> _fetchPage({String? cursor, int offset = 0}) {
    return widget.api.listMedia(
      libraryId: widget.libraryId,
      folder: widget.folder,
      recursive: widget.recursive,
      albumId: widget.albumId,
      tagId: widget.tagId,
      type: widget.type,
      search: widget.search,
      favorite: widget.favorite,
      minRating: widget.minRating,
      sort: widget.sort,
      limit: _pageSize,
      offset: offset,
      cursor: cursor,
    );
  }

  void _handleScroll() {
    if (_scrollController.hasClients &&
        _scrollController.position.extentAfter < 1000) {
      unawaited(_loadMore());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _items.isEmpty) {
      return Column(
        children: [
          if (widget.header != null) widget.header!,
          const Expanded(child: Center(child: CircularProgressIndicator())),
        ],
      );
    }
    if (_error != null && _items.isEmpty) {
      return Column(
        children: [
          if (widget.header != null) widget.header!,
          Expanded(
            child: _ErrorState(error: _error, onRetry: refresh),
          ),
        ],
      );
    }

    return RefreshIndicator(
      onRefresh: refresh,
      child: CustomScrollView(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          if (widget.header != null) SliverToBoxAdapter(child: widget.header),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                '已加载 ${_items.length} / $_total',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
          if (_items.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: Text(widget.emptyLabel)),
            )
          else if (widget.groupByDate)
            ..._buildDateSections()
          else
            _buildGrid(_items),
          SliverToBoxAdapter(child: _buildFooter()),
        ],
      ),
    );
  }

  List<Widget> _buildDateSections() {
    final groups = <String, List<MediaItem>>{};
    for (final item in _items) {
      groups.putIfAbsent(_dateKey(item.capturedAt), () => []).add(item);
    }
    return [
      for (final entry in groups.entries) ...[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
            child: Row(
              children: [
                Text(
                  entry.key,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(width: 8),
                Text(
                  '${entry.value.length} 项',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        _buildGrid(entry.value),
      ],
    ];
  }

  Widget _buildGrid(List<MediaItem> items) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 230,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
          childAspectRatio: 1,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) => _tile(items[index]),
          childCount: items.length,
        ),
      ),
    );
  }

  Widget _tile(MediaItem item) {
    return MediaTile(
      key: ValueKey(item.id),
      item: item,
      imageUrl: widget.api.resolve(item.thumbnailUrl).toString(),
      headers: widget.api.authorizationHeaders,
      favoritePending: _favoritePending.contains(item.id),
      onTap: () => _open(item),
      onFavoriteToggle: () => _toggleFavorite(item),
      onManage: () => MediaManageSheet.show(
        context,
        api: widget.api,
        item: item,
        onUpdated: _replaceItem,
      ),
    );
  }

  Widget _buildFooter() {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null && _items.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: OutlinedButton.icon(
            onPressed: _loadMore,
            icon: const Icon(Icons.refresh),
            label: Text('加载更多失败：$_error'),
          ),
        ),
      );
    }
    if (_hasMore) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: OutlinedButton.icon(
            onPressed: _loadMore,
            icon: const Icon(Icons.expand_more),
            label: const Text('加载更多'),
          ),
        ),
      );
    }
    return const SizedBox(height: 24);
  }

  Future<void> _toggleFavorite(MediaItem item) async {
    if (_favoritePending.contains(item.id)) return;
    setState(() => _favoritePending.add(item.id));
    try {
      final updated = await widget.api.setFavorite(item.id, !item.favorite);
      if (!mounted) return;
      if (widget.favorite && !updated.favorite) {
        setState(() {
          _items.removeWhere((value) => value.id == updated.id);
          _total = (_total - 1).clamp(0, 1 << 31);
          _favoritePending.remove(item.id);
        });
      } else {
        _replaceItem(updated);
        setState(() => _favoritePending.remove(item.id));
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _favoritePending.remove(item.id));
      _showError(error);
    }
  }

  void _replaceItem(MediaItem updated) {
    final index = _items.indexWhere((item) => item.id == updated.id);
    if (index < 0 || !mounted) return;
    setState(() => _items[index] = updated);
  }

  void _open(MediaItem item) {
    final route = item.isVideo
        ? MaterialPageRoute<void>(
            builder: (_) => VideoViewerScreen(
              item: item,
              url: widget.api.resolve(item.streamUrl).toString(),
              headers: widget.api.authorizationHeaders,
              api: widget.api,
            ),
          )
        : MaterialPageRoute<void>(
            builder: (_) => ImageViewerScreen(
              item: item,
              url: widget.api.resolve(item.originalUrl).toString(),
              headers: widget.api.authorizationHeaders,
            ),
          );
    Navigator.of(context).push(route);
  }

  void _showError(Object error) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error.toString())),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.error, required this.onRetry});

  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 56),
            const SizedBox(height: 12),
            Text(error.toString(), textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

String _dateKey(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year} 年 ${two(local.month)} 月 ${two(local.day)} 日';
}

String _querySignature(MediaBrowser widget) => [
      widget.libraryId,
      widget.folder,
      widget.recursive,
      widget.albumId,
      widget.tagId,
      widget.type,
      widget.search,
      widget.favorite,
      widget.minRating,
      widget.sort,
    ].join('|');
