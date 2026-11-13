import 'dart:typed_data';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/providers/api_providers.dart';
import '../../../shared/services/api/api_client.dart';
import '../../../shared/widgets/fill_grid.dart';
import '../../../shared/widgets/page_header.dart';
import '../../appointments/domain/appointment_text.dart' show dateLabel, timeLabel;
import '../../settings/state/settings_providers.dart' show fileSharerProvider;

/// D-85: money in and out for the pharmacy and the admin.

String rmText(num v) => 'RM${v.toStringAsFixed(2)}';

class CashflowSummary {
  const CashflowSummary(this.json);
  final Map<String, dynamic> json;

  double _n(String k) => (json[k] as num?)?.toDouble() ?? 0;
  int get days => (json['days'] as num?)?.toInt() ?? 30;
  double get received => _n('received');
  double get medicineRevenue => _n('medicineRevenue');
  double get deliveryFees => _n('deliveryFees');
  int get paidCount => (json['paidCount'] as num?)?.toInt() ?? 0;
  double get averagePayment => _n('averagePayment');
  int get failedCount => (json['failedCount'] as num?)?.toInt() ?? 0;
  double get failedAmount => _n('failedAmount');
  double get outstanding => _n('outstanding');
  int get outstandingCount => (json['outstandingCount'] as num?)?.toInt() ?? 0;
  Map<String, double> get byMethod => {
    for (final e in ((json['byMethod'] as Map?) ?? const {}).entries)
      '${e.key}': (e.value as num).toDouble(),
  };
  List<(DateTime, double)> get byDay => [
    for (final d in (json['byDay'] as List? ?? const []))
      (DateTime.parse((d as Map)['date'] as String), (d['amount'] as num).toDouble()),
  ];
  List<Map<String, dynamic>> get transactions => [
    for (final t in (json['transactions'] as List? ?? const [])) (t as Map).cast<String, dynamic>(),
  ];
}

final cashflowProvider = FutureProvider.autoDispose.family<CashflowSummary, int>((ref, days) async {
  return CashflowSummary(await ref.watch(apiClientProvider).cashflow(days));
});

final orderPaymentsProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>(
  (ref, orderId) => ref.watch(apiClientProvider).orderPayments(orderId),
);

/// Where an order opens for this staff member.
String orderPath(bool admin, String orderId) =>
    admin ? '/admin/orders/$orderId' : '/pharmacy/order/$orderId';

class CashflowPage extends ConsumerStatefulWidget {
  const CashflowPage({super.key, this.admin = false});
  final bool admin;

  @override
  ConsumerState<CashflowPage> createState() => _CashflowPageState();
}

class _CashflowPageState extends ConsumerState<CashflowPage> {
  int _days = 30;

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(cashflowProvider(_days));
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        PageHeader(
          title: 'Cashflow',
          subtitle: 'Payments received, money still owed and failed payments (Stripe test mode).',
          icon: Icons.payments_outlined,
          color: Colors.green.shade700,
          actions: [
            SegmentedButton<int>(
              key: const Key('cashflow-days'),
              segments: const [
                ButtonSegment(value: 7, label: Text('7 days')),
                ButtonSegment(value: 30, label: Text('30 days')),
                ButtonSegment(value: 90, label: Text('90 days')),
              ],
              selected: {_days},
              onSelectionChanged: (s) => setState(() => _days = s.first),
            ),
            IconButton(
              tooltip: 'Refresh',
              onPressed: () => ref.invalidate(cashflowProvider(_days)),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        data.when(
          loading: () => const LinearProgressIndicator(),
          error: (_, _) => TextButton(
            onPressed: () => ref.invalidate(cashflowProvider(_days)),
            child: const Text('Could not load the cashflow. Retry'),
          ),
          data: (c) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FillGrid(
                minItemWidth: 220,
                spacing: 12,
                equalHeight: true,
                children: [
                  _Kpi(
                    key: const Key('cash-received'),
                    label: 'Received',
                    value: rmText(c.received),
                    note: '${c.paidCount} payment(s)',
                    color: Colors.green.shade700,
                    icon: Icons.south_west,
                  ),
                  _Kpi(
                    key: const Key('cash-outstanding'),
                    label: 'Still owed',
                    value: rmText(c.outstanding),
                    note: '${c.outstandingCount} order(s) waiting for payment',
                    color: Colors.orange.shade800,
                    icon: Icons.hourglass_top,
                  ),
                  _Kpi(
                    key: const Key('cash-failed'),
                    label: 'Failed payments',
                    value: '${c.failedCount}',
                    note: '${rmText(c.failedAmount)} not taken',
                    color: Colors.red.shade700,
                    icon: Icons.error_outline,
                  ),
                  _Kpi(
                    key: const Key('cash-average'),
                    label: 'Average payment',
                    value: rmText(c.averagePayment),
                    note:
                        'Medicines ${rmText(c.medicineRevenue)} · '
                        'delivery ${rmText(c.deliveryFees)}',
                    color: Colors.blue.shade700,
                    icon: Icons.receipt_long_outlined,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Money received per day', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 12),
                      SizedBox(height: 220, child: CashflowChart(points: c.byDay)),
                      const SizedBox(height: 8),
                      Text(
                        'Delivery orders ${rmText(c.byMethod['delivery'] ?? 0)} · '
                        'pharmacy collection ${rmText(c.byMethod['collection'] ?? 0)}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                      child: Text('Payments', style: theme.textTheme.titleMedium),
                    ),
                    if (c.transactions.isEmpty)
                      const Padding(
                        key: Key('cash-none'),
                        padding: EdgeInsets.all(16),
                        child: Text('No payments in this period.'),
                      ),
                    for (final t in c.transactions)
                      _PaymentRow(
                        t: t,
                        onTap: t['orderId'] == null
                            ? null
                            : () => context.go(orderPath(widget.admin, '${t['orderId']}')),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi({
    super.key,
    required this.label,
    required this.value,
    required this.note,
    required this.color,
    required this.icon,
  });

  final String label;
  final String value;
  final String note;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: color, width: 5)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: color.withValues(alpha: 0.14),
            foregroundColor: color,
            child: Icon(icon),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.bodySmall),
                Text(
                  value,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(color: color, fontWeight: FontWeight.bold),
                ),
                Text(note, maxLines: 2, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

(Color, String) paymentStyle(String status) => switch (status) {
  'succeeded' => (Colors.green.shade700, 'Paid'),
  'failed' => (Colors.red.shade700, 'Failed'),
  'refunded' => (Colors.blueGrey, 'Refunded'),
  _ => (Colors.grey, status),
};

class _PaymentRow extends StatelessWidget {
  const _PaymentRow({required this.t, this.onTap});
  final Map<String, dynamic> t;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final (color, label) = paymentStyle('${t['status']}');
    final at = t['processedAt'] == null ? null : DateTime.tryParse('${t['processedAt']}');
    return ListTile(
      key: Key('payment-${t['id']}'),
      onTap: onTap,
      leading: CircleAvatar(
        backgroundColor: color.withValues(alpha: 0.12),
        foregroundColor: color,
        child: Icon(t['status'] == 'succeeded' ? Icons.check : Icons.close, size: 20),
      ),
      title: Text('${t['orderRef'] ?? 'Order'} · ${t['patientName'] ?? 'Patient'}'),
      subtitle: Text(
        [
          if (at != null) '${dateLabel(at)}, ${timeLabel(at)}',
          '${t['chargeId'] ?? ''}',
        ].join(' · '),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Chip(
            label: Text(label),
            labelStyle: TextStyle(color: color, fontWeight: FontWeight.w600),
            side: BorderSide(color: color.withValues(alpha: 0.4)),
            backgroundColor: color.withValues(alpha: 0.08),
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 90,
            child: Text(
              rmText((t['amount'] as num?) ?? 0),
              textAlign: TextAlign.right,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          if (onTap != null) const Icon(Icons.chevron_right),
        ],
      ),
    );
  }
}

/// Daily received amounts as bars.
class CashflowChart extends StatelessWidget {
  const CashflowChart({super.key, required this.points});
  final List<(DateTime, double)> points;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final top = points.fold<double>(0, (m, p) => p.$2 > m ? p.$2 : m);
    final step = (points.length / 6).ceil().clamp(1, 1000);
    return BarChart(
      BarChartData(
        maxY: top == 0 ? 10 : top * 1.2,
        gridData: const FlGridData(drawVerticalLine: false),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 44)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (v, meta) {
                final i = v.toInt();
                if (i < 0 || i >= points.length || i % step != 0) return const SizedBox.shrink();
                final d = points[i].$1;
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('${d.day}/${d.month}', style: const TextStyle(fontSize: 10)),
                );
              },
            ),
          ),
        ),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipItem: (group, _, rod, _) => BarTooltipItem(
              '${points[group.x].$1.day}/${points[group.x].$1.month}\n${rmText(rod.toY)}',
              const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
            ),
          ),
        ),
        barGroups: [
          for (var i = 0; i < points.length; i++)
            BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: points[i].$2,
                  width: points.length > 40 ? 4 : 10,
                  color: Colors.green.shade600,
                  borderRadius: BorderRadius.circular(3),
                  backDrawRodData: BackgroundBarChartRodData(
                    show: true,
                    toY: top == 0 ? 10 : top * 1.2,
                    color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// D-85: on the order page: every payment attempt, the receipt and its PDF.
class OrderPaymentCard extends ConsumerWidget {
  const OrderPaymentCard({super.key, required this.orderId});
  final String orderId;

  Future<void> _download(BuildContext context, WidgetRef ref, String ref_) async {
    try {
      final bytes = await ref.read(apiClientProvider).receiptPdf(orderId);
      await ref
          .read(fileSharerProvider)
          .share(
            Uint8List.fromList(bytes),
            fileName: 'receipt-$ref_.pdf',
            mimeType: 'application/pdf',
          );
    } on ApiException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final data = ref.watch(orderPaymentsProvider(orderId));
    return Card(
      key: const Key('order-payment-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: data.when(
          loading: () => const LinearProgressIndicator(),
          error: (_, _) => const Text('Could not load the payment details.'),
          data: (p) {
            final receipt = (p['receipt'] as Map?)?.cast<String, dynamic>();
            final txs = [
              for (final t in (p['transactions'] as List? ?? const []))
                (t as Map).cast<String, dynamic>(),
            ];
            final patient = (p['patient'] as Map?)?.cast<String, dynamic>() ?? const {};
            DateTime? at(Object? v) => v == null ? null : DateTime.tryParse('$v');
            String when(Object? v) {
              final t = at(v);
              return t == null ? '—' : '${dateLabel(t)}, ${timeLabel(t)}';
            }

            Widget line(String a, String b, {bool bold = false}) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Expanded(child: Text(a)),
                  Text(b, style: bold ? const TextStyle(fontWeight: FontWeight.w700) : null),
                ],
              ),
            );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text('Payment and receipt', style: theme.textTheme.titleMedium),
                    ),
                    if (receipt != null)
                      FilledButton.tonalIcon(
                        key: const Key('download-receipt'),
                        onPressed: () => _download(context, ref, '${p['orderRef']}'),
                        icon: const Icon(Icons.picture_as_pdf_outlined),
                        label: const Text('Receipt PDF'),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                if (receipt == null)
                  Text(
                    'Not paid yet (payment ${p['paymentStatus'] ?? 'pending'}), so there is no '
                    'receipt.',
                    key: const Key('no-receipt'),
                  )
                else
                  Container(
                    key: const Key('receipt'),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Harvey payment receipt · ${p['orderRef']}',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          'Paid ${when(receipt['paidAt'])} by ${patient['name'] ?? 'the patient'}'
                          '${patient['email'] == null ? '' : ' (${patient['email']})'}',
                          style: theme.textTheme.bodySmall,
                        ),
                        const Divider(height: 20),
                        Text('${receipt['medication'] ?? ''}', style: theme.textTheme.bodySmall),
                        const SizedBox(height: 6),
                        line('Medicines', rmText((receipt['medicineAmount'] as num?) ?? 0)),
                        line(
                          receipt['method'] == 'home_delivery' ? 'Home delivery' : 'Collection',
                          rmText((receipt['deliveryFee'] as num?) ?? 0),
                        ),
                        const Divider(height: 16),
                        line('Total paid', rmText((receipt['total'] as num?) ?? 0), bold: true),
                        const SizedBox(height: 6),
                        Text(
                          'Reference ${receipt['reference'] ?? '—'} · ${receipt['processor']}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                if (txs.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('Payment attempts', style: theme.textTheme.labelLarge),
                  for (final t in txs)
                    Builder(
                      builder: (context) {
                        final (color, label) = paymentStyle('${t['status']}');
                        return ListTile(
                          key: Key('attempt-${t['id']}'),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.circle, size: 12, color: color),
                          title: Text('$label · ${rmText((t['amount'] as num?) ?? 0)}'),
                          subtitle: Text('${when(t['processedAt'])} · ${t['chargeId'] ?? ''}'),
                        );
                      },
                    ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}
