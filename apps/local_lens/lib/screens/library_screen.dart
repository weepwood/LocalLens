import 'package:flutter/material.dart';

import '../models/server_settings.dart';
import '../services/api_client.dart';
import 'collections_screen.dart';
import 'folder_browser_screen.dart';
import 'server_screen.dart';
import 'timeline_screen.dart';

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
  late final List<Widget> _pages = [
    TimelineScreen(api: _api),
    FolderBrowserScreen(api: _api),
    CollectionsScreen(api: _api),
    ServerScreen(api: _api, onDisconnect: widget.onDisconnect),
  ];
  int _index = 0;

  @override
  void dispose() {
    _api.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final extended = constraints.maxWidth >= 1180;
        if (constraints.maxWidth >= 760) {
          return Scaffold(
            body: Row(
              children: [
                NavigationRail(
                  extended: extended,
                  selectedIndex: _index,
                  onDestinationSelected: (value) => setState(() => _index = value),
                  leading: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: extended
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.photo_library_rounded, size: 30),
                              const SizedBox(width: 10),
                              Text(
                                'LocalLens',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                            ],
                          )
                        : const Icon(Icons.photo_library_rounded, size: 30),
                  ),
                  destinations: const [
                    NavigationRailDestination(
                      icon: Icon(Icons.timeline_outlined),
                      selectedIcon: Icon(Icons.timeline_rounded),
                      label: Text('时间线'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.account_tree_outlined),
                      selectedIcon: Icon(Icons.account_tree_rounded),
                      label: Text('目录'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.collections_bookmark_outlined),
                      selectedIcon: Icon(Icons.collections_bookmark_rounded),
                      label: Text('集合'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.dns_outlined),
                      selectedIcon: Icon(Icons.dns_rounded),
                      label: Text('服务器'),
                    ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: IndexedStack(index: _index, children: _pages),
                ),
              ],
            ),
          );
        }
        return Scaffold(
          appBar: AppBar(
            title: Text(_titles[_index]),
            leading: const Icon(Icons.photo_library_rounded),
          ),
          body: IndexedStack(index: _index, children: _pages),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (value) => setState(() => _index = value),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.timeline_outlined),
                selectedIcon: Icon(Icons.timeline_rounded),
                label: '时间线',
              ),
              NavigationDestination(
                icon: Icon(Icons.account_tree_outlined),
                selectedIcon: Icon(Icons.account_tree_rounded),
                label: '目录',
              ),
              NavigationDestination(
                icon: Icon(Icons.collections_bookmark_outlined),
                selectedIcon: Icon(Icons.collections_bookmark_rounded),
                label: '集合',
              ),
              NavigationDestination(
                icon: Icon(Icons.dns_outlined),
                selectedIcon: Icon(Icons.dns_rounded),
                label: '服务器',
              ),
            ],
          ),
        );
      },
    );
  }
}

const _titles = ['拍摄时间线', '物理目录', '相册与标签', '服务器与设备'];
