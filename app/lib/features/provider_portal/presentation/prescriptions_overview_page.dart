import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/providers/api_providers.dart';
import '../../../shared/services/api/api_client.dart';
import '../../appointments/domain/appointment_text.dart' show dateLabel;
import '../../orders/data/order_models.dart';
import '../../../shared/widgets/page_header.dart';

/// D-78 Prescription management (doctor only): every prescription the doctor issued.
class DoctorPrescription {
  const DoctorPrescription({
    required this.id,
    required this.patientId,
    required this.patientName,
    required this.details,
    required this.isRecurring,
    this.itemCount = 0,
    this.total,
    this.issuedAt,
    this.orderRef,
    this.orderStatus,
    this.paymentStatus,
    this.cancelReason,
    this.cancelledBy,
  });

  /// D-132: why the latest order was cancelled, and by whom (pharmacist / admin / doctor).
  final String? cancelReason;
  final String? cancelledBy;

  bool get cancelledByPharmacy =>
      orderStatus == 'cancelled' && (cancelledBy == 'pharmacist' || cancelledBy == 'admin');

  final String id;
  final String patientId;
  final String patientName;
  final String details;
  final bool isRecurring;
  final int itemCount;
  final double? total;
  final DateTime? issuedAt;
  final String? orderRef;
  final String? orderStatus;
  final String? paymentStatus;

  factory DoctorPrescription.fromApi(Map<String, dynamic> j) {
    final o = j['latestOrder'] as Map<String, dynamic>?;
    return DoctorPrescription(
      id: '${j['id']}',
      patientId: '${j['patientId']}',
      patientName: j['patientName'] as String? ?? 'Patient',
      details: j['medicationDetails'] as String? ?? '',
      isRecurring: j['isRecurring'] as bool? ?? false,
      itemCount: (j['items'] as List<dynamic>? ?? const []).length,
      total: (j['total'] as num?)?.toDouble(),
      issuedAt: DateTime.tryParse('${j['issuedAt']}'),
      orderRef: o?['ref'] as String?,
      orderStatus: o?['status'] as String?,
      paymentStatus: o?['paymentStatus'] as String?,
      cancelReason: o?['cancelReason'] as String?,
      cancelledBy: o?['cancelledBy'] as String?,
    );
  }
}

final doctorPrescriptionsProvider = FutureProvider.autoDispose<List<DoctorPrescription>>((
  ref,
) async {
  final j = await ref.watch(apiClientProvider).doctorPrescriptions();
  return [
    for (final r in j['prescriptions'] as List<dynamic>? ?? const [])
      DoctorPrescription.fromApi(r as Map<String, dynamic>),
  ];
}, retry: (_, _) => null);

String orderLabel(String? status) =>
    Fulfilment.values.where((f) => f.value == status).firstOrNull?.label ?? 'No order yet';

Color orderColor(String? status) => switch (status) {
  'awaiting_confirmation' || 'awaiting_payment' => Colors.orange.shade700,
  'preparing' || 'ready_for_collection' || 'ready_for_delivery' => Colors.blue.shade600,
  'collected' || 'delivered' => Colors.green.shade600,
  'out_of_stock' || 'failed' => Colors.red.shade600,
  _ => Colors.blueGrey,
};

class PrescriptionsOverviewPage extends ConsumerStatefulWidget {
  const PrescriptionsOverviewPage({super.key});

  @override
  ConsumerState<PrescriptionsOverviewPage> createState() => _State();
}

class _State extends ConsumerState<PrescriptionsOverviewPage> {
  String _query = '';
  String _filter = 'all'; // all | repeating | one_off

  Future<void> _stop(DoctorPrescription p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Stop the monthly repeat?'),
        content: Text(
          '${p.patientName} will stop getting a new order each month. Orders already started '
          'are not changed.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Stop')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(apiClientProvider).setRecurring(p.id, false);
      ref.invalidate(doctorPrescriptionsProvider);
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = ref.watch(doctorPrescriptionsProvider);
    final all = list.value ?? const <DoctorPrescription>[];
    final q = _query.toLowerCase();
    final shown = [
      for (final p in all)
        if ((q.isEmpty ||
                p.patientName.toLowerCase().contains(q) ||
                p.details.toLowerCase().contains(q)) &&
            (_filter == 'all' || (_filter == 'repeating') == p.isRecurring))
          p,
    ];
    int count(bool Function(DoctorPrescription) t) => all.where(t).length;
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        PageHeader(
          title: 'Prescriptions',
          subtitle: 'Every prescription you issued, with its latest order.',
          icon: Icons.medication_outlined,
          color: Colors.teal,
          actions: [
            IconButton(
              tooltip: 'Refresh',
              onPressed: () => ref.invalidate(doctorPrescriptionsProvider),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _Count('Total', all.length, Colors.blueGrey),
            _Count('Repeating monthly', count((p) => p.isRecurring), Colors.blue.shade600),
            _Count(
              'Awaiting patient',
              count(
                (p) =>
                    p.orderStatus == 'awaiting_payment' || p.orderStatus == 'awaiting_confirmation',
              ),
              Colors.orange.shade700,
            ),
            _Count(
              'Out of stock',
              count((p) => p.orderStatus == 'out_of_stock'),
              Colors.red.shade600,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 320,
              child: TextField(
                key: const Key('rx-search'),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Patient or medicine',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _query = v.trim()),
              ),
            ),
            SegmentedButton<String>(
              key: const Key('rx-filter'),
              segments: const [
                ButtonSegment(value: 'all', label: Text('All')),
                ButtonSegment(value: 'repeating', label: Text('Repeating')),
                ButtonSegment(value: 'one_off', label: Text('One-off')),
              ],
              selected: {_filter},
              onSelectionChanged: (s) => setState(() => _filter = s.first),
            ),
          ],
        ),
        const SizedBox(height: 12),
        list.when(
          loading: () => const LinearProgressIndicator(),
          error: (_, _) => TextButton(
            onPressed: () => ref.invalidate(doctorPrescriptionsProvider),
            child: const Text('Could not load prescriptions. Retry'),
          ),
          data: (_) => shown.isEmpty
              ? const Padding(
                  key: Key('rx-empty'),
                  padding: EdgeInsets.all(16),
                  child: Text('No prescriptions match.'),
                )
              // D-79: every card the full width of the list, one under the other.
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final p in shown)
                      Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        key: Key('rx-${p.id}'),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Wrap(
                                spacing: 8,
                                runSpacing: 4,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Text(p.patientName, style: theme.textTheme.titleMedium),
                                  if (p.isRecurring)
                                    const Chip(
                                      visualDensity: VisualDensity.compact,
                                      avatar: Icon(Icons.repeat, size: 16),
                                      label: Text('Monthly'),
                                    ),
                                  _OrderChip(p.orderStatus),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(p.details),
                              if (p.cancelledByPharmacy) CancelledOrderNotice(prescription: p),
                              Text(
                                [
                                  if (p.issuedAt != null) 'Issued ${dateLabel(p.issuedAt!)}',
                                  if (p.total != null) 'RM${p.total!.toStringAsFixed(2)}/month',
                                  if (p.orderRef != null) 'Order ${p.orderRef}',
                                ].join(' · '),
                                style: theme.textTheme.bodySmall,
                              ),
                              const SizedBox(height: 4),
                              Wrap(
                                spacing: 4,
                                children: [
                                  TextButton.icon(
                                    key: Key('rx-open-${p.id}'),
                                    onPressed: () => context.go('/doctor/patient/${p.patientId}'),
                                    icon: const Icon(Icons.person_outline),
                                    label: const Text('Patient'),
                                  ),
                                  TextButton.icon(
                                    key: Key('rx-edit-${p.id}'),
                                    onPressed: () =>
                                        context.go('/doctor/patient/${p.patientId}/prescriptions'),
                                    icon: const Icon(Icons.edit_outlined),
                                    label: const Text('Edit'),
                                  ),
                                  if (p.isRecurring)
                                    TextButton.icon(
                                      key: Key('rx-stop-${p.id}'),
                                      onPressed: () => _stop(p),
                                      icon: const Icon(Icons.stop_circle_outlined),
                                      label: const Text('Stop monthly repeat'),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _Count extends StatelessWidget {
  const _Count(this.label, this.value, this.color);
  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: color.withValues(alpha: 0.5)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$value',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: color),
        ),
        Text(label),
      ],
    ),
  );
}

class _OrderChip extends StatelessWidget {
  const _OrderChip(this.status);
  final String? status;

  @override
  Widget build(BuildContext context) {
    final c = orderColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        orderLabel(status),
        style: TextStyle(color: c, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// D-132: the pharmacy cancelled this prescription's order. Shows why, and lets the doctor
/// send a new order (the patient confirms and pays it as usual).
class CancelledOrderNotice extends ConsumerStatefulWidget {
  const CancelledOrderNotice({super.key, required this.prescription});

  final DoctorPrescription prescription;

  @override
  ConsumerState<CancelledOrderNotice> createState() => _CancelledOrderNoticeState();
}

class _CancelledOrderNoticeState extends ConsumerState<CancelledOrderNotice> {
  bool _busy = false;

  Future<void> _reorder() async {
    final p = widget.prescription;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await ref.read(apiClientProvider).reorderPrescription(p.patientId, p.id);
      ref.invalidate(doctorPrescriptionsProvider);
      messenger.showSnackBar(
        SnackBar(content: Text('New order sent. ${p.patientName} will be asked to confirm it.')),
      );
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.prescription;
    final error = Theme.of(context).colorScheme.error;
    final who = p.cancelledBy == 'admin' ? 'an admin' : 'the pharmacy';
    return Container(
      key: Key('rx-cancelled-${p.id}'),
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
      decoration: BoxDecoration(
        color: error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.cancel_outlined, size: 18, color: error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Order cancelled by $who'
              '${p.cancelReason == null ? '' : ': ${p.cancelReason}'}',
              style: TextStyle(color: error),
            ),
          ),
          TextButton.icon(
            key: Key('rx-reorder-${p.id}'),
            onPressed: _busy ? null : _reorder,
            icon: const Icon(Icons.send_outlined, size: 18),
            label: const Text('Send new order'),
          ),
        ],
      ),
    );
  }
}
