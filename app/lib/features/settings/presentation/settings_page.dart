import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/theme_mode.dart';
import '../../../shared/widgets/confirm_sign_out.dart';
import '../../../shared/widgets/settings_widgets.dart';
import '../../auth/domain/app_user.dart';
import '../../auth/state/auth_providers.dart';
import '../state/settings_providers.dart';
import '../../family/data/location_source.dart';
import '../../family/state/family_providers.dart';

/// Fig 4.3.11.1 Settings (FR-12.1, FR-12.2; UC12.1-UC12.4; D-45).
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  /// Shown while a toggle is being saved, so the switch moves at once.
  NotificationPrefs? _pending;

  Future<void> _setPrefs(NotificationPrefs prefs) async {
    setState(() => _pending = prefs);
    try {
      await ref.read(settingsRepositoryProvider).updateNotifications(prefs);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Could not save your notification setting.')));
      }
    } finally {
      if (mounted) setState(() => _pending = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider).value;
    final prefs = _pending ?? user?.notificationPrefs ?? const NotificationPrefs();
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      // D-79: grouped, colour-coded settings with a profile header.
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (user != null) _ProfileHeader(user: user),
          SettingsGroup(
            title: 'Account',
            children: [
              _NavTile(
                key: const Key('settings-personal'),
                icon: Icons.person_outline,
                color: Colors.blue.shade600,
                title: 'Personal information',
                subtitle: 'Name, date of birth, gender, IC',
                path: '/settings/personal',
              ),
              _NavTile(
                key: const Key('settings-contact'),
                icon: Icons.contact_phone_outlined,
                color: Colors.teal.shade600,
                title: 'Contact details',
                subtitle: 'Phone number, emergency contact',
                path: '/settings/contact',
              ),
              // D-69: used to pre-fill medication deliveries.
              _NavTile(
                key: const Key('settings-address'),
                icon: Icons.home_outlined,
                color: Colors.green.shade600,
                title: 'Delivery address',
                subtitle: 'Pick on the map for medicine deliveries',
                path: '/settings/address',
              ),
            ],
          ),
          SettingsGroup(
            title: 'Health',
            children: [
              _NavTile(
                key: const Key('settings-health'),
                icon: Icons.medical_information_outlined,
                color: Colors.red.shade400,
                title: 'Health profile',
                subtitle: 'Allergies, conditions, lifestyle',
                path: '/settings/health',
              ),
            ],
          ),
          SettingsGroup(
            title: 'Notifications',
            children: [
              SwitchListTile(
                key: const Key('pref-medication'),
                secondary: SettingsIcon(Icons.alarm_outlined, Colors.orange.shade700),
                title: const Text(
                  'Medication reminders',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: const Text('Dose reminders and refill alerts'),
                value: prefs.medicationReminders,
                onChanged: user == null
                    ? null
                    : (v) => _setPrefs(
                        NotificationPrefs(
                          medicationReminders: v,
                          healthUpdates: prefs.healthUpdates,
                        ),
                      ),
              ),
              SwitchListTile(
                key: const Key('pref-updates'),
                secondary: SettingsIcon(Icons.notifications_outlined, Colors.purple.shade400),
                title: const Text('Health updates', style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: const Text('Readings, risk changes, messages'),
                value: prefs.healthUpdates,
                onChanged: user == null
                    ? null
                    : (v) => _setPrefs(
                        NotificationPrefs(
                          medicationReminders: prefs.medicationReminders,
                          healthUpdates: v,
                        ),
                      ),
              ),
              ListTile(
                dense: true,
                leading: SettingsIcon(Icons.priority_high, Colors.red.shade600),
                title: const Text(
                  'Urgent alerts (very high blood pressure, emergencies) are always sent.',
                ),
              ),
            ],
          ),
          SettingsGroup(
            title: 'Appearance',
            children: [
              // Full width under its title, so the three labels never wrap.
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
            title: 'Family and privacy',
            children: [
              if (user?.linkCode != null)
                SettingsTile(
                  key: const Key('settings-link-code'),
                  icon: Icons.family_restroom,
                  color: Colors.cyan.shade700,
                  title: 'Family',
                  subtitle:
                      'Link code ${user!.linkCode} · approve requests, manage who follows you',
                  onTap: () => context.push('/family-requests'),
                ),
              // D-80: the family map's last known location.
              if (user != null) _ShareLocationTile(uid: user.uid),
              _NavTile(
                key: const Key('settings-privacy'),
                icon: Icons.shield_outlined,
                color: Colors.blueGrey,
                title: 'Data & privacy',
                subtitle: 'Export your data, delete your account',
                path: '/settings/privacy',
              ),
            ],
          ),
          const SizedBox(height: 24),
          // D-77: light blue like the rest of the app; deleting the account stays under
          // Data & privacy (FR-12.2), not next to Sign out.
          FilledButton.tonalIcon(
            key: const Key('settings-sign-out'),
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.primaryContainer,
              foregroundColor: theme.colorScheme.onPrimaryContainer,
              minimumSize: const Size.fromHeight(48),
            ),
            onPressed: () => confirmAndSignOut(context, ref),
            icon: const Icon(Icons.logout),
            label: const Text('Sign out'),
          ),
        ],
      ),
    );
  }
}

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({required this.user});

  final AppUser user;

  @override
  Widget build(BuildContext context) {
    final shortId = user.uid.length <= 6 ? user.uid : user.uid.substring(0, 6);
    return SettingsHeader(
      name: user.name,
      lines: ['Patient ID: #${shortId.toUpperCase()}', user.email],
      action: FilledButton.tonal(
        key: const Key('settings-edit-profile'),
        style: FilledButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: Theme.of(context).colorScheme.primary,
          visualDensity: VisualDensity.compact,
        ),
        onPressed: () => context.push('/settings/personal'),
        child: const Text('Edit profile'),
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.path,
    this.color = Colors.blue,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String path;
  final Color color;

  @override
  Widget build(BuildContext context) => SettingsTile(
    icon: icon,
    color: color,
    title: title,
    subtitle: subtitle,
    onTap: () => context.push(path),
  );
}

/// D-80: on by default once location is allowed; off removes the location from the
/// family map. Turning it on asks for location permission if needed.
class _ShareLocationTile extends ConsumerStatefulWidget {
  const _ShareLocationTile({required this.uid});
  final String uid;

  @override
  ConsumerState<_ShareLocationTile> createState() => _ShareLocationTileState();
}

class _ShareLocationTileState extends ConsumerState<_ShareLocationTile> {
  bool _busy = false;

  Future<void> _set(bool on) async {
    setState(() => _busy = true);
    final repo = ref.read(patientLocationRepositoryProvider);
    final source = ref.read(locationSourceProvider);
    try {
      if (on) {
        final access = await source.request();
        if (access != LocationAccess.granted) {
          if (!mounted) return;
          final (text, action) = locationAdvice(access);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(text),
              action: action == null
                  ? null
                  : SnackBarAction(label: action, onPressed: () => source.openSettings(access)),
            ),
          );
          return;
        }
        await repo.setSharing(widget.uid, true);
        final loc = await source.current();
        if (loc != null) await repo.save(widget.uid, lat: loc['lat']!, lng: loc['lng']!);
      } else {
        await repo.setSharing(widget.uid, false);
        await ref.read(backgroundLocationProvider).stop(); // D-80
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not change it. Check your connection.')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool? _always; // "Allow all the time" granted (null = not checked yet)

  @override
  void initState() {
    super.initState();
    _checkAlways();
  }

  Future<void> _checkAlways() async {
    try {
      final ok = await ref.read(backgroundLocationProvider).allowedAllTheTime();
      if (mounted) setState(() => _always = ok);
    } catch (_) {}
  }

  /// D-80: explain, then ask Android for "Allow all the time" and start the job.
  Future<void> _enableBackground() async {
    final bg = ref.read(backgroundLocationProvider);
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Update while Harvey is closed?'),
        content: const Text(
          'Your family map then updates about every 15 minutes even when Harvey is closed.\n\n'
          'Android will ask you to choose "Allow all the time" for Harvey\'s location. '
          'On some phones (e.g. Xiaomi, Oppo, Vivo) also turn off battery optimisation for '
          'Harvey, or updates may stop. You can switch this off any time.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Not now')),
          FilledButton(
            key: const Key('allow-background'),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (go != true) return;
    setState(() => _busy = true);
    try {
      final granted = await bg.askAllTheTime();
      if (granted) {
        await bg.start();
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Choose "Allow all the time" under Location for Harvey.'),
            action: SnackBarAction(label: 'Open settings', onPressed: bg.openSettings),
          ),
        );
      }
    } catch (_) {
      // Permission screens can fail on unusual phones; the status below stays accurate.
    } finally {
      await _checkAlways();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(patientLocationProvider(widget.uid)).value;
    final on = loc?.sharing ?? true;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _shareSwitch(on),
        if (on)
          ListTile(
            key: const Key('settings-background-location'),
            contentPadding: const EdgeInsets.only(left: 72, right: 16),
            title: const Text('Keep updating while Harvey is closed'),
            subtitle: Text(
              _always == true
                  ? 'On: about every 15 minutes ("Allow all the time")'
                  : 'Off: only while Harvey is open',
            ),
            trailing: _always == true
                ? Icon(Icons.check_circle, color: Colors.green.shade600)
                : TextButton(
                    key: const Key('enable-background-location'),
                    onPressed: _busy ? null : _enableBackground,
                    child: const Text('Turn on'),
                  ),
          ),
      ],
    );
  }

  Widget _shareSwitch(bool on) {
    return SwitchListTile(
      key: const Key('settings-share-location'),
      secondary: SettingsIcon(Icons.share_location, Colors.teal.shade600),
      title: const Text(
        'Share my location with family',
        style: TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        on
            ? 'Linked family see where you last opened Harvey'
            : 'Off: family see no location (SOS still sends it)',
      ),
      value: on,
      onChanged: _busy ? null : _set,
    );
  }
}
