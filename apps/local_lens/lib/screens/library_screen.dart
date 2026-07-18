import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../models/server_settings.dart';
import '../models/server_state.dart';
import '../services/api_client.dart';
import '../widgets/media_tile.dart';
import 'image_viewer_screen.dart';
import 'video_viewer_screen.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    required this.settings,
    required this.onDisconnect,
    super.key,
  });

  final ServerSettings settings;
  final Future<void> Function() onDisconnect;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  static const _pageSize = 100;

  late final ApiClient _api = ApiClient(widget.settings);
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();

  final List<MediaItem> _items = <MediaItem>[];
  List<LibraryInfo> _libraries = const <LibraryInfo>[];
  ScanStatus? _scanStatus;
  Object? _mediaError;
  Object? _serverStateError;
  Timer? _searchDebounce;
  Timer? _scanPollTimer;

  String _type = 'all';
  int _total = 0;
  int _requestGeneration = 0;
  bool _loadingInitial = true;
  bool _loadingMore = false;
  bool _startingScan = false;
  bool _pollingScan = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
    unawaited(_refreshAll());
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _scanPollTimer?.cancel();
    _scrollController.dispose();
    _searchController.dispose();
    _api.close();
    super.dispose();
  }

  Future<void> _refreshAll({bool showLoading = true}) async {
    await Future.wait<void>([
      _loadServerState(),
      _loadFirstPage(showLoading: showLoading),
    ]);
  }

  Future<void> _loadServerState() async {
    try {
      final libraries = await _api.listLibraries();
      final scanStatus = await _api.getScanStatus();
      if (!mounted) return;
      setState(() {
        _libraries = libraries;
        _scanStatus = scanStatus;
        _serverStateError = null;
      });
      _syncScanPolling(scanStatus);
    } catch (error) {
      if (!mounted) return;
      setState(() => _serverStateError = error);
    }
  }

  Future<void> _loadFirstPage({bool showLoading = true}) async {
    final generation = ++_requestGeneration;
    if (mounted && showLoading) {
      setState(() {
        _loadingInitial = true;
        _mediaError = null;
      });
    }

    try {
      final page = await _api.listMedia(
        type: _type == 'all' ? null : _type,
        search: _searchController.text,
        limit: _pageSize,
      );
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page.items);
        _total = page.total;
        _loadingInitial = false;
        _loadingMore = false;
        _mediaError = null;
      });
    } catch (error) {
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _loadingInitial = false;
        _loadingMore = false;
        _mediaError = error;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingInitial || _loadingMore || _items.length >= _total) return;
    final generation = _requestGeneration;
    setState(() => _loadingMore = true);

    try {
      final page = await _api.listMedia(
        type: _type == 'all' ? null : _type,
        search: _searchController.text,
        limit: _pageSize,
        offset: _items.length,
      );
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _items.addAll(page.items);
        _total = page.total;
        _loadingMore = false;
        _mediaError = null;
      });
    } catch (error) {
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _loadingMore = false;
        _mediaError = error;
      });
    }
  }

  void _handleScroll() {
    if (_scrollController.position.extentAfter < 900) {
      unawaited(_loadMore());
    }
  }

  void _handleSearchChanged(String value) {
    setState(() {});
    _searchDebounce?.cancel();
    _searchDebounce = Timer(
      const Duration(milliseconds: 420),
      () => unawaited(_loadFirstPage()),
    );
  }

  Future<void> _startScan() async {
    if (_startingScan || _scanStatus?.running == true) return;
    setState(() => _startingScan = true);
    try {
      final status = await _api.startScan();
      if (!mounted) return;
      setState(() {
        _scanStatus = status;
        _startingScan = false;
        _serverStateError = null;
      });
      _syncScanPolling(status);
    } catch (error) {
      if (!mounted) return;
      setState(() => _startingScan = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString())),
      );
    }
  }

  void _syncScanPolling(ScanStatus status) {
    _scanPollTimer?.cancel();
    if (!status.running) return;
    _scanPollTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_pollScanStatus()),
    );
  }

  Future<void> _pollScanStatus() async {
    if (_pollingScan) return;
    _pollingScan = true;
    try {
      final status = await _api.getScanStatus();
      if (!mounted) return;
      final completed = _scanStatus?.running == true && !status.running;
      setState(() {
        _scanStatus = status;
        _serverStateError = null;
      });
      if (completed) {
        _scanPollTimer?.cancel();
        await _refreshAll(showLoading: false);
      }
    } catch (error) {
      if (mounted) setState(() => _serverStateError = error);
    } finally {
      _pollingScan = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('LocalLens'),
        actions: [
          IconButton(
            tooltip: _scanStatus?.running == true ? '正在扫描' : '扫描媒体库',
            onPressed: _scanStatus?.running == true || _startingScan
                ? null
                : _startScan,
            icon: _scanStatus?.running == true || _startingScan
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.manage_search_outlined),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: () => unawaited(_refreshAll()),
            icon: const Icon(Icons.refresh),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'disconnect') {
                unawaited(widget.onDisconnect());
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'disconnect', child: Text('断开服务器')),
            ],
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loadingInitial && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_mediaError != null && _items.isEmpty) {
      return _ErrorState(
        error: _mediaError,
        onRetry: () => unawaited(_refreshAll()),
      );
    }

    return RefreshIndicator(
      onRefresh: () => _refreshAll(showLoading: false),
      child: CustomScrollView(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: _buildToolbar()),
          if (_scanStatus != null || _serverStateError != null)
            SliverToBoxAdapter(child: _buildServerStatus()),
          if (_items.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: Text('没有找到媒体文件')),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 230,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                  childAspectRatio: 1,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final item = _items[index];
                    return MediaTile(
                      item: item,
                      imageUrl: _api.resolve(item.thumbnailUrl).toString(),
                      headers: _api.authorizationHeaders,
                      onTap: () => _open(item),
                    );
                  },
                  childCount: _items.length,
                ),
              ),
            ),
          SliverToBoxAdapter(child: _buildFooter()),
        ],
      ),
    );
  }

  Widget _buildToolbar() {
    final enabledLibraries = _libraries.where((item) => item.enabled).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460, minWidth: 260),
                child: SearchBar(
                  controller: _searchController,
                  hintText: '搜索文件名',
                  leading: const Icon(Icons.search),
                  trailing: [
                    if (_searchController.text.isNotEmpty)
                      IconButton(
                        tooltip: '清空搜索',
                        onPressed: () {
                          _searchController.clear();
                          _handleSearchChanged('');
                        },
                        icon: const Icon(Icons.close),
                      ),
                  ],
                  onChanged: _handleSearchChanged,
                  onSubmitted: (_) => unawaited(_loadFirstPage()),
                ),
              ),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'all', label: Text('全部')),
                  ButtonSegment(
                    value: 'image',
                    label: Text('图片'),
                    icon: Icon(Icons.image_outlined),
                  ),
                  ButtonSegment(
                    value: 'video',
                    label: Text('视频'),
                    icon: Icon(Icons.movie_outlined),
                  ),
                ],
                selected: <String>{_type},
                onSelectionChanged: (selection) {
                  setState(() => _type = selection.first);
                  unawaited(_loadFirstPage());
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _MetricChip(
                icon: Icons.photo_library_outlined,
                label: '已加载 ${_items.length} / $_total',
              ),
              _MetricChip(
                icon: Icons.folder_outlined,
                label: '$enabledLibraries 个媒体库',
              ),
              ..._libraries.map(
                (library) => Tooltip(
                  message: _libraryTooltip(library),
                  child: Chip(
                    avatar: Icon(
                      library.enabled
                          ? Icons.folder_open_outlined
                          : Icons.folder_off_outlined,
                      size: 18,
                    ),
                    label: Text(library.name),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildServerStatus() {
    final status = _scanStatus;
    final error = _serverStateError;
    if (status == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Card(
          child: ListTile(
            leading: const Icon(Icons.cloud_off_outlined),
            title: const Text('无法读取服务器状态'),
            subtitle: Text(error.toString()),
            trailing: IconButton(
              onPressed: () => unawaited(_loadServerState()),
              icon: const Icon(Icons.refresh),
            ),
          ),
        ),
      );
    }

    if (!status.running && status.errorMessage == null) {
      return const SliverStatusSpacer();
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    status.running
                        ? Icons.sync
                        : Icons.error_outline,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      status.running
                          ? '正在扫描${status.current == null ? '' : '：${status.current}'}'
                          : '最近一次扫描失败',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  Text('已索引 ${status.indexed}'),
                ],
              ),
              const SizedBox(height: 10),
              if (status.running)
                LinearProgressIndicator(value: status.progress)
              else
                Text(status.errorMessage ?? error.toString()),
              const SizedBox(height: 8),
              Text(
                '发现 ${status.discovered} · 失败 ${status.failed}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
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
    if (_mediaError != null && _items.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: OutlinedButton.icon(
            onPressed: () => unawaited(_loadMore()),
            icon: const Icon(Icons.refresh),
            label: Text('加载更多失败：$_mediaError'),
          ),
        ),
      );
    }
    if (_items.length < _total) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: OutlinedButton.icon(
            onPressed: () => unawaited(_loadMore()),
            icon: const Icon(Icons.expand_more),
            label: const Text('加载更多'),
          ),
        ),
      );
    }
    if (_items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      child: Center(
        child: Text(
          '已加载全部 ${_items.length} 项',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }

  String _libraryTooltip(LibraryInfo library) {
    final scanTime = library.lastScannedAt;
    final scanned = scanTime == null ? '尚未扫描' : '上次扫描 ${_formatDateTime(scanTime)}';
    final mode = library.recursive ? '包含子目录' : '仅当前目录';
    return '$mode · $scanned';
  }

  void _open(MediaItem item) {
    final route = item.isVideo
        ? MaterialPageRoute<void>(
            builder: (_) => VideoViewerScreen(
              item: item,
              url: _api.resolve(item.streamUrl).toString(),
              headers: _api.authorizationHeaders,
            ),
          )
        : MaterialPageRoute<void>(
            builder: (_) => ImageViewerScreen(
              item: item,
              url: _api.resolve(item.originalUrl).toString(),
              headers: _api.authorizationHeaders,
            ),
          );
    Navigator.of(context).push(route);
  }
}

class SliverStatusSpacer extends StatelessWidget {
  const SliverStatusSpacer({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox(height: 4);
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(icon, size: 18),
      label: Text(label),
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

String _formatDateTime(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} '
      '${two(value.hour)}:${two(value.minute)}';
}
