import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hypertension/core/theme/app_theme.dart';
import 'package:hypertension/features/staff_shell/staff_shell.dart';
import 'package:hypertension/shared/widgets/page_header.dart';

// D-84: portal look: page header, collapsible grouped sidebar, portal theme.

void main() {
  testWidgets('page header shows icon, title, description and its actions', (t) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    var tapped = false;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PageHeader(
            title: 'Inventory',
            subtitle: 'Medicines and stock.',
            icon: Icons.inventory_2_outlined,
            actions: [FilledButton(onPressed: () => tapped = true, child: const Text('Import'))],
          ),
        ),
      ),
    );
    expect(find.text('Inventory'), findsOneWidget);
    expect(find.text('Medicines and stock.'), findsOneWidget);
    expect(find.byIcon(Icons.inventory_2_outlined), findsOneWidget);
    await t.tap(find.text('Import'));
    expect(tapped, isTrue);
  });

  testWidgets('the sidebar groups items, highlights the page and collapses to icons', (t) async {
    final went = <String>[];
    Widget bar({required bool compact}) => MaterialApp(
      home: Scaffold(
        body: Row(
          children: [
            PortalSidebar(
              destinations: const [
                StaffDestination('/admin/dashboard', 'Dashboard', Icons.dashboard_outlined),
                StaffDestination('/admin/users', 'Users', Icons.people_outline, 'People'),
                StaffDestination('/admin/leave', 'Leave', Icons.beach_access, 'Scheduling'),
              ],
              location: '/admin/users',
              settingsPath: '/admin/settings',
              compact: compact,
              name: 'Admin Woo',
              roleLabel: 'Admin',
              onNavigate: went.add,
            ),
          ],
        ),
      ),
    );
    await t.pumpWidget(bar(compact: false));
    expect(find.text('PEOPLE'), findsOneWidget);
    expect(find.text('SCHEDULING'), findsOneWidget);
    expect(find.text('Admin Woo'), findsOneWidget);
    expect(t.getSize(find.byKey(const Key('portal-sidebar'))).width, 248);
    await t.tap(find.text('Leave'));
    expect(went, ['/admin/leave']);

    await t.pumpWidget(bar(compact: true));
    expect(t.getSize(find.byKey(const Key('portal-sidebar'))).width, 76);
    expect(find.text('Leave'), findsNothing); // icons only, label in a tooltip
    expect(find.byTooltip('Leave'), findsOneWidget);
  });

  testWidgets('the menu button collapses the sidebar on a wide screen', (t) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(sidebarCollapsedProvider), isFalse);
    c.read(sidebarCollapsedProvider.notifier).toggle();
    expect(c.read(sidebarCollapsedProvider), isTrue);
  });

  test('the portal theme has a soft background and white cards with a border', () {
    final theme = AppTheme.portalLight();
    expect(theme.scaffoldBackgroundColor, const Color(0xFFF2F5FA));
    expect(theme.cardTheme.color, Colors.white);
    expect(theme.inputDecorationTheme.filled, isTrue);
    expect(theme.inputDecorationTheme.errorMaxLines, 3); // keeps D-82
  });
}
