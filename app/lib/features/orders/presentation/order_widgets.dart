import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../appointments/domain/appointment_text.dart';
import '../../medications/domain/med_schedule.dart';
import '../data/order_models.dart';
import '../state/orders_providers.dart';

/// Module 13 display helpers (D-66). Times are Malaysia time.

const pharmacyName = 'Harvey pharmacy';

const _months = [
  'January', 'February', 'March', 'April', 'May', 'June', //
  'July', 'August', 'September', 'October', 'November', 'December',
];

/// "October 2026" for an order's cycle.
String cycleLabel(DateTime? cycle) {
  if (cycle == null) return 'Monthly refill';
  final l = toMyt(cycle);
  return '${_months[l.month - 1]} ${l.year}';
}

/// Where the patient should land for an order: confirm, pay or track (Figs 4.3.10.1-3).
String orderRoute(MedicationOrder o) => switch (o.status) {
  Fulfilment.awaitingConfirmation || Fulfilment.skipped => '/orders/${o.id}/confirm',
  Fulfilment.awaitingPayment => '/orders/${o.id}/pay',
  _ => '/orders/${o.id}/track',
};

class OrderStatusChip extends StatelessWidget {
  const OrderStatusChip({super.key, required this.status, this.label});
  final Fulfilment status;

  /// Overrides the status name (D-89 "Finding a driver").
  final String? label;

  /// The chip for an order, including "Finding a driver".
  factory OrderStatusChip.of(MedicationOrder o, {Key? key}) =>
      OrderStatusChip(key: key, status: o.status, label: o.statusLabel);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (bg, fg) = switch (status) {
      Fulfilment.outOfStock ||
      Fulfilment.failed ||
      Fulfilment.cancelled => (scheme.errorContainer, scheme.onErrorContainer),
      Fulfilment.readyForCollection ||
      Fulfilment.readyForDelivery ||
      Fulfilment.delivered ||
      Fulfilment.collected => (scheme.primaryContainer, scheme.onPrimaryContainer),
      Fulfilment.preparing => (scheme.tertiaryContainer, scheme.onTertiaryContainer),
      _ => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
      child: Text(
        label ?? status.label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(color: fg),
      ),
    );
  }
}

/// One step of a vertical timeline (Fig 4.3.10.3).
class TimelineStep {
  const TimelineStep(this.title, {this.subtitle, this.icon = Icons.circle_outlined});
  final String title;
  final String? subtitle;
  final IconData icon;
}

class OrderTimeline extends StatelessWidget {
  const OrderTimeline({super.key, required this.steps, required this.current});

  final List<TimelineStep> steps;

  /// Index of the step in progress; earlier steps are done.
  final int current;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      children: [
        for (var i = 0; i < steps.length; i++)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 36,
                  child: Column(
                    children: [
                      CircleAvatar(
                        radius: 14,
                        backgroundColor: i < current || (i == current && i == steps.length - 1)
                            ? scheme.primary
                            : i == current
                            ? scheme.primaryContainer
                            : scheme.surfaceContainerHighest,
                        child: Icon(
                          i < current || (i == current && i == steps.length - 1)
                              ? Icons.check
                              : steps[i].icon,
                          size: 16,
                          color: i < current || (i == current && i == steps.length - 1)
                              ? scheme.onPrimary
                              : i == current
                              ? scheme.primary
                              : scheme.outline,
                        ),
                      ),
                      if (i < steps.length - 1)
                        Expanded(
                          child: Container(
                            width: 2,
                            color: i < current ? scheme.primary : scheme.outlineVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 20, top: 3),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          steps[i].title,
                          key: Key('step-$i'),
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: i > current ? scheme.outline : null,
                            fontWeight: i == current ? FontWeight.bold : null,
                          ),
                        ),
                        if (steps[i].subtitle != null && i <= current)
                          Text(steps[i].subtitle!, style: theme.textTheme.bodySmall),
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

/// Medications page entry point (UC13.2): the orders waiting for the patient, or a link to
/// the order list. Shows nothing for patients without recurring prescriptions.
class MonthlyOrdersBanner extends ConsumerWidget {
  const MonthlyOrdersBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orders = ref.watch(myOrdersProvider).value ?? const <MedicationOrder>[];
    if (orders.isEmpty) return const SizedBox.shrink();
    final waiting = orders.where((o) => o.needsPatient).toList();
    final active = orders.where((o) => o.isActive).length;
    final theme = Theme.of(context);
    final urgent = waiting.isNotEmpty;
    // D-99: green when all is well, orange when an order needs the patient.
    final colors = urgent
        ? [Colors.orange.shade600, Colors.deepOrange.shade400]
        : [Colors.green.shade600, Colors.teal.shade400];
    final title = !urgent
        ? 'Monthly orders'
        : waiting.length == 1
        ? 'Your monthly order needs you'
        : '${waiting.length} monthly orders need you';
    final subtitle = !urgent
        ? 'Track your recurring prescription refills'
        : '${waiting.first.medicationDetails}: ${waiting.first.statusLabel.toLowerCase()}';
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(
          colors: colors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: colors.first.withValues(alpha: 0.3),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: const Key('orders-banner'),
          borderRadius: BorderRadius.circular(18),
          onTap: () => context.push(waiting.length == 1 ? orderRoute(waiting.first) : '/orders'),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    urgent ? Icons.notifications_active : Icons.local_pharmacy,
                    color: Colors.white,
                    size: 26,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white),
                      ),
                      if (active > 0) ...[
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.25),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '$active active',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: Colors.white),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Ready 2:30 PM, Thu 16 Oct".
String readyLabel(DateTime t) => '${timeLabel(t)}, ${dateLabel(t)}';

/// D-97: from an order notification. Loads the order, then shows it with the Orders list
/// behind it on the matching tab (Active while it is still going, Completed when done).
class OrderOpenPage extends ConsumerStatefulWidget {
  const OrderOpenPage({super.key, required this.orderId});
  final String orderId;

  @override
  ConsumerState<OrderOpenPage> createState() => _OrderOpenPageState();
}

class _OrderOpenPageState extends ConsumerState<OrderOpenPage> {
  bool _moved = false;

  void _go(MedicationOrder o) {
    if (_moved) return;
    _moved = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final router = GoRouter.of(context);
      router.pushReplacement(o.isActive ? '/orders' : '/orders?tab=completed');
      router.push(orderRoute(o));
    });
  }

  @override
  Widget build(BuildContext context) {
    final order = ref.watch(orderProvider(widget.orderId));
    return Scaffold(
      appBar: AppBar(title: const Text('Order')),
      body: order.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('This order could not be opened.'),
              TextButton(
                key: const Key('order-open-list'),
                onPressed: () => context.pushReplacement('/orders'),
                child: const Text('See all orders'),
              ),
            ],
          ),
        ),
        data: (o) {
          _go(o);
          return const Center(child: CircularProgressIndicator());
        },
      ),
    );
  }
}
