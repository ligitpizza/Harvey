import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/theme_mode.dart';
import '../../../shared/widgets/confirm_sign_out.dart';
import '../../../shared/widgets/settings_widgets.dart';
import '../../auth/state/auth_providers.dart';
import '../state/family_providers.dart';

/// Family app settings: account, who you follow, theme, sign out.
class FamilySettingsPage extends ConsumerWidget {
  const FamilySettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider).value;
    final linked = ref.watch(linkedPatientIdProvider).value;
    final person = linked == null ? null : ref.watch(linkedPersonProvider(linked)).value;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      // D-79: same grouped look as the patient app.
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SettingsHeader(name: user?.name ?? '', lines: [user?.email ?? '', 'Harvey Family']),
          SettingsGroup(
            title: 'Family',
            children: [
              SettingsTile(
                key: const Key('family-settings-linked'),
                icon: Icons.family_restroom,
                color: Colors.teal.shade600,
                title: linked == null ? 'Not following anyone' : 'Following ${person?.name ?? '…'}',
                subtitle: 'Manage under Patients',
                onTap: () => context.go('/family/link'),
              ),
            ],
          ),
          SettingsGroup(
            title: 'Notifications',
            children: [
              SettingsTile(
                icon: Icons.notifications_active_outlined,
                color: Colors.red.shade600,
                title: 'Emergency alerts are always delivered.',
                subtitle: 'Allow notifications for Harvey Family so you never miss one.',
              ),
            ],
          ),
          SettingsGroup(
            title: 'Appearance',
            children: [
              ListTile(
                leading: SettingsIcon(Icons.palette_outlined, Colors.indigo.shade400),
                title: const Text('Theme', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: ThemeModeSelector(expanded: true),
              ),
            ],
          ),
          SettingsGroup(
            title: 'Safety',
            children: [
              SettingsTile(
                icon: Icons.emergency_outlined,
                color: Colors.red.shade700,
                title: 'In an emergency, call 999',
                subtitle: 'Harvey alerts you, but it does not replace emergency services.',
              ),
            ],
          ),
          const SizedBox(height: 24),
          FilledButton.tonalIcon(
            key: const Key('family-sign-out'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () => confirmAndSignOut(context, ref),
            icon: const Icon(Icons.logout),
            label: const Text('Sign out'),
          ),
        ],
      ),
    );
  }
}
