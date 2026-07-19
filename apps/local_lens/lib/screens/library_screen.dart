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
        if (constraints.maxWidth >= 780) {
          return _DesktopShell(
            index: _index,
            settings: widget.settings,
            pages: _pages,
            compact: constraints.maxWidth < 1120,
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
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final scheme = theme.colorScheme;
    final sidebarColor = dark ? AppTheme.darkSidebar : AppTheme.lightSidebar;
    final host = Uri.tryParse(settings.normalizedBaseUrl)?.host ??
        settings.normalizedBaseUrl;
    final settingsLabel = settings.isLocal ? '本机服务器设置' : '连接设置';

    return Scaffold(
      body: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            width: compact ? 84 : 252,
            decoration: BoxDecoration(
              color: sidebarColor,
              border: Border(
                right: BorderSide(color: scheme.outlineVariant),
              ),
            ),
            child: SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      compact ? 14 : 18,
                      18,
                      compact ? 14 : 18,
                      18,
                    ),
                    child: _Brand(compact: compact),
                  ),
                  if (!compact)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(22, 0, 22, 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '浏览',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ),
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
                          _ConnectionSummary(
                            local: settings.isLocal,
                            host: host,
                          ),
                        if (!compact) const SizedBox(height: 8),
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
            child: ColoredBox(
              color: theme.scaffoldBackgroundColor,
              child: Column(
                children: [
                  _DesktopCommandBar(
                    destination: _destinations[index],
                    settings: settings,
                    host: host,
                    onEditConnection: onEditConnection,
                  ),
                  Expanded(
                    child: ClipRect(
                      child: IndexedStack(index: index, children: pages),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopCommandBar extends StatelessWidget {
  const _DesktopCommandBar({
    required this.destination,
    required this.settings,
    required this.host,
    required this.onEditConnection,
  });

  final _DestinationData destination;
  final ServerSettings settings;
  final String host;
  final VoidCallback onEditConnection;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final settingsLabel = settings.isLocal ? '本机服务器设置' : '连接设置';
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 22),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.82),
        border: Border(
          bottom: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          Icon(destination.icon, size: 17, color: scheme.onSurfaceVariant),
          const SizedBox(width: 9),
          Text(
            'LocalLens',
            style: theme.textTheme.labelLarge?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Icon(
              LucideIcons.chevronRight,
              size: 14,
              color: scheme.outline,
            ),
          ),
          Text(destination.title, style: theme.textTheme.labelLarge),
          const Spacer(),
          AppStatusPill(
            label: settings.isLocal ? '本机服务正常' : '已连接 $host',
            icon: settings.isLocal ? LucideIcons.server : LucideIcons.wifi,
            color: const Color(0xFF2B9B66),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: settingsLabel,
            onPressed: onEditConnection,
            icon: Icon(
              settings.isLocal ? LucideIcons.serverCog : LucideIcons.settings,
              size: 20,
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectionSummary extends StatelessWidget {
  const _ConnectionSummary({required this.local, required this.host});

  final bool local;
  final String host;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: const Color(0xFF2B9B66).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: const Icon(
              LucideIcons.server,
              size: 15,
              color: Color(0xFF2B9B66),
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  local ? '本机服务运行中' : '远程服务已连接',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                const SizedBox(height: 1),
                Text(
                  host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
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
        titleSpacing: 18,
        title: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(9),
              ),
              alignment: Alignment.center,
              child: Icon(
                LucideIcons.aperture,
                size: 17,
                color: Theme.of(context).colorScheme.onPrimary,
              ),
            ),
            const SizedBox(width: 10),
            Text(_destinations[index].title),
          ],
        ),
        actions: [
          IconButton(
            tooltip: settings.isLocal ? '本机服务器设置' : '修改服务器地址',
            onPressed: onEditConnection,
            icon: Icon(
              settings.isLocal ? LucideIcons.serverCog : LucideIcons.settings,
            ),
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
    final scheme = Theme.of(context).colorScheme;
    final mark = Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primary, scheme.tertiary],
        ),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: 0.2),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Icon(
        LucideIcons.aperture,
        size: 23,
        color: scheme.onPrimary,
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
                '本地媒体空间',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
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
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            height: 46,
            padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 12),
            decoration: BoxDecoration(
              color: selected
                  ? scheme.primaryContainer.withValues(alpha: 0.72)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(
                color: selected
                    ? scheme.primary.withValues(alpha: 0.12)
                    : Colors.transparent,
              ),
            ),
            child: Row(
              mainAxisAlignment:
                  compact ? MainAxisAlignment.center : MainAxisAlignment.start,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: selected
                        ? scheme.primary.withValues(alpha: 0.1)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    icon,
                    size: 19,
                    color: selected ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
                if (!compact) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      label,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            fontWeight:
                                selected ? FontWeight.w700 : FontWeight.w600,
                            color: selected
                                ? scheme.onPrimaryContainer
                                : scheme.onSurface,
                          ),
                    ),
                  ),
                  if (selected)
                    Container(
                      width: 3,
                      height: 18,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: BorderRadius.circular(999),
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
