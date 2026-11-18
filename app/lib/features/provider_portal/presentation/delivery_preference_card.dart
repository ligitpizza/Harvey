import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/services/api/api_client.dart';
import '../../orders/presentation/pharmacy_shared.dart' show PromptDialog;
import '../state/portal_providers.dart';

/// D-72 (M8): how the patient gets their medicines, from their latest order. Shown on the
/// doctor's patient page (Medications tab) and on the Prescription page.
class DeliveryPreferenceCard extends ConsumerWidget {
  const DeliveryPreferenceCard({super.key, required this.patientId});
  final String patientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(deliveryPreferenceProvider(patientId));
    return Card(
      key: const Key('delivery-preference'),
      child: value.when(
        loading: () => const ListTile(
          dense: true,
          leading: Icon(Icons.local_shipping_outlined),
          title: Text('Medication delivery'),
          subtitle: LinearProgressIndicator(),
        ),
        error: (_, _) => ListTile(
          dense: true,
          leading: const Icon(Icons.cloud_off),
          title: const Text('Medication delivery'),
          subtitle: const Text('Could not load the delivery preference.'),
          trailing: TextButton(
            onPressed: () => ref.invalidate(deliveryPreferenceProvider(patientId)),
            child: const Text('Retry'),
          ),
        ),
        data: (pref) {
          final method = switch (pref['method']) {
            'home_delivery' => 'Home delivery',
            'self_collection' => 'Self-collection at the pharmacy',
            _ => 'Not chosen yet',
          };
          final status = pref['latestStatus'] as String?;
          final orderId = pref['latestOrderId'] as String?;
          final skipReason = pref['latestSkipReason'] as String?;
          final tile = ListTile(
            dense: true,
            leading: Icon(
              pref['method'] == 'home_delivery'
                  ? Icons.local_shipping_outlined
                  : Icons.storefront_outlined,
            ),
            title: Text('Medication delivery: $method'),
            subtitle: Text(
              '${pref['orders'] ?? 0} order(s)'
              '${status == null ? '' : ' · latest ${status.replaceAll('_', ' ')}'}'
              '${status == 'skipped' && skipReason != null ? ' ($skipReason)' : ''}',
            ),
          );
          if (pref['latestSkippable'] != true || orderId == null) return tile;
          // D-104: only the doctor skips a month of a recurring prescription.
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              tile,
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: OutlinedButton.icon(
                  key: const Key('doctor-skip-month'),
                  onPressed: () => _skip(context, ref, orderId),
                  icon: const Icon(Icons.event_busy_outlined),
                  label: const Text('Skip this month'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _skip(BuildContext context, WidgetRef ref, String orderId) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => const PromptDialog(
        title: "Skip this month's order?",
        message:
            "The patient and the pharmacy are told, and the pharmacy won't prepare it. "
            "Next month's order comes as usual.",
        fieldKey: Key('skip-reason'),
        label: 'Reason (e.g. bought at another pharmacy)',
        confirmKey: Key('skip-confirm'),
        confirmText: 'Skip this month',
        maxLength: 300,
      ),
    );
    final text = reason?.trim() ?? '';
    if (text.length < 3 || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(portalRepositoryProvider).skipOrder(orderId, text);
      ref.invalidate(deliveryPreferenceProvider(patientId));
      messenger.showSnackBar(const SnackBar(content: Text('This month is skipped.')));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}
