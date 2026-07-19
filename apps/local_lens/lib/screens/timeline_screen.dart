import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../models/server_state.dart';
import '../services/api_client.dart';
import '../widgets/app_components.dart';
import '../widgets/media_browser.dart';

class TimelineScreen extends StatefulWidget {
  const TimelineScreen({required this.api, super.key});

  final ApiClient api;

  @override
  State<TimelineScreen> createState() => _TimelineScreenState();
}

class _TimelineScreenState extends State<TimelineScreen> {
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  List<LibraryInfo> _libraries = const [];
  Timer? _debounce;
  String? _libraryId;
  String _type = 'all';
  String _search = '';
  bool _favorite = false;
  int _minRating = 0;

  bool get _hasActiveFilters =>
      _libraryId != null ||
      _type != 'all' ||
      _search.isNotEmpty ||
      _favorite ||
      _minRating > 0;

  int get _activeFilterCount => [
        _libraryId != null,
        _type != 'all',
        _search.isNotEmpty,
        _favorite,
        _minRating > 0,
      ].where((value) => value).length;

  @override
  void initState() {
    super.initState();
    unawaited(_loadLibraries());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
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
      header: _buildHeader(),
    );
  }

  Widget _buildHeader() {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppPageHeader(
          eyebrow: '媒体浏览',
          title: '拍摄时间线',
          description: '按照真实拍摄时间整理照片与视频，快速回到某一天。',
          icon: LucideIcons.history,
          actions: [
            if (_hasActiveFilters)
              OutlinedButton.icon(
                onPressed: _resetFilters,
                icon: const Icon(LucideIcons.rotateCcw, size: 17),
                label: Text('重置筛选（$_activeFilterCount）'),
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
          child: AppToolbarSurface(
            padding: const EdgeInsets.all(12),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 980;
                final medium = constraints.maxWidth >= 640;
                final searchWidth = wide
                    ? 360.0
                    : medium
                        ? 300.0
                        : constraints.maxWidth;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        SizedBox(
                          width: searchWidth,
                          height: 44,
                          child: SearchBar(
                            controller: _searchController,
                            focusNode: _searchFocusNode,
                            hintText: '搜索文件名或相对路径',
                            leading: const Icon(LucideIcons.search, size: 19),
                            trailing: [
                              if (_searchController.text.isNotEmpty)
                                IconButton(
                                  tooltip: '清空搜索',
                                  onPressed: _clearSearch,
                                  icon: const Icon(LucideIcons.x, size: 17),
                                ),
                            ],
                            onChanged: _onSearchChanged,
                            onSubmitted: (value) =>
                                setState(() => _search = value.trim()),
                          ),
                        ),
                        SizedBox(
                          width: medium ? 220 : constraints.maxWidth,
                          child: DropdownMenu<String?>(
                            key: ValueKey('library-$_libraryId'),
                            initialSelection: _libraryId,
                            expandedInsets: EdgeInsets.zero,
                            label: const Text('媒体库'),
                            leadingIcon: const Icon(
                              LucideIcons.hardDrive,
                              size: 18,
                            ),
                            dropdownMenuEntries: [
                              const DropdownMenuEntry<String?>(
                                value: null,
                                label: '全部媒体库',
                                leadingIcon: Icon(
                                  LucideIcons.database,
                                  size: 18,
                                ),
                              ),
                              ..._libraries.map(
                                (library) => DropdownMenuEntry<String?>(
                                  value: library.id,
                                  label: '${library.name}（${library.mediaCount}）',
                                  leadingIcon: const Icon(
                                    LucideIcons.hardDrive,
                                    size: 18,
                                  ),
                                ),
                              ),
                            ],
                            onSelected: (value) =>
                                setState(() => _libraryId = value),
                          ),
                        ),
                        SegmentedButton<String>(
                          segments: const [
                            ButtonSegment(
                              value: 'all',
                              icon: Icon(LucideIcons.layoutGrid, size: 16),
                              label: Text('全部'),
                            ),
                            ButtonSegment(
                              value: 'image',
                              icon: Icon(LucideIcons.image, size: 16),
                              label: Text('图片'),
                            ),
                            ButtonSegment(
                              value: 'video',
                              icon: Icon(LucideIcons.film, size: 16),
                              label: Text('视频'),
                            ),
                          ],
                          selected: {_type},
                          showSelectedIcon: false,
                          onSelectionChanged: (value) =>
                              setState(() => _type = value.first),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          '快速筛选',
                          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                        ),
                        FilterChip(
                          selected: _favorite,
                          avatar: Icon(
                            LucideIcons.heart,
                            size: 16,
                            color: _favorite ? scheme.primary : null,
                          ),
                          label: const Text('仅收藏'),
                          onSelected: (value) =>
                              setState(() => _favorite = value),
                        ),
                        for (final rating in const [3, 4, 5])
                          FilterChip(
                            selected: _minRating == rating,
                            avatar: const Icon(LucideIcons.star, size: 15),
                            label: Text('$rating 星以上'),
                            onSelected: (selected) => setState(
                              () => _minRating = selected ? rating : 0,
                            ),
                          ),
                        if (_hasActiveFilters)
                          TextButton.icon(
                            onPressed: _resetFilters,
                            icon: const Icon(LucideIcons.x, size: 15),
                            label: const Text('清除'),
                          ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  void _onSearchChanged(String value) {
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 320),
      () {
        if (mounted) setState(() => _search = value.trim());
      },
    );
  }

  void _clearSearch() {
    _debounce?.cancel();
    _searchController.clear();
    _searchFocusNode.unfocus();
    setState(() => _search = '');
  }

  void _resetFilters() {
    _debounce?.cancel();
    _searchController.clear();
    _searchFocusNode.unfocus();
    setState(() {
      _libraryId = null;
      _type = 'all';
      _search = '';
      _favorite = false;
      _minRating = 0;
    });
  }
}
