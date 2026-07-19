import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../models/local_server_config.dart';

class LocalLibraryEditor extends StatefulWidget {
  const LocalLibraryEditor({
    required this.libraries,
    required this.onChanged,
    this.enabled = true,
    this.compact = false,
    super.key,
  });

  final List<LocalLibraryConfig> libraries;
  final ValueChanged<List<LocalLibraryConfig>> onChanged;
  final bool enabled;
  final bool compact;

  @override
  State<LocalLibraryEditor> createState() => _LocalLibraryEditorState();
}

class _LocalLibraryEditorState extends State<LocalLibraryEditor> {
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < widget.libraries.length; index++) ...[
          _libraryCard(context, index, widget.libraries[index]),
          if (index != widget.libraries.length - 1)
            const SizedBox(height: 12),
        ],
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: widget.enabled ? _addLibrary : null,
            icon: const Icon(LucideIcons.folderPlus, size: 18),
            label: const Text('添加媒体库'),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '每个媒体库对应一个独立文件夹。修改后会重启本机服务，并对新增或变更的目录建立索引。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _libraryCard(
    BuildContext context,
    int index,
    LocalLibraryConfig library,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: ValueKey(library.id),
      padding: EdgeInsets.all(widget.compact ? 14 : 16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                library.enabled
                    ? LucideIcons.folderOpen
                    : LucideIcons.folderClosed,
                size: 19,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  '媒体库 ${index + 1}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              IconButton(
                tooltip: widget.libraries.length == 1
                    ? '至少保留一个媒体库'
                    : '移除媒体库',
                onPressed: !widget.enabled || widget.libraries.length == 1
                    ? null
                    : () => _removeLibrary(index),
                icon: const Icon(LucideIcons.trash2, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextFormField(
            key: ValueKey('name-${library.id}'),
            initialValue: library.name,
            enabled: widget.enabled,
            decoration: const InputDecoration(labelText: '媒体库名称'),
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return '请输入媒体库名称';
              }
              return null;
            },
            onChanged: (value) => _replace(
              index,
              library.copyWith(name: value),
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            key: ValueKey('path-${library.id}-${library.path}'),
            initialValue: library.path,
            readOnly: true,
            decoration: InputDecoration(
              labelText: '媒体目录',
              hintText: r'D:\Media',
              helperText: '只读取和索引该目录，不会修改原始图片和视频。',
              suffixIcon: TextButton(
                onPressed: widget.enabled
                    ? () => _chooseDirectory(index, library)
                    : null,
                child: Text(library.path.trim().isEmpty ? '选择目录' : '更换目录'),
              ),
            ),
            validator: (_) {
              if (library.path.trim().isEmpty) return '请选择媒体目录';
              if (_isDuplicatePath(index, library.path)) {
                return '该目录已被其他媒体库使用';
              }
              if (!Directory(library.path).existsSync()) {
                return '目录不存在或当前无法访问';
              }
              return null;
            },
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 20,
            runSpacing: 4,
            children: [
              SizedBox(
                width: 210,
                child: SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: library.recursive,
                  onChanged: widget.enabled
                      ? (value) => _replace(
                            index,
                            library.copyWith(recursive: value),
                          )
                      : null,
                  title: const Text('扫描子文件夹'),
                ),
              ),
              SizedBox(
                width: 210,
                child: SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: library.enabled,
                  onChanged: widget.enabled
                      ? (value) => _replace(
                            index,
                            library.copyWith(enabled: value),
                          )
                      : null,
                  title: const Text('启用媒体库'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _addLibrary() async {
    final path = await getDirectoryPath();
    if (path == null || !mounted) return;
    if (_containsPath(path)) {
      _showMessage('该目录已经在媒体库列表中');
      return;
    }
    final next = List<LocalLibraryConfig>.of(widget.libraries)
      ..add(LocalLibraryConfig(
        id: 'library-${DateTime.now().microsecondsSinceEpoch}',
        name: _directoryName(path),
        path: Directory(path).absolute.path,
      ));
    widget.onChanged(next);
  }

  Future<void> _chooseDirectory(
    int index,
    LocalLibraryConfig library,
  ) async {
    final path = await getDirectoryPath(initialDirectory: library.path);
    if (path == null || !mounted) return;
    if (_containsPath(path, exceptIndex: index)) {
      _showMessage('该目录已经被其他媒体库使用');
      return;
    }
    _replace(
      index,
      library.copyWith(path: Directory(path).absolute.path),
    );
  }

  void _removeLibrary(int index) {
    final next = List<LocalLibraryConfig>.of(widget.libraries)..removeAt(index);
    widget.onChanged(next);
  }

  void _replace(int index, LocalLibraryConfig library) {
    final next = List<LocalLibraryConfig>.of(widget.libraries);
    next[index] = library;
    widget.onChanged(next);
  }

  bool _isDuplicatePath(int index, String path) {
    return _containsPath(path, exceptIndex: index);
  }

  bool _containsPath(String path, {int? exceptIndex}) {
    final normalized = _normalizePath(path);
    for (var index = 0; index < widget.libraries.length; index++) {
      if (index == exceptIndex) continue;
      final candidate = widget.libraries[index].path.trim();
      if (candidate.isNotEmpty && _normalizePath(candidate) == normalized) {
        return true;
      }
    }
    return false;
  }

  String _normalizePath(String path) {
    var normalized = Directory(path).absolute.path.replaceAll('/', '\\');
    normalized = normalized.replaceAll(RegExp(r'[\\/]+$'), '');
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  String _directoryName(String path) {
    final normalized = path.replaceAll(RegExp(r'[\\/]+$'), '');
    final parts = normalized.split(RegExp(r'[\\/]'));
    final name = parts.isEmpty ? '' : parts.last.trim();
    return name.isEmpty ? '媒体库 ${widget.libraries.length + 1}' : name;
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}
