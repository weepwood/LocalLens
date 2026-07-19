import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../models/server_settings.dart';
import '../services/api_client.dart';
import '../services/local_server_supervisor.dart';
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
    this.localServerSupervisor,
    super.key,
  });

  final ServerSettings settings;
  final VoidCallback onEditConnection;
  final Future<void> Function() onDisconnect;
  final LocalServerSupervisor? localServerSupervisor;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  late final ApiClient _api = ApiClient(widget.settings);
  late final List<Widget> _pages = <Widget>[
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
          settings: widget.settings,
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
    final host = Uri.tryParse(settings.normalizedBaseUrl)?.host ??
        settings.normalizedBaseUrl;
    final settingsLabel = settings.isLocal ? '本机服务器设置' : '连接设置';

    return Scaffold(
      body: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 220),
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
                    padding: const EdgeInsets.all(16),
                    child: _Brand(compact: compact),
                  ),
                  Expanded(
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      itemCount: _destinations.length,
                      separatorBuilder: (context, separatorIndex) =>
                          const SizedBox(height: 5),
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
                                    settings.isLocal ? '本机服务 · $host' : host,
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
                          icon: settings.isLocal
                              ? LucideIcons.serverCog
                              : LucideIcons.settings,
                          label: settingsLabel,
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
                        label: settings.isLocal
                            ? '本机服务器运行中'
                            : '已连接 · $host',
                        icon: settings.isLocal
                            ? LucideIcons.server
                            : LucideIcons.wifi,
                        color: const Color(0xFF2B9B66),
                      ),
                      const SizedBox(width: 10),
                      IconButton(
                        tooltip: settingsLabel,
                        onPressed: onEditConnection,
                        icon: Icon(
                          settings.isLocal
                              ? LucideIcons.serverCog
                              : LucideIcons.settings,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(child: IndexedStack(index: index, children: pages)),
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
    required this.settings,
    required this.pages,
    required this.onSelected,
    required this.onEditConnection,
  });

  final int index;
  final ServerSettings settings;
  final List<Widget> pages;
  final ValueChanged<int> onSelected;
  final VoidCallback onEditConnection;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_destinations[index].title),
        actions: [
          IconButton(
            tooltip: settings.isLocal ? '本机服务器设置' : '修改服务器地址',
            onPressed: onEditConnection,
            icon: Icon(
              settings.isLocal ? LucideIcons.serverCog : LucideIcons.settings,
            ),
          ),
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
    final mark = Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary,
        borderRadius: BorderRadius.circular(13),
      ),
      alignment: Alignment.center,
      child: Icon(
        LucideIcons.aperture,
        color: Theme.of(context).colorScheme.onPrimary,
      ),
    );
    if (compact) return Center(child: mark);
    return Row(
      children: [
        mark,
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('LocalLens', style: Theme.of(context).textTheme.titleLarge),
              Text(
                'Personal media space',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
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
          child: Container(
            height: 44,
            padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 12),
            decoration: BoxDecoration(
              color: selected
                  ? scheme.primaryContainer.withValues(alpha: 0.78)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Row(
              mainAxisAlignment: compact
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.start,
              children: [
                Icon(icon, size: 20),
                if (!compact) ...[
                  const SizedBox(width: 12),
                  Expanded(child: Text(label)),
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
  const _DestinationData(this.label, this.title, this.icon);

  final String label;
  final String title;
  final IconData icon;
}

const _destinations = <_DestinationData>[
  _DestinationData('时间线', '拍摄时间线', LucideIcons.history),
  _DestinationData('目录', '物理目录', LucideIcons.folder),
  _DestinationData('集合', '相册与标签', LucideIcons.images),
  _DestinationData('服务器', '服务器与设备', LucideIcons.server),
];
