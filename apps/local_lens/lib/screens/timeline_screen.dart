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
      header: _buildHeader(),
    );
  }

  Widget _buildHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const AppPageHeader(
          title: '拍摄时间线',
          description: '按照真实拍摄时间整理照片与视频，快速回到某一天。',
          icon: LucideIcons.history,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: AppSurface(
            padding: const EdgeInsets.all(14),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final searchWidth = constraints.maxWidth >= 900
                    ? 360.0
                    : constraints.maxWidth >= 560
                        ? 300.0
                        : constraints.maxWidth;
                return Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: searchWidth,
                      child: TextField(
                        controller: _searchController,
                        decoration: InputDecoration(
                          hintText: '搜索文件名或相对路径',
                          prefixIcon: const Icon(LucideIcons.search, size: 19),
                          suffixIcon: _searchController.text.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: '清空搜索',
                                  onPressed: () {
                                    _searchController.clear();
                                    setState(() => _search = '');
                                  },
                                  icon: const Icon(LucideIcons.x, size: 18),
                                ),
                        ),
                        onChanged: (value) {
                          setState(() {});
                          _debounce?.cancel();
                          _debounce = Timer(
                            const Duration(milliseconds: 360),
                            () {
                              if (mounted) setState(() => _search = value.trim());
                            },
                          );
                        },
                        onSubmitted: (value) => setState(() => _search = value.trim()),
                      ),
                    ),
                    SizedBox(
                      width: 220,
                      child: DropdownMenu<String?>(
                        initialSelection: _libraryId,
                        expandedInsets: EdgeInsets.zero,
                        label: const Text('媒体库'),
                        dropdownMenuEntries: [
                          const DropdownMenuEntry<String?>(
                            value: null,
                            label: '全部媒体库',
                            leadingIcon: Icon(LucideIcons.database, size: 18),
                          ),
                          ..._libraries.map(
                            (library) => DropdownMenuEntry<String?>(
                              value: library.id,
                              label: '${library.name}（${library.mediaCount}）',
                              leadingIcon: const Icon(LucideIcons.hardDrive, size: 18),
                            ),
                          ),
                        ],
                        onSelected: (value) => setState(() => _libraryId = value),
                      ),
                    ),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'all', label: Text('全部')),
                        ButtonSegment(
                          value: 'image',
                          icon: Icon(LucideIcons.image, size: 17),
                          label: Text('图片'),
                        ),
                        ButtonSegment(
                          value: 'video',
                          icon: Icon(LucideIcons.film, size: 17),
                          label: Text('视频'),
                        ),
                      ],
                      selected: {_type},
                      showSelectedIcon: false,
                      onSelectionChanged: (value) => setState(() => _type = value.first),
                    ),
                    FilterChip(
                      selected: _favorite,
                      avatar: Icon(
                        _favorite ? LucideIcons.heart : LucideIcons.heart,
                        size: 16,
                      ),
                      label: const Text('收藏'),
                      onSelected: (value) => setState(() => _favorite = value),
                    ),
                    SizedBox(
                      width: 156,
                      child: DropdownMenu<int>(
                        initialSelection: _minRating,
                        expandedInsets: EdgeInsets.zero,
                        label: const Text('最低评分'),
                        leadingIcon: const Icon(LucideIcons.star, size: 17),
                        dropdownMenuEntries: const [
                          DropdownMenuEntry(value: 0, label: '不限'),
                          DropdownMenuEntry(value: 1, label: '1 星以上'),
                          DropdownMenuEntry(value: 2, label: '2 星以上'),
                          DropdownMenuEntry(value: 3, label: '3 星以上'),
                          DropdownMenuEntry(value: 4, label: '4 星以上'),
                          DropdownMenuEntry(value: 5, label: '5 星'),
                        ],
                        onSelected: (value) => setState(() => _minRating = value ?? 0),
                      ),
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
}
