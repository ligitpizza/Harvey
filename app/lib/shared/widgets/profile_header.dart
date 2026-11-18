import 'package:flutter/material.dart';

/// D-116: the header of a person's page in the portal (pharmacy patient, admin user
/// detail): a soft gradient card with initials, name, small badges, contact facts and
/// the page's actions.
class ProfileHeaderCard extends StatelessWidget {
  const ProfileHeaderCard({
    super.key,
    required this.name,
    this.badges = const [],
    this.facts = const [],
    this.actions = const [],
    this.color,
  });

  final String name;

  /// Short labels beside the name (role, status).
  final List<Widget> badges;

  /// Icon + text facts (age, phone, email, address).
  final List<(IconData, String)> facts;

  /// Buttons on the right (or below, on a narrow page).
  final List<Widget> actions;

  /// Accent colour; the theme's primary when null.
  final Color? color;

  static String initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    return (parts.length == 1 ? parts.first[0] : parts.first[0] + parts.last[0]).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = color ?? theme.colorScheme.primary;
    final muted = theme.colorScheme.onSurfaceVariant;
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(name, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
            ...badges,
          ],
        ),
        if (facts.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 20,
            runSpacing: 6,
            children: [
              for (final (icon, text) in facts)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 16, color: muted),
                    const SizedBox(width: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 520),
                      child: Text(text, style: theme.textTheme.bodyMedium?.copyWith(color: muted)),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ],
    );
    return Container(
      key: const Key('profile-header'),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: theme.colorScheme.outlineVariant),
        gradient: LinearGradient(
          colors: [accent.withValues(alpha: 0.12), theme.colorScheme.surface],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          final avatar = CircleAvatar(
            radius: 34,
            backgroundColor: accent.withValues(alpha: 0.18),
            child: Text(
              initials(name),
              style: theme.textTheme.titleLarge?.copyWith(
                color: accent,
                fontWeight: FontWeight.w700,
              ),
            ),
          );
          final wide = box.maxWidth > 760;
          final buttons = Wrap(spacing: 8, runSpacing: 8, children: actions);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  avatar,
                  const SizedBox(width: 18),
                  Expanded(child: info),
                  if (wide && actions.isNotEmpty) ...[const SizedBox(width: 16), buttons],
                ],
              ),
              if (!wide && actions.isNotEmpty) ...[const SizedBox(height: 14), buttons],
            ],
          );
        },
      ),
    );
  }
}

/// A rounded badge for [ProfileHeaderCard.badges].
class ProfileBadge extends StatelessWidget {
  const ProfileBadge(this.text, {super.key, required this.color, this.icon});

  final String text;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color.withValues(alpha: 0.35)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[Icon(icon, size: 14, color: color), const SizedBox(width: 4)],
        Text(
          text,
          style: Theme.of(
            context,
          ).textTheme.labelMedium?.copyWith(color: color, fontWeight: FontWeight.w600),
        ),
      ],
    ),
  );
}

/// A titled card section with an icon and optional trailing count or action.
class InfoSection extends StatelessWidget {
  const InfoSection({
    super.key,
    required this.icon,
    required this.title,
    required this.child,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, size: 18, color: theme.colorScheme.primary),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
                ?trailing,
              ],
            ),
            const Divider(height: 24),
            child,
          ],
        ),
      ),
    );
  }
}
