import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/enums.dart';
import '../../../shared/services/api/api_client.dart';
import 'package:go_router/go_router.dart';

import '../../admin/presentation/team_availability.dart';
import '../../admin/state/admin_providers.dart';
import '../data/appointments_repository.dart';
import '../domain/appointment_text.dart';
import '../state/appointment_providers.dart';

/// Admin: Patient Assignments (Fig 4.3.14.2; FR-7.2, FR-11.2, UC7.3, UC11.2; D-54, D-59):
/// requests on the left, each doctor's caseload against their limit on the right.
class AdminAssignmentsPage extends ConsumerWidget {
  const AdminAssignmentsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final header = [
      Text('Patient assignments', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 4),
      const Text(
        'New patients asking for a doctor, and doctors asking to hand a patient over. '
        'Check each doctor\'s caseload before assigning.',
      ),
      const SizedBox(height: 16),
    ];
    return LayoutBuilder(
      builder: (context, box) {
        const requests = _Requests();
        const team = TeamAvailability();
        if (box.maxWidth < 900) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [...header, requests, const SizedBox(height: 24), team],
          );
        }
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ...header,
            const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: requests),
                SizedBox(width: 24),
                Expanded(child: team),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _Requests extends ConsumerWidget {
  const _Requests();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final requests = ref.watch(pendingAssignmentRequestsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Doctor assignment requests', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        requests.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, _) => const Text('Could not load requests.'),
          data: (list) => list.isEmpty
              ? const Card(
                  key: Key('no-requests'),
                  child: ListTile(
                    leading: Icon(Icons.check_circle_outline),
                    title: Text('No pending requests.'),
                  ),
                )
              // D-82: every request card spans the column (they were sized to their text).
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [for (final r in list) _RequestCard(request: r)],
                ),
        ),
      ],
    );
  }
}

class _RequestCard extends ConsumerWidget {
  const _RequestCard({required this.request});

  final AssignmentRequest request;

  String _name(WidgetRef ref, String? uid) =>
      uid == null ? '-' : ref.watch(personProvider(uid)).value?.name ?? '…';

  Future<void> _approve(BuildContext context, WidgetRef ref) async {
    final doctor = await showDialog<String>(
      context: context,
      builder: (_) => _ChooseDoctor(
        initial: request.proposedDoctorId,
        exclude: request.kind == AssignmentRequestKind.reassign ? request.requestedBy : null,
      ),
    );
    if (doctor == null || !context.mounted) return;
    await _run(
      context,
      () => ref.read(appointmentsRepositoryProvider).approve(request.id, doctor),
      'Doctor assigned.',
    );
  }

  Future<void> _decline(BuildContext context, WidgetRef ref) async {
    // D-82: a reason is required; the requester sees it.
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => const _DeclineDialog(),
    );
    if (reason == null || !context.mounted) return;
    await _run(
      context,
      () => ref.read(appointmentsRepositoryProvider).decline(request.id, reason: reason),
      'Request declined.',
    );
  }

  Future<void> _run(BuildContext context, Future<void> Function() action, String done) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
      messenger.showSnackBar(SnackBar(content: Text(done)));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('Something went wrong. Try again.')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = request;
    final isNew = r.kind == AssignmentRequestKind.newPatient;
    return Card(
      key: Key('request-${r.id}'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isNew ? 'New patient needs a doctor' : 'Reassignment requested',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text('Patient: ${_name(ref, r.patientId)}'),
            const SizedBox(height: 8),
            _PatientSummary(uid: r.patientId), // D-82
            if (!isNew) Text('Requested by: ${_name(ref, r.requestedBy)}'),
            if (r.proposedDoctorId != null)
              Text('Suggested doctor: ${_name(ref, r.proposedDoctorId)}'),
            if (r.reason != null && r.reason!.isNotEmpty) Text('Reason: ${r.reason}'),
            Text(
              'Sent ${dateLabel(r.createdAt)}, ${timeLabel(r.createdAt)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  key: Key('approve-${r.id}'),
                  onPressed: () => _approve(context, ref),
                  child: const Text('Assign doctor'),
                ),
                OutlinedButton(
                  key: Key('decline-${r.id}'),
                  onPressed: () => _decline(context, ref),
                  child: const Text('Decline'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ChooseDoctor extends ConsumerStatefulWidget {
  const _ChooseDoctor({this.initial, this.exclude});

  final String? initial;
  final String? exclude;

  @override
  ConsumerState<_ChooseDoctor> createState() => _ChooseDoctorState();
}

class _ChooseDoctorState extends ConsumerState<_ChooseDoctor> {
  late String? _doctor = widget.initial;

  @override
  Widget build(BuildContext context) {
    final doctors = [
      for (final d in ref.watch(doctorsProvider).value ?? const <PersonName>[])
        if (d.uid != widget.exclude) d,
    ];
    // D-59: show each doctor's caseload; warn before assigning to a full one.
    final loads = ref.watch(doctorCaseloadsProvider).value ?? const {};
    final chosen = loads[_doctor];
    final full = chosen != null && chosen.capacity == Capacity.full;
    return AlertDialog(
      key: const Key('choose-doctor'),
      title: const Text('Assign a doctor'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<String>(
            key: const Key('choose-doctor-field'),
            initialValue: doctors.any((d) => d.uid == _doctor) ? _doctor : null,
            decoration: const InputDecoration(labelText: 'Doctor'),
            items: [
              for (final d in doctors)
                DropdownMenuItem(
                  value: d.uid,
                  child: Text(
                    loads[d.uid] == null
                        ? d.name
                        : '${d.name} · ${loads[d.uid]!.caseload ?? 0}/'
                              '${loads[d.uid]!.maxPatients ?? 30}',
                  ),
                ),
            ],
            onChanged: (v) => setState(() => _doctor = v),
          ),
          if (full)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '${chosen.name} is at capacity (${chosen.caseload}/${chosen.maxPatients}).',
                key: const Key('doctor-full'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const Key('choose-doctor-confirm'),
          onPressed: _doctor == null ? null : () => Navigator.of(context).pop(_doctor),
          child: Text(full ? 'Assign anyway' : 'Assign'),
        ),
      ],
    );
  }
}

/// D-82: a decline needs a reason (at least 5 characters); it is sent to the requester.
class _DeclineDialog extends StatefulWidget {
  const _DeclineDialog();

  @override
  State<_DeclineDialog> createState() => _DeclineDialogState();
}

class _DeclineDialogState extends State<_DeclineDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  bool get _ok => _reason.text.trim().length >= 5;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Decline request?'),
    content: SizedBox(
      width: 420,
      child: TextField(
        key: const Key('decline-reason'),
        controller: _reason,
        maxLength: 500,
        minLines: 2,
        maxLines: 4,
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(
          labelText: 'Reason (sent to the requester)',
          hintText: 'e.g. Please visit the clinic first to register in person.',
          helperText: 'Required, at least 5 characters.',
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Back')),
      FilledButton(
        key: const Key('decline-confirm'),
        onPressed: _ok ? () => Navigator.of(context).pop(_reason.text.trim()) : null,
        child: const Text('Decline'),
      ),
    ],
  );
}

/// D-82: who is asking, so the admin can decide (age, gender, phone, IC, latest BP, risk).
class _PatientSummary extends ConsumerWidget {
  const _PatientSummary({required this.uid});

  final String uid;

  static int? _age(String? iso) {
    final dob = iso == null ? null : DateTime.tryParse(iso);
    if (dob == null) return null;
    final now = DateTime.now();
    var age = now.year - dob.year;
    if (now.month < dob.month || (now.month == dob.month && now.day < dob.day)) age--;
    return age;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final detail = ref.watch(adminUserDetailProvider(uid));
    return Container(
      key: Key('patient-summary-$uid'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(10),
      ),
      child: detail.when(
        loading: () => const LinearProgressIndicator(),
        error: (_, _) => const Text('Could not load the patient details.'),
        data: (d) {
          final user = (d['user'] as Map?)?.cast<String, dynamic>() ?? const {};
          final profile = (d['profile'] as Map?)?.cast<String, dynamic>() ?? const {};
          final patient = (d['patient'] as Map?)?.cast<String, dynamic>() ?? const {};
          final reading = (patient['latestReading'] as Map?)?.cast<String, dynamic>();
          final risk = (patient['risk'] as Map?)?.cast<String, dynamic>();
          final age = _age(profile['dateOfBirth'] as String?);
          final gender = profile['gender'] as String?;
          final facts = <(IconData, String)>[
            if (age != null || gender != null)
              (
                Icons.person_outline,
                [
                  if (age != null) '$age years',
                  if (gender != null) '${gender[0].toUpperCase()}${gender.substring(1)}',
                ].join(' · '),
              ),
            if (user['email'] != null) (Icons.mail_outline, '${user['email']}'),
            if (profile['phone'] != null) (Icons.phone_outlined, '${profile['phone']}'),
            if (profile['icNumber'] != null) (Icons.badge_outlined, 'IC ${profile['icNumber']}'),
            (
              Icons.monitor_heart_outlined,
              reading == null
                  ? 'No BP readings yet'
                  : 'Latest BP ${reading['systolic']}/${reading['diastolic']} mmHg'
                        ' · ${patient['readingsLast30Days'] ?? 0} readings in 30 days',
            ),
            (Icons.shield_outlined, risk == null ? 'No risk score yet' : 'Risk: ${risk['level']}'),
            (
              Icons.assignment_outlined,
              profile['onboardingComplete'] == true
                  ? 'Health profile complete'
                  : 'Health profile not finished',
            ),
          ];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 16,
                runSpacing: 6,
                children: [
                  for (final (icon, text) in facts)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icon, size: 16, color: theme.colorScheme.primary),
                        const SizedBox(width: 4),
                        Text(text),
                      ],
                    ),
                ],
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  key: Key('open-patient-$uid'),
                  onPressed: () => context.go('/admin/users/$uid'),
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: const Text('Full profile'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
