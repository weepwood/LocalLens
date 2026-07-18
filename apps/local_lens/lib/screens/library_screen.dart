import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../models/server_settings.dart';
import '../services/api_client.dart';
import '../theme/app_theme.dart';
import '../widgets/app_components.dart';
import 'collections_screen.dart';
import 'folder_browser_screen.dart';
import 'server_screen.dart';
import 'timeline_screen.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    required this.settings,
    required this.onEditConnection,
    required this.onDisconnect,
    super.key,
  });

  final ServerSettings settings;
  final VoidCallback onEditConnection;
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
        if (constraints.maxWidth >= 760) {
          return _DesktopShell(
            index: _index,
            settings: widget.settings,
            pages: _pages,
            compact: constraints.maxWidth < 1080,
            onSelected: (value) => setState(() => _index = value),
            onEditConnection: widget.onEditConnection,
          );
        }
        return _MobileShell(
          index: _index,
          pages: _pages,
          onSelected: (value) => setState(() => _index = value),
          onEditConnection: widget.onEditConnection,
        );
      },
    );
  }
}

class _DesktopShell extends StatelessWidget {
  const _DesktopShell({
    required this.index,
    required this.settings,
    required this.pages,
    required this.compact,
    required this.onSelected,
    required this.onEditConnection,
  });

  final int index;
  final ServerSettings settings;
  final List<Widget> pages;
  final bool compact;
  final ValueChanged<int> onSelected;
  final VoidCallback onEditConnection;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final sidebarColor = dark ? AppTheme.darkSidebar : AppTheme.lightSidebar;
    final host = Uri.tryParse(settings.normalizedBaseUrl)?.host ?? settings.normalizedBaseUrl;

    return Scaffold(
      body: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            width: compact ? 82 : 238,
            decoration: BoxDecoration(
              color: sidebarColor,
              border: Border(
                right: BorderSide(color: Theme.of(context).dividerColor),
              ),
            ),
            child: SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(compact ? 16 : 18, 18, compact ? 16 : 18, 14),
                    child: _Brand(compact: compact),
                  ),
                  const SizedBox(height: 6),
                  Expanded(
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      itemCount: _destinations.length,
                      separatorBuilder: (context, index) => const SizedBox(height: 5),
                      itemBuilder: (context, itemIndex) {
                        final item = _destinations[itemIndex];
                        return _SidebarDestination(
                          compact: compact,
                          selected: index == itemIndex,
                          icon: item.icon,
                          label: item.label,
                          onTap: () => onSelected(itemIndex),
                        );
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(10),
                    child: Column(
                      children: [
                        if (!compact)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
                            child: Row(
                              children: [
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: const BoxDecoration(
                                    color: Color(0xFF2BB673),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    host,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodySmall,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        _SidebarDestination(
                          compact: compact,
                          selected: false,
                          icon: LucideIcons.settings,
                          label: '连接设置',
                          onTap: onEditConnection,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Column(
              children: [
                Container(
                  height: 64,
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  decoration: BoxDecoration(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    border: Border(
                      bottom: BorderSide(color: Theme.of(context).dividerColor),
                    ),
                  ),
                  child: Row(
                    children: [
                      Text(
                        _destinations[index].title,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const Spacer(),
                      AppStatusPill(
                        label: '已连接 · $host',
                        icon: LucideIcons.wifi,
                        color: const Color(0xFF2B9B66),
                      ),
                      const SizedBox(width: 10),
                      IconButton(
                        tooltip: '修改服务器连接',
                        onPressed: onEditConnection,
                        icon: const Icon(LucideIcons.settings),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: IndexedStack(index: index, children: pages),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MobileShell extends StatelessWidget {
  const _MobileShell({
    required this.index,
    required this.pages,
    required this.onSelected,
    required this.onEditConnection,
  });

  final int index;
  final List<Widget> pages;
  final ValueChanged<int> onSelected;
  final VoidCallback onEditConnection;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(
          children: [
            const _BrandMark(size: 30),
            const SizedBox(width: 10),
            Text(_destinations[index].title),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '修改服务器地址',
            onPressed: onEditConnection,
            icon: const Icon(LucideIcons.settings),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: IndexedStack(index: index, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: onSelected,
        destinations: [
          for (final item in _destinations)
            NavigationDestination(
              icon: Icon(item.icon, size: 21),
              selectedIcon: Icon(item.icon, size: 22),
              label: item.label,
            ),
        ],
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return const Center(child: _BrandMark(size: 42));
    }
    return Row(
      children: [
        const _BrandMark(size: 42),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('LocalLens', style: Theme.of(context).textTheme.titleLarge),
              Text(
                'Personal media space',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF6976E8), Color(0xFF4956C8)],
        ),
        borderRadius: BorderRadius.circular(size * 0.3),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF5B67D8).withValues(alpha: 0.22),
            blurRadius: 18,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Icon(LucideIcons.aperture, color: Colors.white, size: size * 0.54),
    );
  }
}

class _SidebarDestination extends StatelessWidget {
  const _SidebarDestination({
    required this.compact,
    required this.selected,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final bool compact;
  final bool selected;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: compact ? label : '',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(11),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            height: 44,
            padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 12),
            decoration: BoxDecoration(
              color: selected ? scheme.primaryContainer.withValues(alpha: 0.78) : Colors.transparent,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Row(
              mainAxisAlignment: compact ? MainAxisAlignment.center : MainAxisAlignment.start,
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
                ),
                if (!compact) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      label,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                            color: selected ? scheme.onPrimaryContainer : scheme.onSurface,
                          ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DestinationData {
  const _DestinationData({
    required this.label,
    required this.title,
    required this.icon,
  });

  final String label;
  final String title;
  final IconData icon;
}

const _destinations = [
  _DestinationData(label: '时间线', title: '拍摄时间线', icon: LucideIcons.history),
  _DestinationData(label: '目录', title: '物理目录', icon: LucideIcons.folder),
  _DestinationData(label: '集合', title: '相册与标签', icon: LucideIcons.images),
  _DestinationData(label: '服务器', title: '服务器与设备', icon: LucideIcons.server),
];
