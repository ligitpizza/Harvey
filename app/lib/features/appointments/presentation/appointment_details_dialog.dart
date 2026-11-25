import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/enums.dart';
import '../../../shared/models/health_models.dart';
import '../../../shared/services/api/api_client.dart';
import '../../dashboard/state/dashboard_providers.dart';
import '../domain/appointment_text.dart';
import '../state/appointment_providers.dart';
import 'admin_booking_dialog.dart';
import 'cover_labels.dart';
import 'pre_visit_summary_page.dart';

/// Doctor (calendar, patient page) or admin (overview, calendar) opens an appointment:
/// its pending request (D-55: approve / decline), the visit outcome (D-56), cancel with a
/// reason, and the pre-visit summary (UC7.5). D-127: a full page instead of a popup.
Future<void> showAppointmentDetails(
  BuildContext context,
  Appointment a, {
  String? patientName,
  String? doctorName,
  bool forAdmin = false,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => AppointmentDetailsPage(
      appointment: a,
      patientName: patientName,
      doctorName: doctorName,
      forAdmin: forAdmin,
    ),
  ),
);

/// D-127: common reasons offered when staff cancel; the text stays editable.
const cancelReasons = [
  'Doctor unavailable',
  'Clinic closed that day',
  'Needs a different type of visit',
  'Booked by mistake',
];

class AppointmentDetailsPage extends ConsumerStatefulWidget {
  const AppointmentDetailsPage({
    super.key,
    required this.appointment,
    this.patientName,
    this.doctorName,
    this.forAdmin = false,
  });

  final Appointment appointment;
  final String? patientName;
  final String? doctorName;
  final bool forAdmin;

  @override
  ConsumerState<AppointmentDetailsPage> createState() => _AppointmentDetailsPageState();
}

class _AppointmentDetailsPageState extends ConsumerState<AppointmentDetailsPage> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action, String done) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    try {
      await action();
      nav.pop();
      messenger.showSnackBar(SnackBar(content: Text(done)));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('Something went wrong. Try again.')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _decline() {
    final text = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Decline request'),
        content: SizedBox(
          width: 420,
          child: TextField(
            key: const Key('staff-note'),
            controller: text,
            maxLength: 300,
            maxLines: 3,
            minLines: 2,
            decoration: const InputDecoration(
              labelText: 'Message to the patient (optional)',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(), child: const Text('Back')),
          FilledButton(
            key: const Key('staff-note-confirm'),
            onPressed: () => Navigator.of(c).pop(text.text.trim()),
            child: const Text('Decline'),
          ),
        ],
      ),
    );
  }

  /// D-127: cancel with a required reason (quick picks or typed); says who is told.
  Future<String?> _cancel() {
    final text = TextEditingController();
    final told = widget.forAdmin
        ? 'The patient and their doctor will be notified with this reason.'
        : 'The patient and the admin team will be notified with this reason.';
    return showDialog<String>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setState) {
          final theme = Theme.of(c);
          return AlertDialog(
            key: const Key('cancel-dialog'),
            icon: Icon(Icons.event_busy, color: theme.colorScheme.error),
            title: const Text('Cancel appointment'),
            content: SizedBox(
              width: 460,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Quick reasons', style: theme.textTheme.labelLarge),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final r in cancelReasons)
                        ActionChip(
                          key: Key('cancel-reason-$r'),
                          label: Text(r),
                          onPressed: () => setState(() => text.text = r),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('staff-note'),
                    controller: text,
                    maxLength: 300,
                    maxLines: 3,
                    minLines: 2,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Reason (required)',
                      helperText: 'At least 3 characters.',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        Icons.notifications_outlined,
                        size: 16,
                        color: theme.colorScheme.outline,
                      ),
                      const SizedBox(width: 6),
                      Expanded(child: Text(told, style: theme.textTheme.bodySmall)),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(c).pop(), child: const Text('Keep it')),
              FilledButton(
                key: const Key('staff-note-confirm'),
                style: FilledButton.styleFrom(backgroundColor: theme.colorScheme.error),
                onPressed: text.text.trim().length < 3
                    ? null
                    : () => Navigator.of(c).pop(text.text.trim()),
                child: const Text('Cancel appointment'),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.appointment;
    final repo = ref.read(appointmentsRepositoryProvider);
    final now = ref.watch(nowProvider)();
    final theme = Theme.of(context);
    final active = a.isActive;
    final p = a.pendingChange;

    final panels = <Widget>[
      _Header(
        appointment: a,
        patientName: widget.patientName,
        doctorName: widget.doctorName,
        forAdmin: widget.forAdmin,
      ),
      if (a.isCancelled)
        _Panel(
          key: const Key('details-cancel-reason'),
          color: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
          icon: Icons.event_busy,
          title: 'Cancelled${a.cancelledBy == null ? '' : ' by ${a.cancelledBy}'}',
          child: Text(a.changeReason == null ? 'No reason given.' : 'Reason: ${a.changeReason}'),
        ),
      if (a.canRecordOutcome(now))
        _Panel(
          key: const Key('details-outcome'),
          color: a.isOverdue(now) ? Colors.red.withValues(alpha: 0.1) : null,
          icon: a.isOverdue(now) ? Icons.pending_actions : Icons.play_circle_outline,
          title: a.isOverdue(now)
              ? 'Not completed yet: record how the visit went.'
              : 'The appointment has started.',
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                key: const Key('details-complete'),
                icon: const Icon(Icons.check),
                onPressed: _busy
                    ? null
                    : () => _run(
                        () => repo.recordOutcome(a.id, completed: true),
                        'Appointment completed.',
                      ),
                label: const Text('Complete appointment'),
              ),
              OutlinedButton.icon(
                key: const Key('details-no-show'),
                icon: const Icon(Icons.person_off_outlined),
                onPressed: _busy
                    ? null
                    : () => _run(
                        () => repo.recordOutcome(a.id, completed: false),
                        'Marked as no-show.',
                      ),
                label: const Text('No-show'),
              ),
            ],
          ),
        ),
      if (p != null && active)
        _Panel(
          key: const Key('details-pending'),
          color: Colors.amber.withValues(alpha: 0.18),
          icon: Icons.mark_email_unread_outlined,
          title: p.isCancel
              ? 'Patient asks to cancel'
              : 'Patient asks to move to ${whenLabel(p.dateTime!, now)}',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Reason: ${p.reasonText}'),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    key: const Key('details-approve'),
                    onPressed: _busy
                        ? null
                        : () => _run(() => repo.decide(a.id, approve: true), 'Request approved.'),
                    child: const Text('Approve'),
                  ),
                  OutlinedButton(
                    key: const Key('details-decline'),
                    onPressed: _busy
                        ? null
                        : () async {
                            final note = await _decline();
                            if (note == null) return;
                            await _run(
                              () => repo.decide(a.id, approve: false, note: note),
                              'Request declined.',
                            );
                          },
                    child: const Text('Decline'),
                  ),
                ],
              ),
            ],
          ),
        ),
      if (active)
        _Panel(
          icon: Icons.tune,
          title: 'Manage',
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              // D-60: the admin changes time, doctor or type straight away.
              if (widget.forAdmin)
                OutlinedButton.icon(
                  key: const Key('details-edit'),
                  icon: const Icon(Icons.edit_calendar_outlined),
                  onPressed: () async {
                    final nav = Navigator.of(context);
                    if (await showAdminBooking(context, editing: a)) nav.pop();
                  },
                  label: const Text('Edit'),
                ),
              OutlinedButton.icon(
                key: const Key('details-cancel'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                  side: BorderSide(color: theme.colorScheme.error.withValues(alpha: 0.5)),
                ),
                icon: const Icon(Icons.event_busy),
                onPressed: _busy
                    ? null
                    : () async {
                        final reason = await _cancel();
                        if (reason == null || reason.isEmpty) return;
                        await _run(() => repo.staffCancel(a.id, reason), 'Appointment cancelled.');
                      },
                label: const Text('Cancel appointment'),
              ),
            ],
          ),
        ),
    ];

    final summary = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
          child: Text(
            'Pre-visit summary',
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        Expanded(child: PreVisitSummaryView(appointmentId: a.id)),
      ],
    );

    return Scaffold(
      key: const Key('appointment-details'),
      appBar: AppBar(
        title: const Text('Appointment'),
        actions: [
          if (!widget.forAdmin)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton.icon(
                icon: const Icon(Icons.person_outline),
                onPressed: () {
                  Navigator.of(context).pop();
                  context.go('/doctor/patient/${a.patientId}');
                },
                label: const Text('Open patient'),
              ),
            ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, box) {
          final left = ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final w in panels) Padding(padding: const EdgeInsets.only(bottom: 12), child: w),
            ],
          );
          if (box.maxWidth >= 900) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 440, child: left),
                const VerticalDivider(width: 1),
                Expanded(
                  child: Padding(padding: const EdgeInsets.only(top: 16), child: summary),
                ),
              ],
            );
          }
          // Narrow: actions first, then the summary below.
          return Column(
            children: [
              Flexible(child: left),
              const Divider(height: 1),
              Expanded(
                flex: 2,
                child: Padding(padding: const EdgeInsets.only(top: 12), child: summary),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Patient, type, status, date and doctor at the top of the page.
class _Header extends StatelessWidget {
  const _Header({
    required this.appointment,
    required this.patientName,
    required this.doctorName,
    required this.forAdmin,
  });

  final Appointment appointment;
  final String? patientName;
  final String? doctorName;
  final bool forAdmin;

  Color _statusColor(AppointmentStatus s) => switch (s) {
    AppointmentStatus.completed => Colors.green.shade700,
    AppointmentStatus.cancelled => Colors.red.shade700,
    AppointmentStatus.noShow => Colors.orange.shade800,
    _ => Colors.blue.shade700,
  };

  @override
  Widget build(BuildContext context) {
    final a = appointment;
    final theme = Theme.of(context);
    final status = _statusColor(a.status);
    final name = patientName ?? 'Patient';
    Widget chip(String label, Color c, {Key? key}) => Container(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(color: c, fontWeight: FontWeight.w600),
      ),
    );
    return Card(
      key: const Key('details-header'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: Text(
                    name.characters.first.toUpperCase(),
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      Text(a.type.label, style: theme.textTheme.bodyMedium),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Icon(Icons.event, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${dateLabel(a.dateTime)}, ${timeLabel(a.dateTime)}',
                    key: const Key('details-when'),
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            if (doctorName != null) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(Icons.medical_services_outlined, size: 20, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Text(doctorName!),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                chip(a.status.label, status, key: const Key('details-status')),
                if (a.isAdminAssigned) const AdminAssignedBadge(),
                if (a.isCover) CoverTag(appointment: a, forOwnDoctor: forAdmin),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A titled block with an icon; [color] tints it for states that need attention.
class _Panel extends StatelessWidget {
  const _Panel({
    super.key,
    required this.icon,
    required this.title,
    required this.child,
    this.color,
  });

  final IconData icon;
  final String title;
  final Widget child;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      color: color,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}
