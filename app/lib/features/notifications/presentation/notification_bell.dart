import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../appointments/domain/appointment_text.dart' show dateLabel, timeLabel;
import '../../auth/state/auth_providers.dart';
import '../data/notifications_repository.dart';
import '../state/notification_providers.dart';

/// D-77: the bell. Shows the unread count; on the portal it opens a panel under the top
/// bar, on the phone the Notifications page. Checks for new ones every minute.
class NotificationBell extends ConsumerStatefulWidget {
  const NotificationBell({super.key, this.panel = false, this.color});

  /// true on the web portal (panel), false on the phone (full page).
  final bool panel;
  final Color? color;

  static const refreshEvery = Duration(minutes: 1);

  @override
  ConsumerState<NotificationBell> createState() => _NotificationBellState();
}

class _NotificationBellState extends ConsumerState<NotificationBell> {
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(
      NotificationBell.refreshEvery,
      (_) => ref.invalidate(notificationInboxProvider),
    );
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _open() async {
    ref.invalidate(notificationInboxProvider);
    if (!widget.panel) {
      await context.push('/notifications');
      return;
    }
    final route = await showDialog<String>(
      context: context,
      barrierColor: Colors.black12,
      builder: (_) => const Dialog(
        alignment: Alignment.topRight,
        insetPadding: EdgeInsets.only(top: 56, right: 12, left: 12, bottom: 24),
        child: SizedBox(width: 420, height: 560, child: NotificationsPanel(closeOnOpen: true)),
      ),
    );
    if (route != null && mounted) context.go(route);
  }

  @override
  Widget build(BuildContext context) {
    final unread = ref.watch(notificationInboxProvider).value?.unread ?? 0;
    return IconButton(
      key: const Key('notification-bell'),
      tooltip: 'Notifications',
      color: widget.color,
      onPressed: _open,
      icon: Badge(
        key: const Key('bell-badge'),
        isLabelVisible: unread > 0,
        label: Text(unread > 99 ? '99+' : '$unread'),
        child: Icon(unread > 0 ? Icons.notifications_active : Icons.notifications_none),
      ),
    );
  }
}

/// The list of saved notifications. D-98: filter chips (All, Unread, by kind), grouped by
/// day (Today, Yesterday, Earlier), card rows with a coloured icon, "Urgent" badge,
/// relative time and an unread dot.
class NotificationsPanel extends ConsumerStatefulWidget {
  const NotificationsPanel({super.key, this.closeOnOpen = false});

  /// In the portal panel: pop with the route to open instead of navigating here.
  final bool closeOnOpen;

  @override
  ConsumerState<NotificationsPanel> createState() => _NotificationsPanelState();
}

/// Filter chips: label per notification category.
const _kinds = {
  'alerts': 'Alerts',
  'messages': 'Messages',
  'appointments': 'Appointments',
  'medication': 'Medication',
  'orders': 'Orders',
};

class _NotificationsPanelState extends ConsumerState<NotificationsPanel> {
  /// 'all', 'unread' or a category.
  String _filter = 'all';

  Future<void> _tap(AppNotification n) async {
    final role = ref.read(currentUserProvider).value?.role;
    final route = notificationRoute(n.type, n.data, role);
    if (!n.read) {
      try {
        await ref.read(notificationsRepositoryProvider).markRead(n.id);
      } catch (_) {
        // Still open it; the badge catches up on the next refresh.
      }
      ref.invalidate(notificationInboxProvider);
    }
    if (!mounted) return;
    if (widget.closeOnOpen) {
      Navigator.of(context).pop(route);
    } else if (route != null) {
      // D-80: a bottom-tab page lives inside the tab shell, which is already on the
      // stack; pushing a second copy of the shell rendered an empty page. Switch tab.
      if (isTabRoute(route)) {
        context.go(route);
      } else {
        context.push(route);
      }
    }
  }

  static String _day(DateTime? t, DateTime now) {
    if (t == null) return 'Earlier';
    final local = t.toLocal();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(local.year, local.month, local.day);
    final diff = today.difference(day).inDays;
    return switch (diff) {
      0 => 'Today',
      1 => 'Yesterday',
      _ when diff < 7 => 'This week',
      _ => 'Earlier',
    };
  }

  @override
  Widget build(BuildContext context) {
    final inbox = ref.watch(notificationInboxProvider);
    final theme = Theme.of(context);
    final items = inbox.value?.items ?? const <AppNotification>[];
    final unread = inbox.value?.unread ?? 0;
    final present = {for (final n in items) n.category};
    final shown = [
      for (final n in items)
        if (_filter == 'all' || (_filter == 'unread' && !n.read) || (_filter == n.category)) n,
    ];
    final now = DateTime.now();
    Widget chip(String key, String label) => Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        key: Key('notif-filter-$key'),
        label: Text(label),
        selected: _filter == key,
        showCheckmark: false,
        visualDensity: VisualDensity.compact,
        onSelected: (_) => setState(() => _filter = key),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('Notifications', style: theme.textTheme.titleMedium),
                    if (unread > 0)
                      Container(
                        key: const Key('notif-unread-count'),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '$unread new',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onPrimary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              TextButton.icon(
                key: const Key('notifications-read-all'),
                onPressed: unread == 0
                    ? null
                    : () async {
                        await ref.read(notificationsRepositoryProvider).markAllRead();
                        ref.invalidate(notificationInboxProvider);
                      },
                icon: const Icon(Icons.done_all, size: 18),
                label: const Text('Mark all read'),
              ),
            ],
          ),
        ),
        if (items.isNotEmpty)
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              children: [
                chip('all', 'All'),
                chip('unread', unread > 0 ? 'Unread ($unread)' : 'Unread'),
                for (final e in _kinds.entries)
                  if (present.contains(e.key)) chip(e.key, e.value),
              ],
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: inbox.when(
            skipLoadingOnRefresh: true,
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) => Center(
              child: TextButton(
                onPressed: () => ref.invalidate(notificationInboxProvider),
                child: const Text('Could not load notifications. Retry'),
              ),
            ),
            data: (box) {
              if (box.items.isEmpty || shown.isEmpty) {
                return _Empty(
                  key: const Key('notifications-empty'),
                  text: box.items.isEmpty
                      ? "You're all caught up."
                      : _filter == 'unread'
                      ? 'No unread notifications.'
                      : 'Nothing here yet.',
                );
              }
              final rows = <Widget>[];
              String? last;
              for (final n in shown) {
                final day = _day(n.createdAt, now);
                if (day != last) {
                  rows.add(
                    Padding(
                      key: Key('notif-day-$day'),
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                      child: Text(
                        day.toUpperCase(),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.outline,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                  );
                  last = day;
                }
                rows.add(_NotificationTile(n: n, now: now, onTap: () => _tap(n)));
              }
              return RefreshIndicator(
                onRefresh: () => ref.refresh(notificationInboxProvider.future),
                child: ListView(padding: const EdgeInsets.only(bottom: 16), children: rows),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      // Scrollable so pull-to-refresh and short panels still work.
      children: [
        const SizedBox(height: 48),
        Icon(Icons.notifications_off_outlined, size: 56, color: theme.colorScheme.outline),
        const SizedBox(height: 12),
        Text(text, textAlign: TextAlign.center, style: theme.textTheme.bodyLarge),
      ],
    );
  }
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({required this.n, required this.now, required this.onTap});
  final AppNotification n;
  final DateTime now;
  final VoidCallback onTap;

  static (IconData, Color) look(String category, bool urgent) {
    if (urgent) return (Icons.warning_amber_rounded, Colors.red.shade700);
    return switch (category) {
      'messages' => (Icons.chat_bubble_outline, Colors.blue.shade600),
      'alerts' => (Icons.monitor_heart_outlined, Colors.deepOrange.shade600),
      'appointments' => (Icons.event_outlined, Colors.purple.shade400),
      'orders' => (Icons.local_pharmacy_outlined, Colors.green.shade600),
      'medication' => (Icons.medication_outlined, Colors.teal.shade600),
      _ => (Icons.notifications_none, Colors.blueGrey),
    };
  }

  /// "Just now", "5 min ago", "2:30 PM" today, "Yesterday", or the date.
  String _when() {
    final t = n.createdAt;
    if (t == null) return '';
    final ago = now.difference(t);
    if (ago.inMinutes < 1) return 'Just now';
    if (ago.inMinutes < 60) return '${ago.inMinutes} min ago';
    final local = t.toLocal();
    final sameDay = local.year == now.year && local.month == now.month && local.day == now.day;
    if (sameDay) return timeLabel(t);
    return '${dateLabel(t)}, ${timeLabel(t)}';
  }

  @override
  Widget build(BuildContext context) {
    final (icon, color) = look(n.category, n.urgent);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Material(
        color: n.read
            ? theme.colorScheme.surfaceContainerLow
            : theme.colorScheme.primaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: Key('notification-${n.id}'),
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(color: n.read ? Colors.transparent : color, width: 4),
              ),
            ),
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: color),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              n.title,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: n.read ? FontWeight.w500 : FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _when(),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.outline,
                            ),
                          ),
                        ],
                      ),
                      if (n.body.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          n.body,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ],
                      if (n.urgent) ...[
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.red.shade50,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            'Urgent',
                            style: TextStyle(
                              color: Colors.red.shade800,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (!n.read) ...[
                  const SizedBox(width: 8),
                  Container(
                    key: Key('unread-dot-${n.id}'),
                    margin: const EdgeInsets.only(top: 6),
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
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

/// Phone: the Notifications page (from the bell on Home).
class NotificationsPage extends StatelessWidget {
  const NotificationsPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Notifications')),
    body: const NotificationsPanel(),
  );
}
