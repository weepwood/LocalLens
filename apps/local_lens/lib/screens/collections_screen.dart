import 'dart:async';

import 'package:flutter/material.dart';

import '../models/collections.dart';
import '../services/api_client.dart';
import '../widgets/media_browser.dart';

class CollectionsScreen extends StatefulWidget {
  const CollectionsScreen({required this.api, super.key});

  final ApiClient api;

  @override
  State<CollectionsScreen> createState() => _CollectionsScreenState();
}

class _CollectionsScreenState extends State<CollectionsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  List<AlbumInfo> _albums = const [];
  List<TagInfo> _tags = const [];
  String? _selectedAlbumId;
  String? _selectedTagId;
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging && mounted) setState(() {});
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait<Object>([
        widget.api.listAlbums(),
        widget.api.listTags(),
      ]);
      if (!mounted) return;
      setState(() {
        _albums = results[0] as List<AlbumInfo>;
        _tags = results[1] as List<TagInfo>;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: FilledButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh),
          label: Text('加载失败：$_error'),
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            children: [
              Expanded(
                child: TabBar(
                  controller: _tabController,
                  tabs: const [
                    Tab(icon: Icon(Icons.photo_album_outlined), text: '相册'),
                    Tab(icon: Icon(Icons.sell_outlined), text: '标签'),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: _tabController.index == 0
                    ? _createAlbum
                    : _createTag,
                icon: const Icon(Icons.add),
                label: Text(_tabController.index == 0 ? '新建相册' : '新建标签'),
              ),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildCollectionView(
                items: _albums
                    .map(
                      (item) => _CollectionEntry(
                        id: item.id,
                        name: item.name,
                        count: item.itemCount,
                        subtitle: item.description,
                      ),
                    )
                    .toList(),
                selectedId: _selectedAlbumId,
                onSelected: (id) => setState(() => _selectedAlbumId = id),
                onDelete: _deleteAlbum,
                album: true,
              ),
              _buildCollectionView(
                items: _tags
                    .map(
                      (item) => _CollectionEntry(
                        id: item.id,
                        name: item.name,
                        count: item.itemCount,
                        color: item.color,
                      ),
                    )
                    .toList(),
                selectedId: _selectedTagId,
                onSelected: (id) => setState(() => _selectedTagId = id),
                onDelete: _deleteTag,
                album: false,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCollectionView({
    required List<_CollectionEntry> items,
    required String? selectedId,
    required ValueChanged<String?> onSelected,
    required Future<void> Function(String) onDelete,
    required bool album,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final sidebar = _CollectionSidebar(
          items: items,
          selectedId: selectedId,
          emptyLabel: album ? '还没有相册' : '还没有标签',
          allLabel: album ? '全部相册入口' : '全部标签入口',
          onSelected: onSelected,
          onDelete: onDelete,
        );
        final selected = items.where((item) => item.id == selectedId).firstOrNull;
        final media = selectedId == null
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      album
                          ? Icons.photo_album_outlined
                          : Icons.sell_outlined,
                      size: 64,
                    ),
                    const SizedBox(height: 12),
                    Text(album ? '选择一个相册查看内容' : '选择一个标签查看内容'),
                  ],
                ),
              )
            : MediaBrowser(
                key: ValueKey('${album ? 'album' : 'tag'}:$selectedId'),
                api: widget.api,
                albumId: album ? selectedId : null,
                tagId: album ? null : selectedId,
                groupByDate: true,
                emptyLabel: album ? '这个相册还是空的' : '没有带此标签的媒体',
                header: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        selected?.name ?? '',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      if ((selected?.subtitle ?? '').isNotEmpty)
                        Text(
                          selected!.subtitle,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
              );
        if (constraints.maxWidth >= 850) {
          return Row(
            children: [
              SizedBox(width: 280, child: sidebar),
              const VerticalDivider(width: 1),
              Expanded(child: media),
            ],
          );
        }
        return Column(
          children: [
            SizedBox(height: 190, child: sidebar),
            const Divider(height: 1),
            Expanded(child: media),
          ],
        );
      },
    );
  }

  Future<void> _createAlbum() async {
    final name = await _askName('新建相册', '相册名称');
    if (name == null) return;
    try {
      final item = await widget.api.createAlbum(name);
      if (!mounted) return;
      setState(() {
        _albums = [item, ..._albums];
        _selectedAlbumId = item.id;
      });
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _createTag() async {
    final name = await _askName('新建标签', '标签名称');
    if (name == null) return;
    try {
      final item = await widget.api.createTag(name);
      if (!mounted) return;
      setState(() {
        _tags = [..._tags, item];
        _selectedTagId = item.id;
      });
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _deleteAlbum(String id) async {
    if (!await _confirmDelete('删除相册？', '只会删除虚拟相册，不会删除原始文件。')) return;
    try {
      await widget.api.deleteAlbum(id);
      if (!mounted) return;
      setState(() {
        _albums = _albums.where((item) => item.id != id).toList();
        if (_selectedAlbumId == id) _selectedAlbumId = null;
      });
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _deleteTag(String id) async {
    if (!await _confirmDelete('删除标签？', '媒体文件本身不会被删除。')) return;
    try {
      await widget.api.deleteTag(id);
      if (!mounted) return;
      setState(() {
        _tags = _tags.where((item) => item.id != id).toList();
        if (_selectedTagId == id) _selectedTagId = null;
      });
    } catch (error) {
      _showError(error);
    }
  }

  Future<String?> _askName(String title, String label) async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          autofocus: true,
          controller: controller,
          decoration: InputDecoration(labelText: label),
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) Navigator.pop(context, value.trim());
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.isNotEmpty) Navigator.pop(context, value);
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
    controller.dispose();
    return value;
  }

  Future<bool> _confirmDelete(String title, String content) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: Text(content),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('删除'),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _showError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error.toString())),
    );
  }
}

class _CollectionSidebar extends StatelessWidget {
  const _CollectionSidebar({
    required this.items,
    required this.selectedId,
    required this.emptyLabel,
    required this.allLabel,
    required this.onSelected,
    required this.onDelete,
  });

  final List<_CollectionEntry> items;
  final String? selectedId;
  final String emptyLabel;
  final String allLabel;
  final ValueChanged<String?> onSelected;
  final Future<void> Function(String) onDelete;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return Center(child: Text(emptyLabel));
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          ListTile(
            selected: selectedId == null,
            leading: const Icon(Icons.dashboard_outlined),
            title: Text(allLabel),
            onTap: () => onSelected(null),
          ),
          for (final item in items)
            ListTile(
              selected: selectedId == item.id,
              leading: item.color == null || item.color!.isEmpty
                  ? const Icon(Icons.folder_outlined)
                  : CircleAvatar(
                      radius: 9,
                      backgroundColor: _parseColor(item.color!) ??
                          Theme.of(context).colorScheme.primary,
                    ),
              title: Text(item.name),
              subtitle: item.subtitle.isEmpty ? null : Text(item.subtitle),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${item.count}'),
                  PopupMenuButton<String>(
                    onSelected: (value) {
                      if (value == 'delete') unawaited(onDelete(item.id));
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'delete', child: Text('删除')),
                    ],
                  ),
                ],
              ),
              onTap: () => onSelected(item.id),
            ),
        ],
      ),
    );
  }
}

class _CollectionEntry {
  const _CollectionEntry({
    required this.id,
    required this.name,
    required this.count,
    this.subtitle = '',
    this.color,
  });

  final String id;
  final String name;
  final int count;
  final String subtitle;
  final String? color;
}

Color? _parseColor(String value) {
  final normalized = value.replaceFirst('#', '');
  final parsed = int.tryParse(normalized, radix: 16);
  if (parsed == null) return null;
  return Color(normalized.length == 6 ? 0xFF000000 | parsed : parsed);
}
