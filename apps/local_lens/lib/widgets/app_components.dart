import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../theme/app_theme.dart';

class AppPageHeader extends StatelessWidget {
  const AppPageHeader({
    required this.title,
    this.description,
    this.icon,
    this.eyebrow,
    this.actions = const [],
    this.padding = const EdgeInsets.fromLTRB(24, 22, 24, 14),
    super.key,
  });

  final String title;
  final String? description;
  final IconData? icon;
  final String? eyebrow;
  final List<Widget> actions;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: padding,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 720;
          final titleBlock = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (icon != null) ...[
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        scheme.primaryContainer,
                        scheme.primaryContainer.withValues(alpha: 0.58),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(13),
                    border: Border.all(
                      color: scheme.primary.withValues(alpha: 0.12),
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Icon(icon, size: 21, color: scheme.primary),
                ),
                const SizedBox(width: 14),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (eyebrow != null) ...[
                      Text(
                        eyebrow!,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: scheme.primary,
                              letterSpacing: 0.4,
                            ),
                      ),
                      const SizedBox(height: 3),
                    ],
                    Text(
                      title,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    if (description != null) ...[
                      const SizedBox(height: 5),
                      Text(
                        description!,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          );
          if (actions.isEmpty) return titleBlock;
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                titleBlock,
                const SizedBox(height: 14),
                Wrap(spacing: 8, runSpacing: 8, children: actions),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: titleBlock),
              const SizedBox(width: 24),
              Wrap(spacing: 8, runSpacing: 8, children: actions),
            ],
          );
        },
      ),
    );
  }
}

class AppSurface extends StatelessWidget {
  const AppSurface({
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin = EdgeInsets.zero,
    this.backgroundColor,
    this.radius = AppTheme.radius,
    this.clipBehavior = Clip.antiAlias,
    this.emphasized = false,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final Color? backgroundColor;
  final double radius;
  final Clip clipBehavior;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: margin,
      child: ShadCard(
        padding: padding,
        radius: BorderRadius.circular(radius),
        backgroundColor: backgroundColor ??
            (emphasized ? scheme.surfaceContainerLowest : scheme.surface),
        clipBehavior: clipBehavior,
        shadows: emphasized
            ? [
                BoxShadow(
                  color: Colors.black.withValues(
                    alpha: Theme.of(context).brightness == Brightness.dark
                        ? 0.24
                        : 0.055,
                  ),
                  blurRadius: 22,
                  offset: const Offset(0, 8),
                ),
              ]
            : const [],
        child: child,
      ),
    );
  }
}

class AppToolbarSurface extends StatelessWidget {
  const AppToolbarSurface({
    required this.child,
    this.padding = const EdgeInsets.all(12),
    this.margin = EdgeInsets.zero,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: child,
    );
  }
}

class AppSectionTitle extends StatelessWidget {
  const AppSectionTitle({
    required this.title,
    this.subtitle,
    this.trailing,
    super.key,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              if (subtitle != null) ...[
                const SizedBox(height: 3),
                Text(
                  subtitle!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

class AppStatusPill extends StatelessWidget {
  const AppStatusPill({
    required this.label,
    this.icon = LucideIcons.circle,
    this.color,
    super.key,
  });

  final String label;
  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final effective = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: effective.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: effective.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: effective,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: effective.withValues(alpha: 0.35),
                  blurRadius: 5,
                ),
              ],
            ),
          ),
          const SizedBox(width: 7),
          Icon(icon, size: 13, color: effective),
          const SizedBox(width: 5),
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: effective,
                  fontWeight: FontWeight.w700,
                ),
          ),
        ],
      ),
    );
  }
}

class AppEmptyState extends StatelessWidget {
  const AppEmptyState({
    required this.title,
    required this.description,
    this.icon = LucideIcons.images,
    this.action,
    super.key,
  });

  final String title;
  final String description;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: AppSurface(
            emphasized: true,
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 36),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        scheme.primaryContainer,
                        scheme.surfaceContainerHighest,
                      ],
                    ),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  alignment: Alignment.center,
                  child: Icon(icon, size: 29, color: scheme.primary),
                ),
                const SizedBox(height: 18),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  description,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
                if (action != null) ...[
                  const SizedBox(height: 20),
                  action!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
