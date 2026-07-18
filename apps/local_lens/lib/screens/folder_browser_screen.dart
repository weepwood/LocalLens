import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:skeletonizer/skeletonizer.dart';

import '../models/collections.dart';
import '../models/server_state.dart';
import '../services/api_client.dart';
import '../widgets/app_components.dart';
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
    if (_loading) return const _FolderPageSkeleton();
    if (_error != null) {
      return AppEmptyState(
        title: '无法读取服务器目录',
        description: _error.toString(),
        icon: LucideIcons.folderX,
        action: FilledButton.icon(
          onPressed: _load,
          icon: const Icon(LucideIcons.refreshCw, size: 17),
          label: const Text('重新加载'),
        ),
      );
    }
    if (_libraries.isEmpty || _libraryId == null) {
      return const AppEmptyState(
        title: '没有启用的媒体库',
        description: '请先在服务端 config.json 中配置并启用媒体目录。',
        icon: LucideIcons.hardDrive,
      );
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
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
            child: Row(
              children: [
                SizedBox(width: 300, child: tree),
                const SizedBox(width: 14),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: ColoredBox(
                      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.42),
                      child: browser,
                    ),
                  ),
                ),
              ],
            ),
          );
        }
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: SizedBox(height: 240, child: tree),
            ),
            Expanded(child: browser),
          ],
        );
      },
    );
  }

  Widget _buildTree() {
    return AppSurface(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: AppSectionTitle(
              title: '服务器文件夹',
              subtitle: '与 Windows 媒体根目录保持一致',
              trailing: IconButton(
                tooltip: '刷新媒体库',
                onPressed: _load,
                icon: const Icon(LucideIcons.refreshCw, size: 17),
              ),
            ),
          ),
          Divider(color: Theme.of(context).dividerColor),
          Expanded(
            child: Theme(
              data: Theme.of(context).copyWith(
                expansionTileTheme: const ExpansionTileThemeData(
                  tilePadding: EdgeInsets.symmetric(horizontal: 10),
                  childrenPadding: EdgeInsets.zero,
                  shape: Border(),
                  collapsedShape: Border(),
                ),
              ),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(6, 8, 6, 14),
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
          ),
        ],
      ),
    );
  }

  Widget _buildBreadcrumb() {
    final library = _libraries.firstWhere((item) => item.id == _libraryId);
    final segments = _folderPath.isEmpty ? <String>[] : _folderPath.split('/');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppPageHeader(
          title: _folderPath.isEmpty ? library.name : segments.last,
          description: _folderPath.isEmpty ? '媒体库根目录' : _folderPath,
          icon: LucideIcons.folderOpen,
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 6),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _BreadcrumbButton(
                  label: library.name,
                  icon: LucideIcons.hardDrive,
                  onPressed: () => setState(() => _folderPath = ''),
                ),
                for (var index = 0; index < segments.length; index++) ...[
                  Icon(
                    LucideIcons.chevronRight,
                    size: 15,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
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
        ),
      ],
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
      leading: const Icon(LucideIcons.hardDrive, size: 18),
      title: Text(widget.library.name, style: Theme.of(context).textTheme.labelLarge),
      subtitle: Text('${widget.library.mediaCount} 项'),
      trailing: _loading
          ? const SizedBox.square(
              dimension: 17,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(LucideIcons.chevronDown, size: 16),
      children: [
        _TreeRow(
          selected: selected,
          depth: 1,
          icon: LucideIcons.folderOpen,
          label: '根目录',
          count: widget.library.mediaCount,
          onTap: () => widget.onSelected(''),
        ),
        if (_error != null)
          _TreeRow(
            selected: false,
            depth: 1,
            icon: LucideIcons.circleAlert,
            label: '目录加载失败，点击重试',
            onTap: () {
              setState(() => _children = null);
              unawaited(_load());
            },
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
  bool _expanded = false;

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
    return Column(
      children: [
        _TreeRow(
          selected: selected,
          depth: widget.depth,
          icon: _expanded ? LucideIcons.folderOpen : LucideIcons.folder,
          label: widget.folder.name,
          count: widget.folder.mediaCount,
          loading: _loading,
          expandable: widget.folder.childCount > 0,
          expanded: _expanded,
          onExpand: widget.folder.childCount == 0
              ? null
              : () {
                  setState(() => _expanded = !_expanded);
                  if (_expanded) unawaited(_load());
                },
          onTap: () => widget.onSelected(widget.folder.path),
        ),
        if (_expanded)
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
    );
  }
}

class _TreeRow extends StatelessWidget {
  const _TreeRow({
    required this.selected,
    required this.depth,
    required this.icon,
    required this.label,
    required this.onTap,
    this.count,
    this.loading = false,
    this.expandable = false,
    this.expanded = false,
    this.onExpand,
  });

  final bool selected;
  final int depth;
  final IconData icon;
  final String label;
  final int? count;
  final bool loading;
  final bool expandable;
  final bool expanded;
  final VoidCallback? onExpand;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(left: 8.0 * depth, top: 2, bottom: 2),
      child: Material(
        color: selected ? scheme.primaryContainer.withValues(alpha: 0.72) : Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(9),
          child: SizedBox(
            height: 38,
            child: Row(
              children: [
                SizedBox(
                  width: 30,
                  child: expandable
                      ? IconButton(
                          tooltip: expanded ? '收起' : '展开',
                          padding: EdgeInsets.zero,
                          visualDensity: VisualDensity.compact,
                          onPressed: onExpand,
                          icon: Icon(
                            expanded ? LucideIcons.chevronDown : LucideIcons.chevronRight,
                            size: 14,
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                Icon(
                  icon,
                  size: 17,
                  color: selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                        ),
                  ),
                ),
                if (loading)
                  const Padding(
                    padding: EdgeInsets.only(right: 10),
                    child: SizedBox.square(
                      dimension: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else if (count != null && count! > 0)
                  Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: Text('$count', style: Theme.of(context).textTheme.labelSmall),
                  ),
              ],
            ),
          ),
        ),
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
    return TextButton(
      onPressed: onPressed,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16),
            const SizedBox(width: 6),
          ],
          Text(label),
        ],
      ),
    );
  }
}

class _FolderPageSkeleton extends StatelessWidget {
  const _FolderPageSkeleton();

  @override
  Widget build(BuildContext context) {
    return Skeletonizer(
      enabled: true,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Container(
              width: 300,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
