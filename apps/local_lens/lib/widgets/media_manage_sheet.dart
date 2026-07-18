import 'package:flutter/material.dart';

import '../models/collections.dart';
import '../models/media_item.dart';
import '../services/api_client.dart';

class MediaManageSheet extends StatefulWidget {
  const MediaManageSheet({
    required this.api,
    required this.item,
    required this.onUpdated,
    super.key,
  });

  final ApiClient api;
  final MediaItem item;
  final ValueChanged<MediaItem> onUpdated;

  static Future<void> show(
    BuildContext context, {
    required ApiClient api,
    required MediaItem item,
    required ValueChanged<MediaItem> onUpdated,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => MediaManageSheet(
        api: api,
        item: item,
        onUpdated: onUpdated,
      ),
    );
  }

  @override
  State<MediaManageSheet> createState() => _MediaManageSheetState();
}

class _MediaManageSheetState extends State<MediaManageSheet> {
  late MediaItem _item = widget.item;
  List<AlbumInfo> _albums = const [];
  List<TagInfo> _tags = const [];
  Set<String> _albumIds = <String>{};
  Set<String> _tagIds = <String>{};
  bool _loading = true;
  bool _savingRating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait<Object>([
        widget.api.listAlbums(),
        widget.api.listTags(),
        widget.api.getMediaCollections(_item.id),
      ]);
      if (!mounted) return;
      final state = results[2] as MediaCollectionState;
      setState(() {
        _albums = results[0] as List<AlbumInfo>;
        _tags = results[1] as List<TagInfo>;
        _albumIds = state.albumIds;
        _tagIds = state.tagIds;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: FractionallySizedBox(
        heightFactor: 0.9,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _item.fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              Text(
                _item.relativePath,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              _buildRating(),
              const Divider(height: 28),
              if (_loading)
                const Expanded(
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_error != null)
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: _load,
                          icon: const Icon(Icons.refresh),
                          label: const Text('重试'),
                        ),
                      ],
                    ),
                  ),
                )
              else
                Expanded(
                  child: ListView(
                    children: [
                      _SectionHeader(
                        title: '相册',
                        icon: Icons.photo_album_outlined,
                        onAdd: _createAlbum,
                      ),
                      if (_albums.isEmpty)
                        const _EmptyHint(text: '还没有相册')
                      else
                        ..._albums.map(
                          (album) => CheckboxListTile(
                            value: _albumIds.contains(album.id),
                            title: Text(album.name),
                            subtitle: Text('${album.itemCount} 项'),
                            controlAffinity: ListTileControlAffinity.leading,
                            onChanged: (selected) =>
                                _toggleAlbum(album.id, selected ?? false),
                          ),
                        ),
                      const SizedBox(height: 12),
                      _SectionHeader(
                        title: '标签',
                        icon: Icons.sell_outlined,
                        onAdd: _createTag,
                      ),
                      if (_tags.isEmpty)
                        const _EmptyHint(text: '还没有标签')
                      else
                        ..._tags.map(
                          (tag) => CheckboxListTile(
                            value: _tagIds.contains(tag.id),
                            title: Text(tag.name),
                            subtitle: Text('${tag.itemCount} 项'),
                            secondary: tag.color.isEmpty
                                ? null
                                : CircleAvatar(
                                    radius: 8,
                                    backgroundColor: _parseColor(tag.color),
                                  ),
                            controlAffinity: ListTileControlAffinity.leading,
                            onChanged: (selected) =>
                                _toggleTag(tag.id, selected ?? false),
                          ),
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

  Widget _buildRating() {
    return Row(
      children: [
        const Icon(Icons.star_outline_rounded),
        const SizedBox(width: 10),
        Text('评分', style: Theme.of(context).textTheme.titleMedium),
        const Spacer(),
        if (_savingRating)
          const Padding(
            padding: EdgeInsets.only(right: 8),
            child: SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        for (var rating = 1; rating <= 5; rating++)
          IconButton(
            tooltip: '$rating 星',
            onPressed: _savingRating ? null : () => _setRating(rating),
            icon: Icon(
              rating <= _item.rating
                  ? Icons.star_rounded
                  : Icons.star_border_rounded,
            ),
          ),
        IconButton(
          tooltip: '清除评分',
          onPressed: _savingRating || _item.rating == 0
              ? null
              : () => _setRating(0),
          icon: const Icon(Icons.clear_rounded),
        ),
      ],
    );
  }

  Future<void> _setRating(int rating) async {
    setState(() => _savingRating = true);
    try {
      final updated = await widget.api.setRating(_item.id, rating);
      if (!mounted) return;
      setState(() {
        _item = updated;
        _savingRating = false;
      });
      widget.onUpdated(updated);
    } catch (error) {
      if (!mounted) return;
      setState(() => _savingRating = false);
      _showError(error);
    }
  }

  Future<void> _toggleAlbum(String id, bool selected) async {
    setState(() {
      selected ? _albumIds.add(id) : _albumIds.remove(id);
    });
    try {
      await widget.api.setAlbumItem(id, _item.id, selected);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        selected ? _albumIds.remove(id) : _albumIds.add(id);
      });
      _showError(error);
    }
  }

  Future<void> _toggleTag(String id, bool selected) async {
    setState(() {
      selected ? _tagIds.add(id) : _tagIds.remove(id);
    });
    try {
      await widget.api.setMediaTag(_item.id, id, selected);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        selected ? _tagIds.remove(id) : _tagIds.add(id);
      });
      _showError(error);
    }
  }

  Future<void> _createAlbum() async {
    final name = await _askName('新建相册', '相册名称');
    if (name == null) return;
    try {
      final album = await widget.api.createAlbum(name);
      if (!mounted) return;
      setState(() => _albums = <AlbumInfo>[album, ..._albums]);
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _createTag() async {
    final name = await _askName('新建标签', '标签名称');
    if (name == null) return;
    try {
      final tag = await widget.api.createTag(name);
      if (!mounted) return;
      setState(() => _tags = <TagInfo>[..._tags, tag]);
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
          controller: controller,
          autofocus: true,
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

  void _showError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error.toString())),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.icon,
    required this.onAdd,
  });

  final String title;
  final IconData icon;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(title, style: Theme.of(context).textTheme.titleMedium),
      trailing: IconButton(
        tooltip: '新建$title',
        onPressed: onAdd,
        icon: const Icon(Icons.add_rounded),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Text(text, style: Theme.of(context).textTheme.bodySmall),
      ),
    );
  }
}

Color? _parseColor(String value) {
  final normalized = value.replaceFirst('#', '');
  if (normalized.length != 6 && normalized.length != 8) return null;
  final parsed = int.tryParse(normalized, radix: 16);
  if (parsed == null) return null;
  return Color(normalized.length == 6 ? 0xFF000000 | parsed : parsed);
}
