import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../family/presentation/emergency_location_updater.dart';
import '../../family/presentation/family_location_reporter.dart';
import 'quick_actions_sheet.dart';

/// Bottom navigation for the patient app (D-83): Home, Vitals, "+", Meds, Settings.
/// The "+" opens the quick actions sheet (which also holds Records). Was Fig 4.3.11.1:
/// Home, Vitals, Meds, Records, Settings.
class PatientShell extends StatelessWidget {
  const PatientShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  /// The bar's slots; null is the "+" button.
  static const tabs = [
    ('/dashboard', 'Home', Icons.home_outlined, Icons.home),
    ('/vitals', 'Vitals', Icons.show_chart, Icons.show_chart),
    null,
    ('/medications', 'Meds', Icons.medication_outlined, Icons.medication),
    ('/settings', 'Settings', Icons.settings_outlined, Icons.settings),
  ];

  static const plusIndex = 2;

  /// Pages reached from the "+" sheet that stay inside the tab shell.
  static const _underPlus = ['/records'];

  int get _selected {
    for (var i = 0; i < tabs.length; i++) {
      final t = tabs[i];
      if (t != null && location.startsWith(t.$1)) return i;
    }
    return _underPlus.any(location.startsWith) ? plusIndex : 0;
  }

  @override
  Widget build(BuildContext context) {
    final index = _selected;
    final onHome = index == 0 && location.startsWith('/dashboard');
    final scheme = Theme.of(context).colorScheme;
    // Android back on another tab returns to Home; back on Home leaves the app.
    return PopScope(
      canPop: onHome,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) context.go('/dashboard');
      },
      child: Scaffold(
        // D-62: keeps an open emergency alert's location fresh while the app is on screen.
        // D-80: and the family map's last known location.
        body: FamilyLocationReporter(child: EmergencyLocationUpdater(child: child)),
        bottomNavigationBar: NavigationBar(
          selectedIndex: index,
          onDestinationSelected: (i) {
            final t = tabs[i];
            if (t == null) {
              showQuickActions(context);
            } else {
              context.go(t.$1);
            }
          },
          destinations: [
            for (final t in tabs)
              if (t == null)
                NavigationDestination(
                  key: const Key('nav-plus'),
                  tooltip: 'Quick actions',
                  icon: CircleAvatar(
                    radius: 20,
                    backgroundColor: scheme.primary,
                    foregroundColor: scheme.onPrimary,
                    child: const Icon(Icons.add, size: 28),
                  ),
                  label: 'More',
                )
              else
                NavigationDestination(icon: Icon(t.$3), selectedIcon: Icon(t.$4), label: t.$2),
          ],
        ),
      ),
    );
  }
}

/// Placeholder for patient features built in later modules.
class ComingSoonPage extends StatelessWidget {
  const ComingSoonPage({super.key, required this.title, required this.note});

  final String title;
  final String note;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(note, textAlign: TextAlign.center),
      ),
    ),
  );
}
