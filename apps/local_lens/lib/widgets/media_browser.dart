import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:skeletonizer/skeletonizer.dart';

import '../models/media_item.dart';
import '../screens/image_viewer_screen.dart';
import '../screens/video_viewer_screen.dart';
import '../services/api_client.dart';
import 'app_components.dart';
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
  bool _compactGrid = false;
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
          const Expanded(child: _MediaSkeleton()),
        ],
      );
    }
    if (_error != null && _items.isEmpty) {
      return Column(
        children: [
          if (widget.header != null) widget.header!,
          Expanded(
            child: AppEmptyState(
              icon: LucideIcons.cloudOff,
              title: '无法加载媒体库',
              description: _readableError(_error),
              action: FilledButton.icon(
                onPressed: refresh,
                icon: const Icon(LucideIcons.refreshCw, size: 18),
                label: const Text('重新加载'),
              ),
            ),
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
          SliverToBoxAdapter(child: _buildOverview()),
          if (_items.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: AppEmptyState(
                title: widget.emptyLabel,
                description: '尝试切换媒体库、清空筛选条件，或在服务器页面重新扫描。',
                icon: LucideIcons.images,
                action: OutlinedButton.icon(
                  onPressed: refresh,
                  icon: const Icon(LucideIcons.refreshCw, size: 17),
                  label: const Text('刷新'),
                ),
              ),
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

  Widget _buildOverview() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 10),
      child: Row(
        children: [
          Text(
            '$_total 项媒体',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(width: 8),
          Text(
            '已加载 ${_items.length}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const Spacer(),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(
                value: false,
                icon: Icon(LucideIcons.layoutGrid, size: 17),
                tooltip: '舒适网格',
              ),
              ButtonSegment(
                value: true,
                icon: Icon(LucideIcons.grid3X3, size: 17),
                tooltip: '紧凑网格',
              ),
            ],
            selected: {_compactGrid},
            showSelectedIcon: false,
            onSelectionChanged: (value) {
              setState(() => _compactGrid = value.first);
            },
          ),
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
            padding: const EdgeInsets.fromLTRB(24, 18, 24, 10),
            child: Row(
              children: [
                Text(entry.key, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '${entry.value.length} 项',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(child: Divider(color: Theme.of(context).dividerColor)),
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
      padding: const EdgeInsets.fromLTRB(20, 2, 20, 14),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: _compactGrid ? 168 : 224,
          crossAxisSpacing: _compactGrid ? 5 : 8,
          mainAxisSpacing: _compactGrid ? 5 : 8,
          childAspectRatio: 1,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) => _tile(items[index]),
          childCount: items.length,
          addRepaintBoundaries: true,
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
        padding: EdgeInsets.fromLTRB(24, 12, 24, 32),
        child: Column(
          children: [
            LinearProgressIndicator(minHeight: 3),
            SizedBox(height: 10),
            Text('正在加载更多媒体…'),
          ],
        ),
      );
    }
    if (_error != null && _items.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 30),
        child: Center(
          child: OutlinedButton.icon(
            onPressed: _loadMore,
            icon: const Icon(LucideIcons.refreshCw, size: 17),
            label: const Text('加载更多失败，点击重试'),
          ),
        ),
      );
    }
    if (_hasMore) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 30),
        child: Center(
          child: OutlinedButton.icon(
            onPressed: _loadMore,
            icon: const Icon(LucideIcons.chevronDown, size: 17),
            label: const Text('加载更多'),
          ),
        ),
      );
    }
    return const SizedBox(height: 28);
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
      SnackBar(content: Text(_readableError(error))),
    );
  }
}

class _MediaSkeleton extends StatelessWidget {
  const _MediaSkeleton();

  @override
  Widget build(BuildContext context) {
    return Skeletonizer(
      enabled: true,
      child: GridView.builder(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 224,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
        ),
        itemCount: 24,
        itemBuilder: (context, index) => Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Container(
                width: 90,
                height: 10,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
            ),
          ),
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

String _readableError(Object? error) {
  final value = error?.toString().trim() ?? '未知错误';
  if (value.length <= 220) return value;
  return '${value.substring(0, 220)}…';
}
