import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/services/api/api_client.dart';
import '../../appointments/domain/appointment_text.dart';
import '../data/order_models.dart';
import '../../family/state/family_providers.dart';
import '../state/orders_providers.dart';
import 'order_widgets.dart';

/// Fig 4.3.10.3 Delivery tracking (UC13.4, UC13.5; FR-13.4, FR-13.5), the self-collection
/// slip (docs/06 §J step 6) and the reschedule / switch choice after a failed delivery.
class OrderTrackPage extends ConsumerStatefulWidget {
  const OrderTrackPage({super.key, required this.orderId});
  final String orderId;

  /// How often an order in progress is refreshed while the screen is open.
  static const refreshEvery = Duration(seconds: 10);

  @override
  ConsumerState<OrderTrackPage> createState() => _OrderTrackPageState();
}

class _OrderTrackPageState extends ConsumerState<OrderTrackPage> {
  Timer? _poll;
  bool _busy = false;

  static const _live = {
    Fulfilment.preparing,
    Fulfilment.outOfStock,
    Fulfilment.readyForDelivery,
    Fulfilment.readyForCollection,
  };

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(OrderTrackPage.refreshEvery, (_) {
      final o = ref.read(orderProvider(widget.orderId)).value;
      if (o == null || _live.contains(o.status)) ref.invalidate(orderProvider(widget.orderId));
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _act(Future<void> Function() action, String done) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
      ref
        ..invalidate(orderProvider(widget.orderId))
        ..invalidate(myOrdersProvider);
      messenger.showSnackBar(SnackBar(content: Text(done)));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final order = ref.watch(orderProvider(widget.orderId));
    return Scaffold(
      appBar: AppBar(title: const Text('Order tracking')),
      body: order.when(
        skipLoadingOnRefresh: true,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => Center(
          child: TextButton(
            onPressed: () => ref.invalidate(orderProvider(widget.orderId)),
            child: const Text('Could not load the order. Retry'),
          ),
        ),
        data: (o) => RefreshIndicator(
          onRefresh: () => ref.refresh(orderProvider(widget.orderId).future),
          child: _body(context, o),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, MedicationOrder o) {
    final theme = Theme.of(context);
    final repo = ref.read(ordersRepositoryProvider);
    final (icon, title, subtitle) = switch (o.status) {
      Fulfilment.preparing => (
        Icons.inventory_2_outlined,
        'Preparing your order',
        "We're carefully putting everything together.",
      ),
      Fulfilment.outOfStock => (
        Icons.hourglass_bottom,
        'Your order is delayed',
        "The pharmacy is waiting for stock of your medicine. We'll let you know when it's ready.",
      ),
      Fulfilment.readyForDelivery => (
        Icons.local_shipping_outlined,
        o.deliveryStatus == 'in_transit'
            ? 'Out for delivery'
            : o.awaitingDriver
            ? 'Finding a driver'
            : 'Courier booked',
        o.awaitingDriver
            ? '${o.courierBrand} is looking for a driver. If none accepts within 30 minutes, '
                  "we'll ask you to rebook or collect at the pharmacy."
            : o.courierRef == null
            ? 'Your medication is on its way.'
            : '${o.courierBrand} booking ${o.courierRef}',
      ),
      Fulfilment.readyForCollection => (
        Icons.storefront_outlined,
        'Ready for collection',
        'Show your collection slip at $pharmacyName.',
      ),
      Fulfilment.delivered => (Icons.home_outlined, 'Delivered', 'Your medication has arrived.'),
      Fulfilment.collected => (Icons.check_circle_outline, 'Collected', 'Enjoy your month.'),
      Fulfilment.cancelled => (
        Icons.cancel_outlined,
        'Order cancelled',
        o.cancelReason ?? 'This order was cancelled.',
      ),
      Fulfilment.skipped => (
        Icons.event_busy_outlined,
        'Skipped this month',
        o.skipReason ?? 'Your doctor skipped this month.',
      ),
      Fulfilment.failed => (
        Icons.report_problem_outlined,
        'Delivery problem',
        o.failureReason ?? "We couldn't deliver your medication.",
      ),
      _ => (Icons.receipt_long_outlined, o.status.label, ''),
    };
    final delivery = o.isDelivery;
    final steps = delivery
        ? [
            TimelineStep(
              'Order confirmed',
              subtitle: o.paidAt == null ? null : timeLabel(o.paidAt!),
              icon: Icons.receipt_long_outlined,
            ),
            const TimelineStep(
              'Preparing',
              subtitle: 'Your items are being packed securely.',
              icon: Icons.inventory_2_outlined,
            ),
            TimelineStep(
              'Out for delivery',
              subtitle: o.courierRef == null ? null : '${o.courierBrand} ${o.courierRef}',
              icon: Icons.local_shipping_outlined,
            ),
            const TimelineStep('Delivered', icon: Icons.home_outlined),
            // D-94: the patient's own confirmation.
            TimelineStep(
              'Received by you',
              subtitle: o.receivedAt == null ? null : timeLabel(o.receivedAt!),
              icon: Icons.verified_outlined,
            ),
          ]
        : [
            TimelineStep(
              'Order confirmed',
              subtitle: o.paidAt == null ? null : timeLabel(o.paidAt!),
              icon: Icons.receipt_long_outlined,
            ),
            TimelineStep(
              'Preparing',
              subtitle: o.estimatedReadyAt == null || o.readyAt != null
                  ? 'The pharmacist is preparing your medicine.'
                  : 'Estimated ready by ${readyLabel(o.estimatedReadyAt!)}',
              icon: Icons.inventory_2_outlined,
            ),
            TimelineStep(
              'Ready for collection',
              subtitle: o.readyAt == null ? null : readyLabel(o.readyAt!),
              icon: Icons.storefront_outlined,
            ),
            const TimelineStep('Collected', icon: Icons.check),
          ];
    final current = delivery
        ? o.deliveryStage
        : switch (o.status) {
            Fulfilment.collected => 3,
            Fulfilment.readyForCollection => 2,
            _ => o.isPaid ? 1 : 0,
          };
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const SizedBox(height: 8),
        Center(
          child: CircleAvatar(
            radius: 40,
            backgroundColor: o.status == Fulfilment.failed || o.status == Fulfilment.outOfStock
                ? theme.colorScheme.errorContainer
                : theme.colorScheme.primaryContainer,
            child: Icon(icon, size: 36, color: theme.colorScheme.primary),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          title,
          key: const Key('track-title'),
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall,
        ),
        if (subtitle.isNotEmpty)
          Text(subtitle, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 16),
        if (o.status == Fulfilment.failed) ...[
          // FR-13.5: reschedule or switch to self-collection.
          FilledButton.icon(
            key: const Key('reschedule-delivery'),
            onPressed: _busy
                ? null
                : () => _act(() => repo.reschedule(o.id), 'A new courier has been booked.'),
            icon: const Icon(Icons.refresh),
            label: const Text('Reschedule delivery'),
          ),
          OutlinedButton.icon(
            key: const Key('switch-collection'),
            onPressed: _busy
                ? null
                : () => _act(
                    () => repo.switchToCollection(o.id),
                    'Switched to self-collection. Your order is ready at the pharmacy.',
                  ),
            icon: const Icon(Icons.storefront_outlined),
            label: const Text('Switch to self-collection'),
          ),
          const SizedBox(height: 16),
        ],
        if (o.canConfirmReceived) ...[
          // D-94: tells the pharmacy the medicine arrived.
          FilledButton.icon(
            key: const Key('confirm-received'),
            onPressed: _busy
                ? null
                : () => _act(
                    () => repo.confirmReceived(o.id),
                    'Thanks! The pharmacy can see you received your medicine.',
                  ),
            icon: const Icon(Icons.check_circle_outline),
            label: const Text('Medicine received'),
          ),
          const SizedBox(height: 4),
          Text(
            'Press this once the medicine is in your hands.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
        ],
        if (o.receivedAt != null)
          Card(
            key: const Key('received-note'),
            color: Colors.green.shade50,
            child: ListTile(
              leading: Icon(Icons.verified, color: Colors.green.shade700),
              title: const Text('You received this medicine'),
              subtitle: Text('${dateLabel(o.receivedAt!)}, ${timeLabel(o.receivedAt!)}'),
            ),
          ),
        if (o.status == Fulfilment.readyForCollection) _CollectionSlip(order: o),
        // D-68: the courier's own tracking page (Lalamove share link).
        if (o.trackingUrl != null && o.status == Fulfilment.readyForDelivery)
          TextButton.icon(
            key: const Key('courier-tracking'),
            onPressed: () => ref.read(openUrlProvider)(Uri.parse(o.trackingUrl!)),
            icon: const Icon(Icons.open_in_new),
            label: Text('Open ${o.courierBrand} tracking page'),
          ),
        // D-112: a cancelled or skipped order says who, when and why; no timeline.
        if (o.status == Fulfilment.cancelled || o.status == Fulfilment.skipped)
          _StoppedCard(order: o)
        else
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (delivery && o.etaAt != null && o.status == Fulfilment.readyForDelivery) ...[
                    Text('ESTIMATED ARRIVAL', style: theme.textTheme.labelSmall),
                    Text(
                      timeLabel(o.etaAt!),
                      key: const Key('eta'),
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  OrderTimeline(steps: steps, current: current),
                ],
              ),
            ),
          ),
        // D-112: how it reaches the patient, then what was ordered and paid.
        if (o.status != Fulfilment.cancelled && o.status != Fulfilment.skipped && o.method != null)
          delivery ? _DeliveryCard(order: o) : _CollectionCard(order: o),
        _ItemsCard(order: o),
        if (o.isPaid)
          TextButton.icon(
            key: const Key('open-receipt'),
            onPressed: () => context.push('/records'),
            icon: const Icon(Icons.receipt_long_outlined),
            label: const Text('Receipt saved in Health records'),
          ),
      ],
    );
  }
}

/// docs/06 §J step 6: prescription ID and ready time, shown at the pharmacy counter.
class _CollectionSlip extends StatelessWidget {
  const _CollectionSlip({required this.order});
  final MedicationOrder order;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: const Key('collection-slip'),
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Collection slip', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              order.ref,
              style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            Text('Prescription ID: ${order.prescriptionId}'),
            if (order.readyAt != null) Text('Ready since ${readyLabel(order.readyAt!)}'),
            Text(order.medicationDetails),
            const SizedBox(height: 8),
            Text('Show this at the $pharmacyName counter.', style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

Widget _row(BuildContext context, String label, String value, {Key? key, bool bold = false}) {
  final style = bold ? Theme.of(context).textTheme.titleSmall : null;
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Text(label, style: style)),
        const SizedBox(width: 12),
        Flexible(
          child: Text(value, key: key, textAlign: TextAlign.right, style: style),
        ),
      ],
    ),
  );
}

Widget _section(
  BuildContext context,
  String title,
  IconData icon,
  List<Widget> children, {
  Key? key,
}) {
  final theme = Theme.of(context);
  return Card(
    key: key,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text(title, style: theme.textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    ),
  );
}

String _at(DateTime t) => '${dateLabel(t)}, ${timeLabel(t)}';

/// D-112: medicines with quantity and price, delivery fee, total and payment.
class _ItemsCard extends StatelessWidget {
  const _ItemsCard({required this.order});
  final MedicationOrder order;

  @override
  Widget build(BuildContext context) {
    final o = order;
    return _section(
      context,
      'Order details',
      Icons.medication_outlined,
      key: const Key('order-items'),
      [
        if (o.items.isEmpty)
          _row(context, o.medicationDetails, o.amount == null ? '—' : rm(o.amount!))
        else
          for (final i in o.items) _row(context, '${i.label} × ${i.quantity}', rm(i.lineTotal)),
        const Divider(),
        if (o.amount != null) _row(context, 'Medicines', rm(o.amount!)),
        if (o.isDelivery && o.deliveryFee > 0)
          _row(context, 'Delivery (${o.courierBrand})', rm(o.deliveryFee)),
        if (o.total != null)
          _row(context, 'Total', rm(o.total!), bold: true, key: const Key('order-detail-total')),
        const SizedBox(height: 4),
        _row(context, 'Order', o.ref),
        _row(context, 'Month', cycleLabel(o.cycleDate)),
        _row(
          context,
          'Payment',
          o.isPaid
              ? 'Paid${o.paidAt == null ? '' : ' ${_at(o.paidAt!)}'}'
              : o.paymentFailed
              ? 'Failed'
              : 'Not paid',
          key: const Key('order-detail-payment'),
        ),
      ],
    );
  }
}

/// D-112: where the courier is going and who is bringing it.
class _DeliveryCard extends StatelessWidget {
  const _DeliveryCard({required this.order});
  final MedicationOrder order;

  @override
  Widget build(BuildContext context) {
    final o = order;
    return _section(
      context,
      'Home delivery',
      Icons.local_shipping_outlined,
      key: const Key('order-delivery'),
      [
        if (o.deliveryAddress != null) _row(context, 'Address', o.deliveryAddress!),
        if (o.deliveryPhone != null) _row(context, 'Contact number', o.deliveryPhone!),
        _row(context, 'Courier', o.courierBrand),
        if (o.courierRef != null) _row(context, 'Booking', o.courierRef!),
        if (o.etaAt != null && o.status == Fulfilment.readyForDelivery)
          _row(context, 'Estimated arrival', _at(o.etaAt!)),
        if (o.status == Fulfilment.delivered || o.receivedAt != null)
          _row(
            context,
            'Received by you',
            o.receivedAt == null ? 'Not confirmed yet' : _at(o.receivedAt!),
          ),
      ],
    );
  }
}

/// D-112: where and when to pick it up.
class _CollectionCard extends StatelessWidget {
  const _CollectionCard({required this.order});
  final MedicationOrder order;

  @override
  Widget build(BuildContext context) {
    final o = order;
    return _section(
      context,
      'Self-collection',
      Icons.storefront_outlined,
      key: const Key('order-collection'),
      [
        _row(context, 'Pharmacy', pharmacyName),
        if (o.readyAt != null) _row(context, 'Ready since', _at(o.readyAt!)),
        _row(context, 'Status', switch (o.status) {
          Fulfilment.collected => 'Collected',
          Fulfilment.readyForCollection => 'Waiting for you at the counter',
          _ => 'Being prepared',
        }),
        if (o.status == Fulfilment.readyForCollection)
          Text(
            'Bring your MyKad or passport and show the collection slip above.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
      ],
    );
  }
}

/// D-112: cancelled (D-74) or skipped by the doctor (D-104).
class _StoppedCard extends StatelessWidget {
  const _StoppedCard({required this.order});
  final MedicationOrder order;

  @override
  Widget build(BuildContext context) {
    final o = order;
    final skipped = o.status == Fulfilment.skipped;
    final when = skipped ? o.skippedAt : o.cancelledAt;
    final by = skipped
        ? 'Your doctor'
        : switch (o.cancelledBy) {
            'doctor' => 'Your doctor',
            'pharmacist' => 'The pharmacy',
            'patient' => 'You',
            _ => 'The clinic',
          };
    return _section(
      context,
      skipped ? 'Skipped' : 'Cancelled',
      skipped ? Icons.event_busy_outlined : Icons.cancel_outlined,
      key: const Key('order-stopped'),
      [
        _row(context, 'By', by),
        if (when != null) _row(context, 'When', _at(when)),
        _row(context, 'Reason', (skipped ? o.skipReason : o.cancelReason) ?? 'No reason given'),
        const SizedBox(height: 4),
        Text(
          skipped
              ? 'Your next monthly order comes as usual.'
              : 'Nothing was charged for this order.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
