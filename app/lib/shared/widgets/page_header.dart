import 'package:flutter/material.dart';

/// D-84: the top of every portal page: a tinted card with the page's icon, title, a
/// one-line description and the page's main actions on the right (below on narrow
/// screens), so what a page is for and what to do next are obvious.
class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    required this.title,
    required this.icon,
    this.subtitle,
    this.actions = const [],
    this.color,
    this.titleKey,
  });

  final String title;
  final IconData icon;
  final String? subtitle;
  final List<Widget> actions;

  /// Accent colour (defaults to the theme's primary).
  final Color? color;

  /// Key on the title text (tests and anchors).
  final Key? titleKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = color ?? theme.colorScheme.primary;
    final light = theme.brightness == Brightness.light;
    final heading = Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(icon, color: accent, size: 26),
        ),
        const SizedBox(width: 16),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                key: titleKey,
                style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
    return Container(
      key: const Key('page-header'),
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(
          colors: [
            accent.withValues(alpha: light ? 0.10 : 0.22),
            (light ? Colors.white : theme.colorScheme.surfaceContainer).withValues(alpha: 0.9),
          ],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
        border: Border.all(color: accent.withValues(alpha: 0.18)),
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          if (actions.isEmpty) return heading;
          final row = box.maxWidth >= 720;
          final buttons = Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.end,
            children: actions,
          );
          return row
              ? Row(
                  children: [
                    Expanded(child: heading),
                    const SizedBox(width: 16),
                    Flexible(child: buttons),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [heading, const SizedBox(height: 12), buttons],
                );
        },
      ),
    );
  }
}
