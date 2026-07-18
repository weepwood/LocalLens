import 'dart:async';

import 'package:flutter/material.dart';

import '../models/collections.dart';
import '../models/server_state.dart';
import '../services/api_client.dart';
import '../widgets/media_browser.dart';

class FolderBrowserScreen extends StatefulWidget {
  const FolderBrowserScreen({required this.api, super.key});

  final ApiClient api;

  @override
  State<FolderBrowserScreen> createState() => _FolderBrowserScreenState();
}

class _FolderBrowserScreenState extends State<FolderBrowserScreen> {
  List<LibraryInfo> _libraries = const [];
  String? _libraryId;
  String _folderPath = '';
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final libraries = await widget.api.listLibraries();
      if (!mounted) return;
      setState(() {
        _libraries = libraries.where((item) => item.enabled).toList();
        _libraryId ??= _libraries.isEmpty ? null : _libraries.first.id;
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
    if (_libraries.isEmpty || _libraryId == null) {
      return const Center(child: Text('服务端没有启用的媒体库'));
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final tree = _buildTree();
        final browser = MediaBrowser(
          key: ValueKey('$_libraryId|$_folderPath'),
          api: widget.api,
          libraryId: _libraryId,
          folder: _folderPath,
          sort: 'timeline',
          emptyLabel: '当前文件夹没有媒体文件',
          header: _buildBreadcrumb(),
        );
        if (constraints.maxWidth >= 900) {
          return Row(
            children: [
              SizedBox(width: 310, child: tree),
              const VerticalDivider(width: 1),
              Expanded(child: browser),
            ],
          );
        }
        return Column(
          children: [
            SizedBox(height: 240, child: tree),
            const Divider(height: 1),
            Expanded(child: browser),
          ],
        );
      },
    );
  }

  Widget _buildTree() {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
            child: Text(
              '服务器文件夹',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                for (final library in _libraries)
                  _LibraryTreeNode(
                    key: ValueKey(library.id),
                    api: widget.api,
                    library: library,
                    selectedLibraryId: _libraryId,
                    selectedPath: _folderPath,
                    onSelected: (path) {
                      setState(() {
                        _libraryId = library.id;
                        _folderPath = path;
                      });
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBreadcrumb() {
    final library = _libraries.firstWhere((item) => item.id == _libraryId);
    final segments = _folderPath.isEmpty ? <String>[] : _folderPath.split('/');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('物理目录', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _BreadcrumbButton(
                  label: library.name,
                  icon: Icons.storage_outlined,
                  onPressed: () => setState(() => _folderPath = ''),
                ),
                for (var index = 0; index < segments.length; index++) ...[
                  const Icon(Icons.chevron_right, size: 18),
                  _BreadcrumbButton(
                    label: segments[index],
                    onPressed: () => setState(
                      () => _folderPath = segments.take(index + 1).join('/'),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _folderPath.isEmpty ? '根目录' : _folderPath,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _LibraryTreeNode extends StatefulWidget {
  const _LibraryTreeNode({
    required this.api,
    required this.library,
    required this.selectedLibraryId,
    required this.selectedPath,
    required this.onSelected,
    super.key,
  });

  final ApiClient api;
  final LibraryInfo library;
  final String? selectedLibraryId;
  final String selectedPath;
  final ValueChanged<String> onSelected;

  @override
  State<_LibraryTreeNode> createState() => _LibraryTreeNodeState();
}

class _LibraryTreeNodeState extends State<_LibraryTreeNode> {
  List<FolderInfo>? _children;
  Object? _error;
  bool _loading = false;

  Future<void> _load() async {
    if (_children != null || _loading) return;
    setState(() => _loading = true);
    try {
      final children = await widget.api.listFolders(libraryId: widget.library.id);
      if (!mounted) return;
      setState(() {
        _children = children;
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
    final selected = widget.selectedLibraryId == widget.library.id &&
        widget.selectedPath.isEmpty;
    return ExpansionTile(
      initiallyExpanded: widget.selectedLibraryId == widget.library.id,
      onExpansionChanged: (expanded) {
        if (expanded) unawaited(_load());
      },
      leading: const Icon(Icons.storage_outlined),
      title: Text(widget.library.name),
      subtitle: Text('${widget.library.mediaCount} 个媒体文件'),
      trailing: _loading
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
      children: [
        ListTile(
          dense: true,
          selected: selected,
          leading: const Icon(Icons.folder_open_outlined),
          title: const Text('根目录'),
          onTap: () => widget.onSelected(''),
        ),
        if (_error != null)
          ListTile(
            dense: true,
            leading: const Icon(Icons.error_outline),
            title: Text(_error.toString()),
            trailing: IconButton(
              onPressed: () {
                setState(() => _children = null);
                unawaited(_load());
              },
              icon: const Icon(Icons.refresh),
            ),
          ),
        for (final child in _children ?? const <FolderInfo>[])
          _FolderTreeNode(
            api: widget.api,
            folder: child,
            selectedLibraryId: widget.selectedLibraryId,
            selectedPath: widget.selectedPath,
            onSelected: widget.onSelected,
            depth: 1,
          ),
      ],
    );
  }
}

class _FolderTreeNode extends StatefulWidget {
  const _FolderTreeNode({
    required this.api,
    required this.folder,
    required this.selectedLibraryId,
    required this.selectedPath,
    required this.onSelected,
    required this.depth,
  });

  final ApiClient api;
  final FolderInfo folder;
  final String? selectedLibraryId;
  final String selectedPath;
  final ValueChanged<String> onSelected;
  final int depth;

  @override
  State<_FolderTreeNode> createState() => _FolderTreeNodeState();
}

class _FolderTreeNodeState extends State<_FolderTreeNode> {
  List<FolderInfo>? _children;
  bool _loading = false;

  Future<void> _load() async {
    if (_children != null || _loading || widget.folder.childCount == 0) return;
    setState(() => _loading = true);
    try {
      final children = await widget.api.listFolders(
        libraryId: widget.folder.libraryId,
        parent: widget.folder.path,
      );
      if (!mounted) return;
      setState(() {
        _children = children;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.selectedLibraryId == widget.folder.libraryId &&
        widget.selectedPath == widget.folder.path;
    if (widget.folder.childCount == 0) {
      return Padding(
        padding: EdgeInsets.only(left: 16.0 * widget.depth),
        child: ListTile(
          dense: true,
          selected: selected,
          leading: const Icon(Icons.folder_outlined),
          title: Text(widget.folder.name),
          trailing: widget.folder.mediaCount == 0
              ? null
              : Text('${widget.folder.mediaCount}'),
          onTap: () => widget.onSelected(widget.folder.path),
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.only(left: 12.0 * widget.depth),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.only(left: 16, right: 8),
        childrenPadding: EdgeInsets.zero,
        onExpansionChanged: (expanded) {
          if (expanded) unawaited(_load());
        },
        leading: const Icon(Icons.folder_outlined),
        title: InkWell(
          onTap: () => widget.onSelected(widget.folder.path),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              widget.folder.name,
              style: selected
                  ? TextStyle(color: Theme.of(context).colorScheme.primary)
                  : null,
            ),
          ),
        ),
        trailing: _loading
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text('${widget.folder.mediaCount}'),
        children: [
          for (final child in _children ?? const <FolderInfo>[])
            _FolderTreeNode(
              api: widget.api,
              folder: child,
              selectedLibraryId: widget.selectedLibraryId,
              selectedPath: widget.selectedPath,
              onSelected: widget.onSelected,
              depth: widget.depth + 1,
            ),
        ],
      ),
    );
  }
}

class _BreadcrumbButton extends StatelessWidget {
  const _BreadcrumbButton({
    required this.label,
    required this.onPressed,
    this.icon,
  });

  final String label;
  final VoidCallback onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onPressed,
      icon: icon == null ? const SizedBox.shrink() : Icon(icon, size: 17),
      label: Text(label),
    );
  }
}
