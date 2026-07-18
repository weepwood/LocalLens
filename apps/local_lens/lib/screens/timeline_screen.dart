import 'dart:async';

import 'package:flutter/material.dart';

import '../models/server_state.dart';
import '../services/api_client.dart';
import '../widgets/media_browser.dart';

class TimelineScreen extends StatefulWidget {
  const TimelineScreen({required this.api, super.key});

  final ApiClient api;

  @override
  State<TimelineScreen> createState() => _TimelineScreenState();
}

class _TimelineScreenState extends State<TimelineScreen> {
  final _searchController = TextEditingController();
  List<LibraryInfo> _libraries = const [];
  Timer? _debounce;
  String? _libraryId;
  String _type = 'all';
  String _search = '';
  bool _favorite = false;
  int _minRating = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadLibraries());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadLibraries() async {
    try {
      final libraries = await widget.api.listLibraries();
      if (mounted) setState(() => _libraries = libraries);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return MediaBrowser(
      key: ValueKey([
        _libraryId,
        _type,
        _search,
        _favorite,
        _minRating,
      ].join('|')),
      api: widget.api,
      libraryId: _libraryId,
      type: _type == 'all' ? null : _type,
      search: _search,
      favorite: _favorite,
      minRating: _minRating,
      sort: 'timeline',
      groupByDate: true,
      header: _buildToolbar(),
    );
  }

  Widget _buildToolbar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('拍摄时间线', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text(
            '优先使用图片 EXIF 或视频容器时间，缺失时回退到文件修改时间。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420, minWidth: 240),
                child: SearchBar(
                  controller: _searchController,
                  leading: const Icon(Icons.search),
                  hintText: '搜索文件名或相对路径',
                  trailing: [
                    if (_searchController.text.isNotEmpty)
                      IconButton(
                        tooltip: '清空',
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _search = '');
                        },
                        icon: const Icon(Icons.close),
                      ),
                  ],
                  onChanged: (value) {
                    setState(() {});
                    _debounce?.cancel();
                    _debounce = Timer(
                      const Duration(milliseconds: 420),
                      () {
                        if (mounted) setState(() => _search = value.trim());
                      },
                    );
                  },
                  onSubmitted: (value) =>
                      setState(() => _search = value.trim()),
                ),
              ),
              DropdownMenu<String?>(
                initialSelection: _libraryId,
                label: const Text('媒体库'),
                dropdownMenuEntries: [
                  const DropdownMenuEntry<String?>(
                    value: null,
                    label: '全部媒体库',
                  ),
                  ..._libraries.map(
                    (library) => DropdownMenuEntry<String?>(
                      value: library.id,
                      label: '${library.name}（${library.mediaCount}）',
                    ),
                  ),
                ],
                onSelected: (value) => setState(() => _libraryId = value),
              ),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'all', label: Text('全部')),
                  ButtonSegment(
                    value: 'image',
                    icon: Icon(Icons.image_outlined),
                    label: Text('图片'),
                  ),
                  ButtonSegment(
                    value: 'video',
                    icon: Icon(Icons.movie_outlined),
                    label: Text('视频'),
                  ),
                ],
                selected: {_type},
                onSelectionChanged: (value) =>
                    setState(() => _type = value.first),
              ),
              FilterChip(
                selected: _favorite,
                avatar: const Icon(Icons.favorite_outline, size: 18),
                label: const Text('只看收藏'),
                onSelected: (value) => setState(() => _favorite = value),
              ),
              DropdownMenu<int>(
                initialSelection: _minRating,
                label: const Text('最低评分'),
                dropdownMenuEntries: const [
                  DropdownMenuEntry(value: 0, label: '不限'),
                  DropdownMenuEntry(value: 1, label: '1 星以上'),
                  DropdownMenuEntry(value: 2, label: '2 星以上'),
                  DropdownMenuEntry(value: 3, label: '3 星以上'),
                  DropdownMenuEntry(value: 4, label: '4 星以上'),
                  DropdownMenuEntry(value: 5, label: '5 星'),
                ],
                onSelected: (value) =>
                    setState(() => _minRating = value ?? 0),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
