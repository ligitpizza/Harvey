import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/enums.dart';
import '../../shared/models/health_models.dart';
import '../../shared/providers/api_providers.dart';
import '../../shared/services/api/api_client.dart';
import '../appointments/domain/appointment_text.dart' show dateLabel, timeLabel;
import '../appointments/presentation/admin_booking_dialog.dart';

/// D-80 staff leave: doctors and pharmacists apply; the admin approves or rejects and
/// moves the appointments that clash with a doctor's approved leave.

class LeaveRequest {
  const LeaveRequest({
    required this.id,
    required this.staffName,
    required this.staffRole,
    required this.startDate,
    required this.endDate,
    required this.days,
    required this.reason,
    required this.status,
    this.decidedBy,
    this.decisionNote,
    this.affected,
  });

  final String id;
  final String staffName;
  final String staffRole;
  final DateTime startDate;
  final DateTime endDate;
  final int days;
  final String reason;

  /// pending / approved / rejected / cancelled
  final String status;
  final String? decidedBy;
  final String? decisionNote;

  /// Booked appointments in the period (doctors, while pending).
  final int? affected;

  factory LeaveRequest.fromJson(Map<String, dynamic> j) => LeaveRequest(
    id: j['id'] as String,
    staffName: j['staffName'] as String? ?? 'Staff',
    staffRole: j['staffRole'] as String? ?? '',
    startDate: DateTime.parse(j['startDate'] as String),
    endDate: DateTime.parse(j['endDate'] as String),
    days: (j['days'] as num?)?.toInt() ?? 1,
    reason: j['reason'] as String? ?? '',
    status: j['status'] as String? ?? 'pending',
    decidedBy: j['decidedBy'] as String?,
    decisionNote: j['decisionNote'] as String?,
    affected: (j['affectedAppointments'] as num?)?.toInt(),
  );

  bool get canCancel {
    final today = DateTime.now();
    final started = !DateTime(today.year, today.month, today.day).isBefore(startDate);
    return status == 'pending' || (status == 'approved' && !started);
  }
}

class RescheduleItem {
  const RescheduleItem({
    required this.id,
    required this.patientId,
    required this.patientName,
    required this.doctorId,
    required this.doctorName,
    required this.dateTime,
    required this.type,
  });

  final String id;
  final String patientId;
  final String patientName;
  final String doctorId;
  final String doctorName;
  final DateTime dateTime;
  final AppointmentType type;

  factory RescheduleItem.fromJson(Map<String, dynamic> j) => RescheduleItem(
    id: j['id'] as String,
    patientId: j['patientId'] as String,
    patientName: j['patientName'] as String? ?? 'Patient',
    doctorId: j['doctorId'] as String,
    doctorName: j['doctorName'] as String? ?? 'Doctor',
    dateTime: DateTime.parse(j['dateTime'] as String),
    type: AppointmentType.fromValue(j['type'] as String?),
  );

  /// Enough of the appointment for the admin's edit dialog (D-60).
  Appointment toAppointment() => Appointment(
    id: id,
    patientId: patientId,
    doctorId: doctorId,
    dateTime: dateTime,
    status: AppointmentStatus.booked,
    type: type,
    needsReschedule: true,
  );
}

final leaveRequestsProvider = FutureProvider.autoDispose<List<LeaveRequest>>((ref) async {
  final res = await ref.watch(apiClientProvider).leaveRequests();
  return [
    for (final j in (res['leave'] as List? ?? const []))
      LeaveRequest.fromJson(j as Map<String, dynamic>),
  ];
});

final leaveRescheduleProvider = FutureProvider.autoDispose<List<RescheduleItem>>((ref) async {
  final res = await ref.watch(apiClientProvider).leaveReschedule();
  return [
    for (final j in (res['appointments'] as List? ?? const []))
      RescheduleItem.fromJson(j as Map<String, dynamic>),
  ];
});

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String dayText(DateTime d) => '${_days[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}';

String rangeText(DateTime a, DateTime b) => a == b ? dayText(a) : '${dayText(a)} – ${dayText(b)}';

String isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

Color leaveColor(String status) => switch (status) {
  'approved' => Colors.green.shade600,
  'rejected' => Colors.red.shade600,
  'cancelled' => Colors.grey,
  _ => Colors.orange.shade700,
};

String leaveLabel(String status) => switch (status) {
  'approved' => 'Approved',
  'rejected' => 'Not approved',
  'cancelled' => 'Cancelled',
  _ => 'Pending',
};

class _LeaveCard extends StatelessWidget {
  const _LeaveCard({required this.r, this.admin = false, this.actions = const []});

  final LeaveRequest r;
  final bool admin;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = leaveColor(r.status);
    return Card(
      key: Key('leave-${r.id}'),
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: color, width: 5)),
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.beach_access_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    admin
                        ? '${r.staffName} · ${rangeText(r.startDate, r.endDate)}'
                        : rangeText(r.startDate, r.endDate),
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                Chip(
                  label: Text(leaveLabel(r.status)),
                  backgroundColor: color.withValues(alpha: 0.15),
                  side: BorderSide(color: color),
                ),
              ],
            ),
            Text(
              [
                '${r.days} day${r.days == 1 ? '' : 's'}',
                if (admin) r.staffRole == 'doctor' ? 'Doctor' : 'Pharmacist',
              ].join(' · '),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 6),
            Text(r.reason),
            if (r.status == 'pending' && (r.affected ?? 0) > 0)
              Container(
                key: Key('leave-clash-${r.id}'),
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.deepOrange.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${r.affected} booked appointment(s) fall in this period'
                  '${admin ? '. Approving flags them for rescheduling.' : '.'}',
                ),
              ),
            if (r.decidedBy != null && r.status != 'pending')
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '${leaveLabel(r.status)} by ${r.decidedBy}'
                  '${(r.decisionNote ?? '').isEmpty ? '' : ': ${r.decisionNote}'}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            if (actions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(alignment: WrapAlignment.end, spacing: 8, children: actions),
              ),
          ],
        ),
      ),
    );
  }
}

Widget _error(VoidCallback retry, String what) =>
    TextButton(onPressed: retry, child: Text('Could not load $what. Retry'));

void _snack(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

/// Doctor and pharmacist: my leave.
class StaffLeavePage extends ConsumerWidget {
  const StaffLeavePage({super.key});

  Future<void> _apply(BuildContext context, WidgetRef ref) async {
    final sent = await showDialog<bool>(context: context, builder: (_) => const _ApplyDialog());
    if (sent == true) ref.invalidate(leaveRequestsProvider);
  }

  Future<void> _cancel(BuildContext context, WidgetRef ref, LeaveRequest r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Cancel this leave?'),
        content: Text(rangeText(r.startDate, r.endDate)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Cancel leave')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(apiClientProvider).cancelLeave(r.id);
      ref.invalidate(leaveRequestsProvider);
    } on ApiException catch (e) {
      if (context.mounted) _snack(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(leaveRequestsProvider);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('My leave', style: Theme.of(context).textTheme.headlineSmall),
            FilledButton.icon(
              key: const Key('apply-leave'),
              onPressed: () => _apply(context, ref),
              icon: const Icon(Icons.add),
              label: const Text('Apply for leave'),
            ),
            IconButton(
              tooltip: 'Refresh',
              onPressed: () => ref.invalidate(leaveRequestsProvider),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        const Text(
          'The admin approves or rejects leave and you get a notification. If you are a doctor, '
          'patients booked on your leave days are moved by the admin.',
        ),
        const SizedBox(height: 12),
        list.when(
          loading: () => const LinearProgressIndicator(),
          error: (_, _) => _error(() => ref.invalidate(leaveRequestsProvider), 'your leave'),
          data: (rs) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (rs.isEmpty)
                const Padding(
                  key: Key('leave-empty'),
                  padding: EdgeInsets.all(16),
                  child: Text('No leave applied yet.'),
                ),
              for (final r in rs)
                _LeaveCard(
                  r: r,
                  actions: [
                    if (r.canCancel)
                      TextButton(
                        key: Key('cancel-leave-${r.id}'),
                        onPressed: () => _cancel(context, ref, r),
                        child: const Text('Cancel leave'),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ApplyDialog extends ConsumerStatefulWidget {
  const _ApplyDialog();

  @override
  ConsumerState<_ApplyDialog> createState() => _ApplyDialogState();
}

class _ApplyDialogState extends ConsumerState<_ApplyDialog> {
  final _reason = TextEditingController();
  DateTimeRange? _range;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final picked = await showDateRangePicker(
      context: context,
      firstDate: today,
      lastDate: today.add(const Duration(days: 365)),
      initialDateRange: _range,
      helpText: 'Leave dates',
    );
    if (picked != null) setState(() => _range = picked);
  }

  Future<void> _submit() async {
    final range = _range;
    if (range == null) return setState(() => _error = 'Choose the leave dates.');
    if (_reason.text.trim().length < 3) return setState(() => _error = 'Give a short reason.');
    if (range.duration.inDays + 1 > 30) {
      return setState(() => _error = 'Apply for at most 30 days at a time.');
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(apiClientProvider)
          .applyLeave(isoDate(range.start), isoDate(range.end), _reason.text.trim());
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final range = _range;
    return AlertDialog(
      title: const Text('Apply for leave'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            OutlinedButton.icon(
              key: const Key('leave-dates'),
              onPressed: _pick,
              icon: const Icon(Icons.date_range),
              label: Text(range == null ? 'Choose dates' : rangeText(range.start, range.end)),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('leave-reason'),
              controller: _reason,
              maxLength: 500,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Reason',
                hintText: 'e.g. Annual leave, medical leave, conference',
              ),
            ),
            if (_error != null)
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          key: const Key('leave-submit'),
          onPressed: _busy ? null : _submit,
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

/// Admin: leave requests to decide, and appointments to move.
class AdminLeavePage extends ConsumerStatefulWidget {
  const AdminLeavePage({super.key});

  @override
  ConsumerState<AdminLeavePage> createState() => _AdminLeavePageState();
}

class _AdminLeavePageState extends ConsumerState<AdminLeavePage> {
  bool _pendingOnly = true;

  void _refresh() {
    ref.invalidate(leaveRequestsProvider);
    ref.invalidate(leaveRescheduleProvider);
  }

  Future<void> _decide(LeaveRequest r, String decision) async {
    // null = cancelled; '' = no note.
    final text = await showDialog<String>(
      context: context,
      builder: (_) => _DecisionDialog(r: r, decision: decision),
    );
    if (text == null) return;
    try {
      final res = await ref
          .read(apiClientProvider)
          .decideLeave(r.id, decision, note: text.isEmpty ? null : text);
      final flagged = (res['flaggedAppointments'] as num?)?.toInt() ?? 0;
      if (mounted) {
        _snack(
          context,
          decision == 'approve'
              ? 'Leave approved${flagged > 0 ? '. $flagged appointment(s) to reschedule.' : '.'}'
              : 'Leave rejected.',
        );
      }
      _refresh();
    } on ApiException catch (e) {
      if (mounted) _snack(context, e.message);
    }
  }

  Future<void> _reschedule(RescheduleItem item) async {
    final changed = await showAdminBooking(context, editing: item.toAppointment());
    if (changed) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final list = ref.watch(leaveRequestsProvider);
    final todo = ref.watch(leaveRescheduleProvider);
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Expanded(child: Text('Staff leave', style: theme.textTheme.headlineSmall)),
            IconButton(tooltip: 'Refresh', onPressed: _refresh, icon: const Icon(Icons.refresh)),
          ],
        ),
        const Text(
          "Approve or reject doctors' and pharmacists' leave. Approved doctor leave blocks their "
          'slots and lists the clashing appointments below to move.',
        ),
        const SizedBox(height: 16),
        Text('Appointments to reschedule', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        todo.when(
          loading: () => const LinearProgressIndicator(),
          error: (_, _) => _error(() => ref.invalidate(leaveRescheduleProvider), 'appointments'),
          data: (items) => items.isEmpty
              ? const Card(
                  key: Key('reschedule-empty'),
                  child: ListTile(
                    leading: Icon(Icons.event_available_outlined),
                    title: Text('Nothing to move.'),
                  ),
                )
              : Column(
                  children: [
                    for (final i in items)
                      Card(
                        key: Key('move-${i.id}'),
                        color: Colors.deepOrange.withValues(alpha: 0.08),
                        child: ListTile(
                          leading: const Icon(Icons.event_busy_outlined, color: Colors.deepOrange),
                          title: Text(
                            '${dateLabel(i.dateTime)}, ${timeLabel(i.dateTime)} · ${i.patientName}',
                          ),
                          subtitle: Text('${i.doctorName} is on leave · ${i.type.label}'),
                          trailing: FilledButton.tonal(
                            key: Key('move-button-${i.id}'),
                            onPressed: () => _reschedule(i),
                            child: const Text('Reschedule'),
                          ),
                        ),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(child: Text('Leave requests', style: theme.textTheme.titleMedium)),
            FilterChip(
              key: const Key('leave-pending-only'),
              label: const Text('Pending only'),
              selected: _pendingOnly,
              onSelected: (v) => setState(() => _pendingOnly = v),
            ),
          ],
        ),
        const SizedBox(height: 8),
        list.when(
          loading: () => const LinearProgressIndicator(),
          error: (_, _) => _error(() => ref.invalidate(leaveRequestsProvider), 'leave requests'),
          data: (rs) {
            final shown = [
              for (final r in rs)
                if (!_pendingOnly || r.status == 'pending') r,
            ];
            if (shown.isEmpty) {
              return Padding(
                key: const Key('admin-leave-empty'),
                padding: const EdgeInsets.all(16),
                child: Text(_pendingOnly ? 'No leave waiting for a decision.' : 'No leave yet.'),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final r in shown)
                  _LeaveCard(
                    r: r,
                    admin: true,
                    actions: [
                      if (r.status == 'pending') ...[
                        OutlinedButton(
                          key: Key('reject-${r.id}'),
                          onPressed: () => _decide(r, 'reject'),
                          child: const Text('Reject'),
                        ),
                        FilledButton(
                          key: Key('approve-${r.id}'),
                          onPressed: () => _decide(r, 'approve'),
                          child: const Text('Approve'),
                        ),
                      ],
                    ],
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _DecisionDialog extends StatefulWidget {
  const _DecisionDialog({required this.r, required this.decision});

  final LeaveRequest r;
  final String decision;

  @override
  State<_DecisionDialog> createState() => _DecisionDialogState();
}

class _DecisionDialogState extends State<_DecisionDialog> {
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.r;
    final approve = widget.decision == 'approve';
    return AlertDialog(
      title: Text(approve ? 'Approve leave?' : 'Reject leave?'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${r.staffName}: ${rangeText(r.startDate, r.endDate)}'),
            if (approve && (r.affected ?? 0) > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '${r.affected} appointment(s) will be flagged and the patients told the '
                  'clinic will move them. Reschedule them from this page.',
                ),
              ),
            TextField(
              key: const Key('leave-note'),
              controller: _note,
              maxLength: 500,
              decoration: const InputDecoration(labelText: 'Note to the staff member (optional)'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Back')),
        FilledButton(
          key: const Key('leave-confirm'),
          onPressed: () => Navigator.pop(context, _note.text.trim()),
          child: Text(approve ? 'Approve' : 'Reject'),
        ),
      ],
    );
  }
}
