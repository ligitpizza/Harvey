import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/enums.dart';
import '../../../core/utils/risk_style.dart';
import '../../appointments/domain/appointment_text.dart' show dateLabel, timeLabel;
import '../../provider_portal/presentation/portal_widgets.dart' show formatDate;
import '../data/admin_repository.dart';
import '../state/admin_providers.dart';
import 'admin_users_page.dart' show roleLabel;
import 'audit_logs_page.dart' show actionLabel;
import 'user_actions.dart';
import '../../../shared/widgets/fill_grid.dart';
import '../../../shared/widgets/profile_header.dart';
import '../../../shared/widgets/wide_table.dart' show TablePill;

Map<String, dynamic> _map(Object? v) => Map<String, dynamic>.from(v as Map? ?? const {});

List<Map<String, dynamic>> _list(Object? v) => [
  for (final e in (v as List? ?? const [])) Map<String, dynamic>.from(e as Map),
];

DateTime? _time(Object? v) => v == null ? null : DateTime.tryParse('$v');

String _when(Object? v) {
  final t = _time(v);
  return t == null ? '-' : '${dateLabel(t)}, ${timeLabel(t)}';
}

RiskLevel? _level(Object? v) => v == null ? null : RiskLevel.fromValue('$v');

String _levelName(RiskLevel l) => switch (l) {
  RiskLevel.low => 'Low',
  RiskLevel.moderate => 'Moderate',
  RiskLevel.high => 'High',
  RiskLevel.critical => 'Critical',
};

/// D-61: one patient, doctor, pharmacist (or other user) for the admin.
class AdminUserDetailPage extends ConsumerWidget {
  const AdminUserDetailPage({super.key, required this.uid});

  final String uid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(adminUserDetailProvider(uid));
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('detail-back'),
            onPressed: () => context.canPop() ? context.pop() : context.go('/admin/users'),
            icon: const Icon(Icons.arrow_back),
            label: const Text('User management'),
          ),
        ),
        detail.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (_, _) => ListTile(
            leading: const Icon(Icons.cloud_off),
            title: const Text('Could not load this user.'),
            trailing: TextButton(
              onPressed: () => ref.invalidate(adminUserDetailProvider(uid)),
              child: const Text('Retry'),
            ),
          ),
          data: (d) => _Body(uid: uid, data: d),
        ),
      ],
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.uid, required this.data});

  final String uid;
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = AdminUser.fromJson(_map(data['user']));
    final profile = _map(data['profile']);
    final theme = Theme.of(context);
    void refresh() => ref.invalidate(adminUserDetailProvider(uid));
    final sections = <Widget>[
      if (data['patient'] != null) ..._patient(context, _map(data['patient'])),
      if (data['doctor'] != null) ..._doctor(context, user, _map(data['doctor'])),
      // D-79: which patient this family member follows.
      if (data.containsKey('family')) _familyLink(context, _map(data['family'])),
      if (data.containsKey('pharmacist'))
        const _Section(
          key: Key('section-pharmacist'),
          icon: Icons.local_pharmacy_outlined,
          title: 'Prescription orders',
          child: Text(
            'Orders prepared, ready for collection and dispatched for delivery appear here '
            'once medication ordering (Module 13) is live.',
          ),
        ),
      _Section(
        key: const Key('section-activity'),
        icon: Icons.history,
        title: 'Recent activity (30 days)',
        child: _list(data['activity']).isEmpty
            ? const Text('No recorded activity.')
            : Column(
                children: [
                  for (final e in _list(data['activity']))
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.radio_button_checked, size: 14),
                      minLeadingWidth: 14,
                      title: Text(actionLabel('${e['action']}')),
                      subtitle: Text('${_when(e['timestamp'])} · ${e['details'] ?? ''}'),
                    ),
                ],
              ),
      ),
    ];
    final status = user.isActive
        ? 'Active'
        : user.deletionRequested
        ? 'Deletion pending'
        : 'Deactivated';
    final account = <String, String>{
      'Joined': user.createdAt == null ? '-' : formatDate(user.createdAt!).split(',').first,
      if (profile['icNumber'] != null) 'MyKad': '${profile['icNumber']}',
      // D-103
      if (profile['passportNumber'] != null)
        'Passport':
            '${profile['passportNumber']}'
            '${profile['nationality'] == null ? '' : ' (${profile['nationality']})'}',
      if (profile['dateOfBirth'] != null) 'Date of birth': '${profile['dateOfBirth']}',
      if (profile['gender'] != null) 'Gender': '${profile['gender']}',
      if (profile['phone'] != null) 'Phone': '${profile['phone']}',
      if (profile['onboardingComplete'] != null)
        'Health profile': profile['onboardingComplete'] == true ? 'Complete' : 'Not completed yet',
      if (user.isDoctor) 'Specialty': user.specialty ?? '-',
      if (user.isDoctor) 'Caseload': '${user.caseload ?? 0} / ${user.maxPatients ?? 30} patients',
    };
    final roleColour = switch (user.role) {
      UserRole.doctor => Colors.indigo.shade600,
      UserRole.pharmacist => Colors.brown.shade500,
      UserRole.admin => Colors.deepPurple.shade500,
      UserRole.familyMember => Colors.orange.shade800,
      _ => Colors.teal.shade700,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // D-116: profile header, then the sections in a grid that fills the page.
        KeyedSubtree(
          key: const Key('detail-header'),
          child: ProfileHeaderCard(
            name: user.name,
            color: roleColour,
            badges: [
              ProfileBadge(roleLabel(user.role), color: roleColour, icon: Icons.badge_outlined),
              ProfileBadge(
                status,
                key: const Key('detail-status'),
                color: user.isActive ? Colors.green.shade700 : theme.colorScheme.error,
                icon: user.isActive ? Icons.check_circle : Icons.block,
              ),
            ],
            facts: [
              (Icons.mail_outline, user.email),
              if (profile['phone'] != null) (Icons.phone_outlined, '${profile['phone']}'),
              if (user.createdAt != null)
                (
                  Icons.calendar_today_outlined,
                  'Joined ${formatDate(user.createdAt!).split(',').first}',
                ),
            ],
            actions: [
              OutlinedButton.icon(
                key: const Key('detail-edit'),
                onPressed: () async {
                  if (await editUser(context, ref, user)) refresh();
                },
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Edit'),
              ),
              OutlinedButton.icon(
                key: const Key('detail-toggle'),
                onPressed: () async {
                  if (await toggleUserActive(context, ref, user)) refresh();
                },
                icon: Icon(user.isActive ? Icons.block : Icons.check_circle_outline),
                label: Text(user.isActive ? 'Deactivate' : 'Reactivate'),
              ),
              OutlinedButton.icon(
                key: const Key('detail-delete'),
                style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error),
                onPressed: () async {
                  if (await deleteUser(context, ref, user) && context.mounted) {
                    context.go('/admin/users');
                  }
                },
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        FillGrid(
          minItemWidth: 440,
          children: [
            _Section(
              key: const Key('section-account'),
              icon: Icons.badge_outlined,
              title: 'Account details',
              child: _Facts(account),
            ),
            ...sections,
          ],
        ),
      ],
    );
  }

  Widget _familyLink(BuildContext context, Map<String, dynamic> f) {
    final patient = f['patient'] == null ? null : _map(f['patient']);
    return _Section(
      key: const Key('section-family-link'),
      icon: Icons.family_restroom,
      title: 'Linked patient',
      child: patient == null
          ? const Text('Not linked to a patient yet (waiting for the patient to approve).')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Facts({
                  'Patient': '${patient['name'] ?? 'Unknown'}',
                  'Email': '${patient['email'] ?? '-'}',
                  'Assigned doctor': '${patient['assignedDoctor'] ?? 'Not assigned yet'}',
                  'Account': patient['isActive'] == false ? 'Deactivated' : 'Active',
                  if (f['linkedAt'] != null) 'Linked since': _when(f['linkedAt']),
                }),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const Key('open-linked-patient'),
                  onPressed: () => context.go('/admin/users/${patient['uid']}'),
                  icon: const Icon(Icons.person_search_outlined),
                  label: const Text('Open patient record'),
                ),
              ],
            ),
    );
  }

  List<Widget> _patient(BuildContext context, Map<String, dynamic> p) {
    final doctor = p['doctor'] == null ? null : _map(p['doctor']);
    final reading = p['latestReading'] == null ? null : _map(p['latestReading']);
    final risk = p['risk'] == null ? null : _map(p['risk']);
    final level = _level(risk?['level']);
    final records = _map(p['records']);
    return [
      _Section(
        key: const Key('section-health'),
        icon: Icons.monitor_heart_outlined,
        title: 'Health overview',
        child: _Facts({
          'Assigned doctor': doctor == null ? 'Not assigned yet' : '${doctor['name']}',
          'Latest reading': reading == null
              ? 'No readings yet'
              : '${reading['systolic']}/${reading['diastolic']} mmHg · ${_when(reading['timestamp'])}',
          'Readings (30 days)': '${p['readingsLast30Days'] ?? 0}',
          'Risk level': level == null ? 'Not assessed yet' : _levelName(level),
          'Records': '${records['total'] ?? 0} uploaded · ${records['shared'] ?? 0} shared',
          'Family members': _list(p['family']).isEmpty
              ? 'None linked'
              : _list(p['family']).map((f) => f['name']).join(', '),
        }, highlight: level == null ? null : riskColor(level)),
      ),
      _Section(
        key: const Key('section-meds'),
        icon: Icons.medication_outlined,
        title: 'Medications',
        child: _list(p['medications']).isEmpty
            ? const Text('No medications recorded.')
            : Column(children: [for (final m in _list(p['medications'])) _MedAdherence(m: m)]),
      ),
      _Section(
        key: const Key('section-appointments'),
        icon: Icons.event_outlined,
        title: 'Appointments',
        child: _Appointments(rows: _list(p['appointments']), otherLabel: 'with'),
      ),
    ];
  }

  List<Widget> _doctor(BuildContext context, AdminUser user, Map<String, dynamic> d) => [
    _Section(
      key: const Key('section-patients'),
      icon: Icons.people_outline,
      title: 'Assigned patients (${_list(d['patients']).length})',
      child: _list(d['patients']).isEmpty
          ? const Text('No patients assigned.')
          : Column(
              children: [
                for (final p in _list(d['patients']))
                  ListTile(
                    key: Key('doctor-patient-${p['uid']}'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      Icons.circle,
                      size: 12,
                      color: _level(p['riskLevel']) == null
                          ? Colors.grey
                          : riskColor(_level(p['riskLevel'])!),
                    ),
                    title: Text('${p['name']}${p['isActive'] == false ? ' (deactivated)' : ''}'),
                    subtitle: Text(
                      _level(p['riskLevel']) == null
                          ? 'Not assessed'
                          : '${_levelName(_level(p['riskLevel'])!)} risk',
                    ),
                    onTap: () => context.push('/admin/users/${p['uid']}'),
                  ),
              ],
            ),
    ),
    _Section(
      key: const Key('section-upcoming'),
      icon: Icons.event_outlined,
      title: 'Upcoming appointments',
      child: _Appointments(rows: _list(d['upcoming']), otherLabel: 'patient'),
    ),
    _Section(
      key: const Key('section-workload'),
      icon: Icons.work_outline,
      title: 'Workload',
      child: _Facts({
        'Completed visits': '${d['completedTotal'] ?? 0}',
        'Open clinical alerts': '${d['openAlerts'] ?? 0}',
      }),
    ),
  ];
}

class _Section extends StatelessWidget {
  const _Section({super.key, required this.title, required this.child, required this.icon});

  final String title;
  final Widget child;
  final IconData icon;

  @override
  Widget build(BuildContext context) => InfoSection(icon: icon, title: title, child: child);
}

class _Facts extends StatelessWidget {
  const _Facts(this.facts, {this.highlight});

  final Map<String, String> facts;
  final Color? highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = facts.entries.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < entries.length; i++)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              border: i == entries.length - 1
                  ? null
                  : Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 150,
                  child: Text(
                    entries[i].key,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Expanded(
                  child: entries[i].key == 'Risk level' && highlight != null
                      ? Align(
                          alignment: Alignment.centerLeft,
                          child: TablePill(entries[i].value, color: highlight!),
                        )
                      : Text(
                          entries[i].value,
                          style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                        ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// One medicine with its adherence as a coloured bar.
class _MedAdherence extends StatelessWidget {
  const _MedAdherence({required this.m});
  final Map<String, dynamic> m;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rate = (m['adherenceRate'] as num?)?.toDouble();
    final colour = rate == null
        ? theme.colorScheme.outline
        : rate >= 80
        ? Colors.green.shade600
        : rate >= 50
        ? Colors.amber.shade800
        : Colors.red.shade600;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('${m['name']} ${m['dosage'] ?? ''}', style: theme.textTheme.titleSmall),
              ),
              Text(
                rate == null ? '-' : 'Adherence ${rate.round()}%',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: colour,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          if (rate != null) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: (rate / 100).clamp(0.0, 1.0),
                minHeight: 5,
                color: colour,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Appointments extends StatelessWidget {
  const _Appointments({required this.rows, required this.otherLabel});

  final List<Map<String, dynamic>> rows;

  /// "with" (patient page: the doctor) or "patient" (doctor page).
  final String otherLabel;

  Widget _row(Map<String, dynamic> a) => ListTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    title: Text(_when(a['dateTime'])),
    subtitle: Text(
      [
        otherLabel == 'with' ? 'with ${a['other']}' : '${a['other']}',
        AppointmentType.fromValue('${a['type'] ?? 'checkup'}').label,
        '${a['status']}'.replaceAll('_', '-'),
        if (a['bookedBy'] == 'admin') 'Admin assigned',
        if (a['bookedBy'] == 'pharmacist') 'Walk-in',
        if (a['changeReason'] != null) '${a['changeReason']}',
      ].join(' · '),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const Text('No appointments.');
    // D-82: upcoming first, then the past appointment history.
    final now = DateTime.now();
    bool past(Map<String, dynamic> a) =>
        DateTime.tryParse('${a['dateTime']}')?.isBefore(now) ?? true;
    final upcoming = rows.where((a) => !past(a)).toList().reversed.toList();
    final history = rows.where(past).toList();
    final label = Theme.of(context).textTheme.labelLarge;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Upcoming (${upcoming.length})', key: const Key('appts-upcoming'), style: label),
        if (upcoming.isEmpty)
          const Padding(padding: EdgeInsets.symmetric(vertical: 4), child: Text('None booked.')),
        for (final a in upcoming) _row(a),
        const SizedBox(height: 8),
        Text('Past history (${history.length})', key: const Key('appts-history'), style: label),
        if (history.isEmpty)
          const Padding(padding: EdgeInsets.symmetric(vertical: 4), child: Text('No past visits.')),
        for (final a in history) _row(a),
      ],
    );
  }
}
