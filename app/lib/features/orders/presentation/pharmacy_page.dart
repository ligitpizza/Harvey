import 'package:flutter/material.dart';
import '../../../shared/widgets/fill_grid.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/order_models.dart';
import '../state/orders_providers.dart';
import 'order_widgets.dart';
import '../../staff_shell/dashboards.dart' show StatTile;
import 'pharmacy_shared.dart';
import '../../../shared/widgets/page_header.dart';

/// Fig 4.3.13.1 Pharmacist view (UC13.6; FR-13.3; D-66): the paid-order queue, recurring
/// prescriptions waiting for a price, stock levels and a patient lookup.
class PharmacyPage extends ConsumerWidget {
  const PharmacyPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 1000;
        // D-79: counts on top, then the queue by stage, then what waits for the patient.
        // D-96: one tabbed Orders card (to prepare, collection, delivery, waiting, completed).
        const main = [_OrdersTabs(), SizedBox(height: 16), _PriceCard()];
        const side = [_QuickActions()];
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            PageHeader(
              title: 'Pharmacy operations',
              subtitle:
                  'Prepare paid orders and price older prescriptions. Stock and the catalogue '
                  'are under Inventory.',
              icon: Icons.local_pharmacy_outlined,
              color: Colors.green.shade700,
              actions: [
                IconButton(
                  key: const Key('pharmacy-refresh'),
                  tooltip: 'Refresh',
                  onPressed: () => ref
                    ..invalidate(ordersOverviewProvider((group: 'awaiting_patient', query: '')))
                    ..invalidate(ordersOverviewProvider(_completed))
                    ..invalidate(pharmacyQueueProvider)
                    ..invalidate(stockProvider),
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),

            const _StatusStrip(),
            const SizedBox(height: 16),
            if (wide)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Expanded(
                    flex: 3,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: main),
                  ),
                  const SizedBox(width: 16),
                  const SizedBox(width: 280, child: Column(children: side)),
                ],
              )
            else
              const Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [...main, SizedBox(height: 16), ...side],
              ),
          ],
        );
      },
    );
  }
}

// ---------------- queue ----------------

/// D-96: the Orders tabs.
enum _OrdersTab {
  prepare('To prepare', Icons.medication_outlined),
  collection('Ready for collection', Icons.storefront_outlined),
  delivery('Delivery', Icons.local_shipping_outlined),
  waiting('Waiting for patient', Icons.hourglass_top_outlined),
  completed('Completed', Icons.task_alt);

  const _OrdersTab(this.label, this.icon);
  final String label;
  final IconData icon;

  bool holds(MedicationOrder o) => switch (this) {
    prepare => o.status == Fulfilment.preparing || o.status == Fulfilment.outOfStock,
    collection => o.status == Fulfilment.readyForCollection,
    delivery => o.status == Fulfilment.readyForDelivery || o.status == Fulfilment.failed,
    waiting || completed => true,
  };
}

const _completed = (group: 'completed', query: '');

class _SelectedOrdersTab extends Notifier<_OrdersTab> {
  @override
  _OrdersTab build() => _OrdersTab.prepare;

  void select(_OrdersTab t) => state = t;
}

final _ordersTabProvider = NotifierProvider<_SelectedOrdersTab, _OrdersTab>(_SelectedOrdersTab.new);

class _OrdersTabs extends ConsumerWidget {
  const _OrdersTabs();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(_ordersTabProvider);
    final queue = ref.watch(pharmacyQueueProvider).value?.orders ?? const <MedicationOrder>[];
    final waiting =
        ref.watch(ordersOverviewProvider((group: 'awaiting_patient', query: ''))).value?.orders ??
        const <MedicationOrder>[];
    final completed =
        ref.watch(ordersOverviewProvider(_completed)).value?.orders ?? const <MedicationOrder>[];
    int count(_OrdersTab t) => switch (t) {
      _OrdersTab.waiting => waiting.length,
      _OrdersTab.completed => completed.length,
      _ => queue.where(t.holds).length,
    };
    return PharmacySection(
      key: const Key('orders-tabs'),
      icon: Icons.receipt_long_outlined,
      title: 'Orders',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final t in _OrdersTab.values)
                ChoiceChip(
                  key: Key('orders-tab-${t.name}'),
                  avatar: Icon(t.icon, size: 18),
                  label: Text('${t.label} (${count(t)})'),
                  selected: tab == t,
                  showCheckmark: false,
                  onSelected: (_) => ref.read(_ordersTabProvider.notifier).select(t),
                ),
            ],
          ),
          const SizedBox(height: 12),
          switch (tab) {
            _OrdersTab.waiting => const _WaitingForPatient(),
            _OrdersTab.completed => _CompletedList(orders: completed),
            _ => _QueueCard(tab: tab),
          },
        ],
      ),
    );
  }
}

class _QueueCard extends ConsumerWidget {
  const _QueueCard({required this.tab});

  final _OrdersTab tab;

  Future<void> _ready(BuildContext context, WidgetRef ref, MedicationOrder o) async {
    if (o.items.isNotEmpty) {
      // D-69: each medicine is taken from its catalogue-linked stock.
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(o.isDelivery ? 'Ready for delivery' : 'Ready for collection'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('These quantities are taken from stock:'),
              const SizedBox(height: 8),
              for (final i in o.items) Text('• ${i.label} × ${i.quantity}'),
              if (o.isDelivery)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('A courier is booked as soon as you confirm.'),
                ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(
              key: const Key('ready-confirm'),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Confirm'),
            ),
          ],
        ),
      );
      if (ok != true || !context.mounted) return;
      await runPharmacyAction(
        context,
        ref,
        () => ref.read(ordersRepositoryProvider).markReady(o.id),
        o.isDelivery ? 'Ready for delivery. Courier booked.' : 'Ready for collection.',
      );
      return;
    }
    final stock = await ref.read(stockProvider.future).catchError((_) => <StockItem>[]);
    if (!context.mounted) return;
    if (stock.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Add the medicine to stock first (New stock).')));
      return;
    }
    final words = o.medicationDetails.toLowerCase().split(RegExp(r'[\s,]+'));
    final guess = stock
        .where((s) => words.isNotEmpty && s.name.toLowerCase().contains(words.first))
        .firstOrNull;
    final picked = await showDialog<(String, int)>(
      context: context,
      builder: (_) => _ReadyDialog(order: o, stock: stock, initial: guess ?? stock.first),
    );
    if (picked == null || !context.mounted) return;
    await runPharmacyAction(
      context,
      ref,
      () => ref
          .read(ordersRepositoryProvider)
          .markReady(o.id, stockItemId: picked.$1, units: picked.$2),
      o.isDelivery ? 'Ready for delivery. Courier booked.' : 'Ready for collection.',
    );
  }

  Future<void> _outOfStock(BuildContext context, WidgetRef ref, MedicationOrder o) async {
    final note = await showDialog<String>(
      context: context,
      builder: (_) => PromptDialog(
        title: 'Mark out of stock?',
        message:
            'The admin is alerted and ${o.patientName ?? 'the patient'} is told about the delay.',
        fieldKey: const Key('oos-note'),
        label: 'Note for the admin (optional)',
        confirmKey: const Key('oos-confirm'),
        confirmText: 'Mark out of stock',
        maxLength: 300,
      ),
    );
    if (note == null || !context.mounted) return;
    final text = note.trim();
    await runPharmacyAction(
      context,
      ref,
      () => ref.read(ordersRepositoryProvider).outOfStock(o.id, note: text.isEmpty ? null : text),
      'Marked out of stock. Admin alerted.',
    );
  }

  Widget _row(BuildContext context, WidgetRef ref, MedicationOrder o) {
    final theme = Theme.of(context);
    final initials = (o.patientName ?? '?')
        .trim()
        .split(' ')
        .map((w) => w.isEmpty ? '' : w[0])
        .take(2)
        .join();
    final actions = <Widget>[
      if (o.status == Fulfilment.preparing || o.status == Fulfilment.outOfStock)
        FilledButton(
          key: Key('ready-${o.id}'),
          onPressed: () => _ready(context, ref, o),
          child: const Text('Mark ready'),
        ),
      if (o.status == Fulfilment.preparing)
        OutlinedButton(
          key: Key('oos-${o.id}'),
          onPressed: () => _outOfStock(context, ref, o),
          child: const Text('Out of stock'),
        ),
      if (o.canCancelCourier)
        OutlinedButton(
          key: Key('cancel-courier-${o.id}'),
          onPressed: () => cancelCourierWithReason(context, ref, o),
          child: const Text('Cancel courier'),
        ),
      if (o.status == Fulfilment.readyForCollection)
        FilledButton.tonal(
          key: Key('collected-${o.id}'),
          onPressed: () => runPharmacyAction(
            context,
            ref,
            () => ref.read(ordersRepositoryProvider).collected(o.id),
            'Marked as collected.',
          ),
          child: const Text('Collected'),
        ),
    ];
    return Card(
      key: Key('queue-${o.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      color: theme.colorScheme.surfaceContainerLowest,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        // D-69: the patient's dispensing details.
        onTap: () => context.go('/pharmacy/patients/${o.patientId}'),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(child: Text(initials)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(o.patientName ?? 'Patient', style: theme.textTheme.titleMedium),
                        OrderStatusChip.of(o),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      o.items.isEmpty
                          ? o.medicationDetails
                          : o.items.map((i) => '${i.label} ×${i.quantity}').join(', '),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        o.ref,
                        if (o.isDelivery) 'Home delivery' else 'Self-collection',
                        ?o.courierRef,
                        if (o.status == Fulfilment.failed && o.failureReason != null)
                          o.failureReason!,
                      ].join(' · '),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              if (actions.isNotEmpty) ...[
                const SizedBox(width: 12),
                // Equal-width buttons, stacked on the right.
                IntrinsicWidth(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final a in actions)
                        Padding(padding: const EdgeInsets.only(bottom: 6), child: a),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(pharmacyQueueProvider);
    return queue.when(
      loading: () => const LinearProgressIndicator(),
      error: (_, _) => TextButton(
        onPressed: () => ref.invalidate(pharmacyQueueProvider),
        child: const Text('Could not load the queue. Retry'),
      ),
      data: (q) {
        final orders = q.orders.where(tab.holds).toList();
        if (orders.isEmpty) {
          return Padding(
            key: const Key('queue-empty'),
            padding: const EdgeInsets.all(8),
            child: Text(switch (tab) {
              _OrdersTab.prepare => 'No paid orders to prepare.',
              _OrdersTab.collection => 'Nothing waiting for collection.',
              _ => 'No deliveries in progress.',
            }),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [for (final o in orders) _row(context, ref, o)],
        );
      },
    );
  }
}

/// D-96: delivered and collected orders; a delivery the patient confirmed shows
/// "Received by patient" (D-94).
class _CompletedList extends StatelessWidget {
  const _CompletedList({required this.orders});
  final List<MedicationOrder> orders;

  @override
  Widget build(BuildContext context) {
    if (orders.isEmpty) {
      return const Padding(padding: EdgeInsets.all(8), child: Text('No completed orders yet.'));
    }
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final o in orders)
          ListTile(
            key: Key('completed-${o.id}'),
            contentPadding: EdgeInsets.zero,
            onTap: () => context.go('/pharmacy/order/${o.id}'),
            leading: Icon(
              o.receivedAt != null
                  ? Icons.verified
                  : o.isDelivery
                  ? Icons.home_outlined
                  : Icons.storefront_outlined,
              color: o.receivedAt != null ? Colors.green.shade700 : null,
            ),
            title: Text(
              '${o.patientName ?? 'Patient'} · '
              '${o.items.isEmpty ? o.medicationDetails : o.items.map((i) => '${i.label} ×${i.quantity}').join(', ')}',
            ),
            subtitle: Text(
              [
                o.ref,
                if (o.isDelivery) 'Home delivery' else 'Self-collection',
                if (o.total != null) rm(o.total!),
              ].join(' · '),
              style: theme.textTheme.bodySmall,
            ),
            trailing: OrderStatusChip.of(o),
          ),
      ],
    );
  }
}

/// D-79: the queue at a glance.
class _StatusStrip extends ConsumerWidget {
  const _StatusStrip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orders = ref.watch(pharmacyQueueProvider).value?.orders ?? const <MedicationOrder>[];
    final waiting =
        ref.watch(ordersOverviewProvider((group: 'awaiting_patient', query: ''))).value?.orders ??
        const <MedicationOrder>[];
    int n(bool Function(MedicationOrder) t) => orders.where(t).length;
    // D-80: the counters stretch across the page.
    return FillGrid(
      minItemWidth: 200,
      spacing: 12,
      equalHeight: true,
      children: [
        StatTile(
          icon: Icons.medication_outlined,
          color: Colors.blue.shade600,
          label: 'To prepare',
          onTap: () => ref.read(_ordersTabProvider.notifier).select(_OrdersTab.prepare),
          value:
              '${n((o) => o.status == Fulfilment.preparing || o.status == Fulfilment.outOfStock)}',
        ),
        StatTile(
          icon: Icons.storefront_outlined,
          color: Colors.green.shade600,
          label: 'Ready for collection',
          value: '${n((o) => o.status == Fulfilment.readyForCollection)}',
          onTap: () => ref.read(_ordersTabProvider.notifier).select(_OrdersTab.collection),
        ),
        StatTile(
          icon: Icons.local_shipping_outlined,
          color: Colors.purple.shade400,
          label: 'Delivery',
          value:
              '${n((o) => o.status == Fulfilment.readyForDelivery || o.status == Fulfilment.failed)}',
          onTap: () => ref.read(_ordersTabProvider.notifier).select(_OrdersTab.delivery),
        ),
        StatTile(
          icon: Icons.hourglass_top_outlined,
          color: Colors.orange.shade700,
          label: 'Waiting for patient',
          value: '${waiting.length}',
          onTap: () => ref.read(_ordersTabProvider.notifier).select(_OrdersTab.waiting),
        ),
      ],
    );
  }
}

class _ReadyDialog extends StatefulWidget {
  const _ReadyDialog({required this.order, required this.stock, required this.initial});
  final MedicationOrder order;
  final List<StockItem> stock;
  final StockItem initial;

  @override
  State<_ReadyDialog> createState() => _ReadyDialogState();
}

class _ReadyDialogState extends State<_ReadyDialog> {
  late String _stockId = widget.initial.id;
  final _units = TextEditingController(text: '30');

  @override
  void dispose() {
    _units.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final units = int.tryParse(_units.text) ?? 0;
    return AlertDialog(
      title: Text(widget.order.isDelivery ? 'Ready for delivery' : 'Ready for collection'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.order.medicationDetails),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: const Key('ready-stock'),
            initialValue: _stockId,
            decoration: const InputDecoration(labelText: 'Take from stock'),
            items: [
              for (final s in widget.stock)
                DropdownMenuItem(value: s.id, child: Text('${s.name} (${s.units} units)')),
            ],
            onChanged: (v) => setState(() => _stockId = v ?? _stockId),
          ),
          TextField(
            key: const Key('ready-units'),
            controller: _units,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(labelText: 'Units dispensed'),
            onChanged: (_) => setState(() {}),
          ),
          if (widget.order.isDelivery)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('A courier is booked as soon as you confirm.'),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const Key('ready-confirm'),
          onPressed: units < 1 ? null : () => Navigator.pop(context, (_stockId, units)),
          child: const Text('Confirm'),
        ),
      ],
    );
  }
}

// ---------------- pricing ----------------

class _PriceCard extends ConsumerWidget {
  const _PriceCard();

  Future<void> _price(BuildContext context, WidgetRef ref, UnpricedPrescription rx) async {
    final text = await showDialog<String>(
      context: context,
      builder: (_) => PromptDialog(
        title: 'Monthly price',
        message: '${rx.patientName ?? 'Patient'} · ${rx.medicationDetails}',
        fieldKey: const Key('price-input'),
        label: '30-day supply (min RM2.00)',
        prefixText: 'RM ',
        confirmKey: const Key('price-save'),
        confirmText: 'Save',
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        allowed: RegExp(r'[0-9.]'),
        isValid: (v) => (double.tryParse(v) ?? 0) >= 2,
      ),
    );
    final price = double.tryParse(text ?? '');
    if (price == null || !context.mounted) return;
    await runPharmacyAction(
      context,
      ref,
      () => ref.read(ordersRepositoryProvider).setPrice(rx.id, price),
      'Price saved. The patient can now confirm.',
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(pharmacyQueueProvider).value?.needsPrice ?? const [];
    if (list.isEmpty) return const SizedBox.shrink();
    return PharmacySection(
      icon: Icons.sell_outlined,
      title: 'Recurring prescriptions to price',
      child: Column(
        children: [
          for (final rx in list)
            ListTile(
              key: Key('needs-price-${rx.id}'),
              contentPadding: EdgeInsets.zero,
              title: Text(rx.medicationDetails),
              subtitle: Text(rx.patientName ?? 'Patient'),
              trailing: FilledButton.tonal(
                key: Key('price-${rx.id}'),
                onPressed: () => _price(context, ref, rx),
                child: const Text('Set price'),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------- lookup + quick actions ----------------

class _QuickActions extends ConsumerWidget {
  const _QuickActions();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ready = (ref.watch(pharmacyQueueProvider).value?.orders ?? const [])
        .where((o) => o.status == Fulfilment.preparing)
        .length;
    Widget link(String key, IconData icon, String label, String path) => OutlinedButton.icon(
      key: Key(key),
      onPressed: () => context.go(path),
      icon: Icon(icon),
      label: Align(alignment: Alignment.centerLeft, child: Text(label)),
    );
    return PharmacySection(
      icon: Icons.bolt_outlined,
      title: 'Quick actions',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '$ready order${ready == 1 ? '' : 's'} to prepare',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('quick-new-stock'),
            onPressed: () => addStockItem(context, ref),
            icon: const Icon(Icons.add_box_outlined),
            label: const Align(alignment: Alignment.centerLeft, child: Text('New stock')),
          ),
          link(
            'quick-tracking',
            Icons.local_shipping_outlined,
            'Track orders',
            '/pharmacy/tracking',
          ),
          link('quick-inventory', Icons.inventory_2_outlined, 'Inventory', '/pharmacy/inventory'),
          link('quick-patients', Icons.people_outline, 'Patients', '/pharmacy/patients'),
          link('quick-messages', Icons.chat_bubble_outline, 'Messages', '/pharmacy/messages'),
        ].expand((w) => [w, const SizedBox(height: 8)]).toList(),
      ),
    );
  }
}

/// D-73/D-74: prescriptions the doctor has issued that wait for the patient to confirm and
/// pay; listed inside the queue (with Cancel) and moved up once paid.
class _WaitingForPatient extends ConsumerWidget {
  const _WaitingForPatient();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final waiting = ref.watch(ordersOverviewProvider((group: 'awaiting_patient', query: '')));
    final orders = waiting.value?.orders ?? const <MedicationOrder>[];
    if (orders.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(8),
        child: Text('No orders waiting for a patient.'),
      );
    }
    return KeyedSubtree(
      key: const Key('waiting-for-patient'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Issued by the doctor; the patient still has to confirm and pay.'),
          for (final o in orders)
            ListTile(
              key: Key('incoming-${o.id}'),
              contentPadding: EdgeInsets.zero,
              onTap: () => context.go('/pharmacy/patients/${o.patientId}'),
              leading: const Icon(Icons.hourglass_top_outlined),
              title: Text(
                '${o.patientName ?? 'Patient'} · '
                '${o.items.isEmpty ? o.medicationDetails : o.items.map((i) => '${i.label} ×${i.quantity}').join(', ')}',
              ),
              subtitle: Text(
                [
                  o.ref,
                  o.status.label,
                  if (o.total != null) rm(o.total!) else 'awaiting price',
                ].join(' · '),
              ),
              trailing: TextButton(
                key: Key('cancel-${o.id}'),
                onPressed: () => cancelOrderWithReason(context, ref, o),
                child: const Text('Cancel'),
              ),
            ),
        ],
      ),
    );
  }
}
