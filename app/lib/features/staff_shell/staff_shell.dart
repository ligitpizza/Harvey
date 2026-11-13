import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants/enums.dart';
import '../../core/theme/theme_mode.dart';
import '../auth/presentation/widgets/role_toggle.dart';
import '../../shared/widgets/confirm_sign_out.dart';
import '../auth/state/auth_providers.dart';
import '../../shared/widgets/harvey_logo.dart';
import '../notifications/presentation/notification_bell.dart';

class StaffDestination {
  const StaffDestination(this.path, this.label, this.icon, [this.group = '']);
  final String path;
  final String label;
  final IconData icon;

  /// D-84: sidebar section ("Patient care", "Pharmacy", ...); '' = top, no heading.
  final String group;
}

/// Destinations per staff role (NFR-3.2: role-specific interface), in sidebar order.
/// D-84 groups them into sections.
List<StaffDestination> staffDestinations(UserRole role) => switch (role) {
  UserRole.doctor => const [
    StaffDestination('/doctor/dashboard', 'Dashboard', Icons.dashboard_outlined), // D-77
    StaffDestination('/doctor', 'Patients', Icons.people_outline, 'Patient care'),
    StaffDestination(
      '/doctor/prescriptions',
      'Prescriptions',
      Icons.medication_outlined,
      'Patient care',
    ), // D-78
    StaffDestination('/doctor/calendar', 'Calendar', Icons.calendar_month_outlined, 'Patient care'),
    StaffDestination('/doctor/messages', 'Messages', Icons.chat_bubble_outline, 'Communication'),
    StaffDestination('/doctor/leave', 'Leave', Icons.beach_access_outlined, 'Workplace'), // D-80
    StaffDestination('/doctor/admin-center', 'Admin center', Icons.support_agent, 'Workplace'),
  ],
  UserRole.pharmacist => const [
    StaffDestination('/pharmacy/dashboard', 'Dashboard', Icons.dashboard_outlined), // D-77
    StaffDestination('/pharmacy', 'Orders', Icons.local_pharmacy_outlined, 'Pharmacy'),
    StaffDestination('/pharmacy/walk-in', 'Walk-in', Icons.how_to_reg_outlined, 'Pharmacy'),
    // D-70: tracking, inventory and patients apart from the order queue.
    StaffDestination('/pharmacy/tracking', 'Tracking', Icons.local_shipping_outlined, 'Pharmacy'),
    StaffDestination('/pharmacy/inventory', 'Inventory', Icons.inventory_2_outlined, 'Pharmacy'),
    StaffDestination('/pharmacy/cashflow', 'Cashflow', Icons.payments_outlined, 'Pharmacy'), // D-85
    StaffDestination('/pharmacy/patients', 'Patients', Icons.people_outline, 'Pharmacy'),
    StaffDestination(
      '/pharmacy/messages',
      'Messages',
      Icons.chat_bubble_outline,
      'Communication',
    ), // D-69
    StaffDestination('/pharmacy/leave', 'Leave', Icons.beach_access_outlined, 'Workplace'),
    StaffDestination('/pharmacy/admin-center', 'Admin center', Icons.support_agent, 'Workplace'),
  ],
  UserRole.admin => const [
    StaffDestination('/admin/dashboard', 'Dashboard', Icons.dashboard_outlined), // D-77
    StaffDestination('/admin/users', 'Users', Icons.manage_accounts_outlined, 'People'),
    StaffDestination(
      '/admin/assignments',
      'Assignments',
      Icons.assignment_ind_outlined,
      'People',
    ), // D-54
    StaffDestination('/admin/calendar', 'Calendar', Icons.calendar_month_outlined, 'Scheduling'),
    StaffDestination(
      '/admin/appointments',
      'Appointments',
      Icons.event_note_outlined,
      'Scheduling',
    ),
    StaffDestination('/admin/leave', 'Leave', Icons.beach_access_outlined, 'Scheduling'), // D-80
    StaffDestination(
      '/admin/messages',
      'Messages',
      Icons.chat_bubble_outline,
      'Communication',
    ), // D-76
    StaffDestination('/admin/requests', 'Staff requests', Icons.support_agent, 'Communication'),
    StaffDestination('/admin/orders', 'Orders', Icons.receipt_long_outlined, 'Pharmacy'), // D-70
    StaffDestination('/admin/deliveries', 'Deliveries', Icons.local_shipping_outlined, 'Pharmacy'),
    StaffDestination('/admin/inventory', 'Inventory', Icons.inventory_2_outlined, 'Pharmacy'),
    StaffDestination('/admin/cashflow', 'Cashflow', Icons.payments_outlined, 'Pharmacy'), // D-85
    StaffDestination(
      '/admin/analytics/hospital',
      'Hospital analytics',
      Icons.insights_outlined,
      'Insights',
    ),
    StaffDestination('/admin/analytics/system', 'Usage analytics', Icons.query_stats, 'Insights'),
    StaffDestination('/admin/audit-logs', 'Audit logs', Icons.policy_outlined, 'Insights'),
    StaffDestination(
      '/admin/system-health',
      'System health',
      Icons.health_and_safety_outlined,
      'Insights',
    ),
  ],
  _ => const [],
};

/// The destination whose path is the longest prefix of [location] ('/doctor/messages/x'
/// selects Messages, not Patients).
int selectedDestination(List<StaffDestination> destinations, String location) {
  var best = -1;
  for (var i = 0; i < destinations.length; i++) {
    final p = destinations[i].path;
    if (location.startsWith(p) && (best < 0 || p.length > destinations[best].path.length)) {
      best = i;
    }
  }
  return best;
}

/// Home route for each staff role (D-77: their dashboard).
String staffHome(UserRole? role) => switch (role) {
  UserRole.pharmacist => '/pharmacy/dashboard',
  UserRole.admin => '/admin/dashboard',
  _ => '/doctor/dashboard',
};

/// D-77: each role's Settings page (bottom of the left nav).
String staffSettingsPath(UserRole? role) => switch (role) {
  UserRole.pharmacist => '/pharmacy/settings',
  UserRole.admin => '/admin/settings',
  _ => '/doctor/settings',
};

/// D-84: the sidebar is collapsed to icons (remembered for this session).
class SidebarCollapsed extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;
}

final sidebarCollapsedProvider = NotifierProvider<SidebarCollapsed, bool>(SidebarCollapsed.new);

/// Sidebar shell for the Staff Web Portal. D-84: a wide sidebar with grouped sections,
/// labels, the signed-in person and Settings; collapsible to icons; a drawer on narrow
/// screens (< 800 px).
class StaffShell extends ConsumerWidget {
  const StaffShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider).value;
    final role = user?.role ?? UserRole.doctor;
    final destinations = staffDestinations(role);
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 800;
    final collapsed = ref.watch(sidebarCollapsedProvider) || width < 1100;

    Future<void> signOut() => confirmAndSignOut(context, ref);

    final settingsPath = staffSettingsPath(role);
    final light = Theme.of(context).brightness == Brightness.light;

    // D-78: Harvey blue gradient (navy in dark mode), white text and icons.
    final header = AppBar(
      key: const Key('staff-top-bar'),
      foregroundColor: Colors.white,
      iconTheme: const IconThemeData(color: Colors.white),
      actionsIconTheme: const IconThemeData(color: Colors.white),
      automaticallyImplyLeading: !wide,
      leading: wide
          ? IconButton(
              key: const Key('sidebar-toggle'),
              tooltip: collapsed ? 'Expand menu' : 'Collapse menu',
              icon: const Icon(Icons.menu),
              onPressed: width < 1100
                  ? null
                  : () => ref.read(sidebarCollapsedProvider.notifier).toggle(),
            )
          : null,
      flexibleSpace: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: light
                ? const [Color(0xFF0D47A1), Color(0xFF1E88E5)]
                : const [Color(0xFF0A1931), Color(0xFF15305C)],
          ),
        ),
      ),
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
            child: const HarveyLogo.mark(size: 26),
          ),
          const SizedBox(width: 10),
          const Text(
            'Harvey Pro',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
          ),
        ],
      ),
      actions: [
        const NotificationBell(panel: true, color: Colors.white),
        const ThemeModeMenuButton(),
        IconButton(
          key: const Key('staff-sign-out'),
          tooltip: 'Sign out',
          icon: const Icon(Icons.logout),
          onPressed: signOut,
        ),
        const SizedBox(width: 4),
      ],
    );

    Widget sidebar({required bool compact, bool inDrawer = false}) => PortalSidebar(
      destinations: destinations,
      location: location,
      settingsPath: settingsPath,
      compact: compact,
      name: user?.name,
      roleLabel: user == null ? null : RoleToggle.label(user.role),
      onNavigate: (path) {
        if (inDrawer) Navigator.of(context).pop();
        context.go(path);
      },
    );

    if (destinations.length < 2) return Scaffold(appBar: header, body: child);
    if (!wide) {
      return Scaffold(
        appBar: header,
        drawer: Drawer(child: SafeArea(child: sidebar(compact: false, inDrawer: true))),
        body: child,
      );
    }
    return Scaffold(
      appBar: header,
      body: Row(
        children: [
          sidebar(compact: collapsed),
          const VerticalDivider(width: 1),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// D-84: grouped navigation with icons and labels, the signed-in person, and Settings.
class PortalSidebar extends StatelessWidget {
  const PortalSidebar({
    super.key,
    required this.destinations,
    required this.location,
    required this.settingsPath,
    required this.onNavigate,
    this.compact = false,
    this.name,
    this.roleLabel,
  });

  final List<StaffDestination> destinations;
  final String location;
  final String settingsPath;
  final ValueChanged<String> onNavigate;
  final bool compact;
  final String? name;
  final String? roleLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final light = theme.brightness == Brightness.light;
    final selected = selectedDestination(destinations, location);
    final onSettings = location.startsWith(settingsPath);
    final items = <Widget>[];
    String? group;
    for (var i = 0; i < destinations.length; i++) {
      final d = destinations[i];
      if (d.group != group) {
        group = d.group;
        if (d.group.isNotEmpty) {
          items.add(
            compact
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 6, horizontal: 18),
                    child: Divider(height: 1),
                  )
                : Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 12, 6),
                    child: Text(
                      d.group.toUpperCase(),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ),
          );
        }
      }
      items.add(
        _NavItem(
          key: Key('nav-${d.path}'),
          icon: d.icon,
          label: d.label,
          selected: i == selected && !onSettings,
          compact: compact,
          onTap: () => onNavigate(d.path),
        ),
      );
    }
    final trimmed = (name ?? '').trim();
    final initial = trimmed.isEmpty ? '?' : trimmed[0].toUpperCase();
    return Container(
      key: const Key('portal-sidebar'),
      width: compact ? 76 : 248,
      color: light ? const Color(0xFFF7F9FC) : theme.colorScheme.surfaceContainerLow,
      child: Column(
        children: [
          Expanded(
            child: ListView(
              key: const Key('staff-rail-scroll'),
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: items,
            ),
          ),
          const Divider(height: 1),
          _NavItem(
            key: const Key('staff-settings'),
            icon: Icons.settings_outlined,
            label: 'Settings',
            selected: onSettings,
            compact: compact,
            onTap: () => onNavigate(settingsPath),
          ),
          if (name != null)
            Padding(
              padding: EdgeInsets.fromLTRB(compact ? 0 : 16, 4, compact ? 0 : 12, 12),
              child: compact
                  ? Tooltip(
                      message: '$name · ${roleLabel ?? ''}',
                      child: CircleAvatar(
                        radius: 18,
                        backgroundColor: theme.colorScheme.primary,
                        foregroundColor: theme.colorScheme.onPrimary,
                        child: Text(initial),
                      ),
                    )
                  : Row(
                      key: const Key('sidebar-profile'),
                      children: [
                        CircleAvatar(
                          radius: 18,
                          backgroundColor: theme.colorScheme.primary,
                          foregroundColor: theme.colorScheme.onPrimary,
                          child: Text(initial),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                name!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w600),
                              ),
                              if (roleLabel != null)
                                Text(roleLabel!, style: theme.textTheme.bodySmall),
                            ],
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

class _NavItem extends StatelessWidget {
  const _NavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.compact,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? scheme.primary : scheme.onSurfaceVariant;
    final tile = Material(
      color: selected ? scheme.primaryContainer.withValues(alpha: 0.7) : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        hoverColor: scheme.primary.withValues(alpha: 0.06),
        onTap: onTap,
        child: Container(
          height: 44,
          padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 12),
          decoration: selected
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border(left: BorderSide(color: scheme.primary, width: 4)),
                )
              : null,
          child: Row(
            mainAxisAlignment: compact ? MainAxisAlignment.center : MainAxisAlignment.start,
            children: [
              Icon(icon, color: fg, size: 22),
              if (!compact) ...[
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? scheme.primary : scheme.onSurface,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: compact ? Tooltip(message: label, child: tile) : tile,
    );
  }
}

/// Placeholder body for portal sections built in later increments.
class ComingSoon extends StatelessWidget {
  const ComingSoon({super.key, required this.title, required this.note});

  final String title;
  final String note;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(note, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}
