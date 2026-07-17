import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../models/server_settings.dart';
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
  late final ApiClient _api = ApiClient(widget.settings);
  final _searchController = TextEditingController();
  String _type = 'all';
  late Future<MediaPage> _pageFuture;

  @override
  void initState() {
    super.initState();
    _pageFuture = _loadPage();
  }

  @override
  void dispose() {
    _api.close();
    _searchController.dispose();
    super.dispose();
  }

  Future<MediaPage> _loadPage() {
    return _api.listMedia(
      type: _type == 'all' ? null : _type,
      search: _searchController.text,
      limit: 200,
    );
  }

  void _reload() {
    setState(() => _pageFuture = _loadPage());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('LocalLens'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'disconnect') widget.onDisconnect();
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'disconnect', child: Text('断开服务器')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 420,
                  child: SearchBar(
                    controller: _searchController,
                    hintText: '搜索文件名',
                    leading: const Icon(Icons.search),
                    onSubmitted: (_) => _reload(),
                  ),
                ),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'all', label: Text('全部')),
                    ButtonSegment(value: 'image', icon: Icon(Icons.image_outlined)),
                    ButtonSegment(value: 'video', icon: Icon(Icons.movie_outlined)),
                  ],
                  selected: <String>{_type},
                  onSelectionChanged: (selection) {
                    setState(() => _type = selection.first);
                    _reload();
                  },
                ),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder<MediaPage>(
              future: _pageFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return _ErrorState(error: snapshot.error, onRetry: _reload);
                }
                final page = snapshot.data!;
                if (page.items.isEmpty) {
                  return const Center(child: Text('没有找到媒体文件'));
                }
                return LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth;
                    final columns = width >= 1400
                        ? 7
                        : width >= 1000
                            ? 5
                            : width >= 700
                                ? 4
                                : 3;
                    return GridView.builder(
                      padding: const EdgeInsets.all(12),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                        childAspectRatio: 1,
                      ),
                      itemCount: page.items.length,
                      itemBuilder: (context, index) {
                        final item = page.items[index];
                        return MediaTile(
                          item: item,
                          imageUrl: _api.resolve(item.thumbnailUrl).toString(),
                          headers: _api.authorizationHeaders,
                          onTap: () => _open(item),
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
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
