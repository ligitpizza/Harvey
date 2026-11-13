import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../appointments/domain/appointment_text.dart' show timeLabel;
import '../data/admin_repository.dart';
import '../../../shared/providers/api_providers.dart';
import '../state/admin_providers.dart';
import '../../../shared/widgets/page_header.dart';

(String, Color) statusStyle(String status) => switch (status) {
  'operational' => ('Operational', Colors.teal.shade600),
  'degraded' => ('Degraded', Colors.orange.shade700),
  'simulated' => ('Simulated', Colors.blueGrey),
  'not_configured' => ('Not configured', Colors.blueGrey),
  _ => ('Down', Colors.red.shade700),
};

IconData _icon(String key) => switch (key) {
  'api' => Icons.hub_outlined,
  'firestore' => Icons.storage_outlined,
  'ml' => Icons.psychology_outlined,
  'push' => Icons.notifications_outlined,
  'email' => Icons.email_outlined,
  'ai' => Icons.smart_toy_outlined,
  'stripe' => Icons.payments_outlined,
  'grab' => Icons.local_shipping_outlined,
  _ => Icons.settings_outlined,
};

String _percent(double? v) => v == null ? '—' : '${v.toStringAsFixed(2)}%';

String _ms(double? v) => v == null ? '—' : '${v.round()}ms';

/// System Health (Fig 4.3.14.7; FR-11.3; D-59).
class SystemHealthPage extends ConsumerWidget {
  const SystemHealthPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final health = ref.watch(systemHealthProvider);
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        PageHeader(
          title: 'System Health',
          subtitle:
              'Live status of every service. Test one, read its recent errors or open its console.',
          icon: Icons.health_and_safety_outlined,
          color: Colors.green.shade700,
        ),
        health.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, _) => ListTile(
            leading: const Icon(Icons.cloud_off),
            title: const Text('Could not check the system.'),
            trailing: TextButton(
              onPressed: () => ref.invalidate(systemHealthProvider),
              child: const Text('Retry'),
            ),
          ),
          data: (h) {
            final (label, color) = statusStyle(h.overall);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  key: const Key('health-overview'),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.circle, size: 12, color: color),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text('System overview', style: theme.textTheme.titleLarge),
                            ),
                            Chip(
                              key: const Key('health-overall'),
                              label: Text(
                                h.overall == 'operational'
                                    ? 'All systems operational'
                                    : 'Attention: $label',
                              ),
                              labelStyle: TextStyle(color: color),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 48,
                          runSpacing: 12,
                          children: [
                            _Big('API uptime (30 days)', _percent(h.uptime)),
                            _Big('Average latency', _ms(h.averageLatencyMs)),
                            _Big(
                              'Services',
                              '${h.services.where((s) => s.status == 'operational').length}'
                                  '/${h.services.length} live',
                            ),
                          ],
                        ),
                        const Divider(height: 24),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                h.checkedAt == null
                                    ? 'Last checked: just now'
                                    : 'Last checked: ${timeLabel(h.checkedAt!)} MYT',
                              ),
                            ),
                            TextButton.icon(
                              key: const Key('health-refresh'),
                              onPressed: () => ref.invalidate(systemHealthProvider),
                              icon: const Icon(Icons.refresh),
                              label: const Text('Refresh'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text('Service status', style: theme.textTheme.titleLarge),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  children: [for (final s in h.services) _ServiceCard(service: s)],
                ),
                const SizedBox(height: 12),
                Text(
                  'Uptime counts the 15-minute scheduled sweep: runs received ÷ runs expected '
                  'over 30 days. Simulated services use test adapters.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _Big extends StatelessWidget {
  const _Big(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label.toUpperCase(), style: Theme.of(context).textTheme.labelMedium),
      Text(value, style: Theme.of(context).textTheme.headlineMedium),
    ],
  );
}

/// D-79: where each service is managed (opens in a new tab).
const _consoles = {
  'api': (
    'Cloud Run logs',
    'https://console.cloud.google.com/run/detail/asia-southeast1/careflow-api/logs?project=hypertension-dd85f',
  ),
  'firestore': (
    'Firestore console',
    'https://console.firebase.google.com/project/hypertension-dd85f/firestore',
  ),
  'ml': (
    'Cloud Run service',
    'https://console.cloud.google.com/run/detail/asia-southeast1/careflow-api/revisions?project=hypertension-dd85f',
  ),
  'push': (
    'Firebase Messaging',
    'https://console.firebase.google.com/project/hypertension-dd85f/messaging',
  ),
  'email': ('Brevo dashboard', 'https://app.brevo.com/'),
  'ai': ('Google AI Studio', 'https://aistudio.google.com/'),
  'sms': ('Brevo SMS', 'https://app.brevo.com/sms/campaign/listing'),
  'stripe': ('Stripe test dashboard', 'https://dashboard.stripe.com/test/payments'),
  'grab': ('Lalamove partner portal', 'https://partnerportal.lalamove.com/'),
};

class _ServiceCard extends ConsumerStatefulWidget {
  const _ServiceCard({required this.service});

  final ServiceHealth service;

  static const width = 300.0;
  static const height = 236.0;

  @override
  ConsumerState<_ServiceCard> createState() => _ServiceCardState();
}

class _ServiceCardState extends ConsumerState<_ServiceCard> {
  bool _testing = false;
  Map<String, dynamic>? _result;

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _result = null;
    });
    try {
      final r = await ref.read(apiClientProvider).testService(widget.service.key);
      if (mounted) setState(() => _result = r);
    } catch (_) {
      if (mounted) {
        setState(() => _result = {'ok': false, 'message': 'The test could not be run.'});
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _errors() async {
    final key = widget.service.key;
    await showDialog<void>(
      context: context,
      builder: (c) => Consumer(
        builder: (context, ref, _) => AlertDialog(
          title: Text('Recent errors · ${widget.service.name}'),
          content: SizedBox(
            width: 560,
            height: 360,
            child: FutureBuilder<Map<String, dynamic>>(
              future: ref.read(apiClientProvider).serviceErrors(key),
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) return const Text('Could not load the errors.');
                final errs = [
                  for (final e in snap.data?['errors'] as List<dynamic>? ?? const [])
                    Map<String, dynamic>.from(e as Map),
                ];
                if (errs.isEmpty) {
                  return const Center(
                    key: Key('no-errors'),
                    child: Text('No errors since the backend last started.'),
                  );
                }
                return ListView(
                  children: [
                    for (final e in errs)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.error_outline, color: Colors.red),
                        title: SelectableText('${e['message']}'),
                        subtitle: Text(_errorTime('${e['at']}')),
                      ),
                  ],
                );
              },
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.service;
    final (label, color) = statusStyle(s.status);
    final theme = Theme.of(context);
    final console = _consoles[s.key];
    final result = _result;
    return SizedBox(
      width: _ServiceCard.width,
      height: _ServiceCard.height,
      child: Card(
        key: Key('service-${s.key}'),
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: color, width: 2),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(_icon(s.key)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      s.name,
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text('● $label', style: TextStyle(color: color)),
                  const SizedBox(width: 8),
                ],
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Row(
                  children: [
                    Expanded(child: _Big('Uptime', _percent(s.uptime))),
                    _Big('Latency', _ms(s.latencyMs)),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                result == null ? s.note : '${result['message']}',
                key: Key('service-note-${s.key}'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: result == null
                    ? theme.textTheme.bodySmall
                    : theme.textTheme.bodySmall?.copyWith(
                        color: result['ok'] == true
                            ? Colors.green.shade700
                            : theme.colorScheme.error,
                        fontWeight: FontWeight.w600,
                      ),
              ),
              const Spacer(),
              if (_testing)
                const LinearProgressIndicator(minHeight: 4)
              else
                LinearProgressIndicator(value: 1, color: color, minHeight: 4),
              // D-79: act on the service, not just read it.
              Row(
                children: [
                  TextButton(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    key: Key('test-${s.key}'),
                    onPressed: _testing ? null : _test,
                    child: const Text('Test now'),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    key: Key('errors-${s.key}'),
                    onPressed: _errors,
                    child: const Text('Errors'),
                  ),
                  const Expanded(child: SizedBox()),
                  if (console != null)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      key: Key('console-${s.key}'),
                      tooltip: 'Open ${console.$1}',
                      icon: const Icon(Icons.open_in_new, size: 20),
                      onPressed: () => ref.read(urlOpenerProvider)(console.$2),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _errorTime(String iso) {
  final t = DateTime.tryParse(iso)?.toLocal();
  if (t == null) return iso;
  return '${t.day}/${t.month} ${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';
}
