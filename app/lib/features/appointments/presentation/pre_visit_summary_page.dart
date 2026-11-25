import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/enums.dart';
import '../../../core/utils/risk_style.dart';
import '../../charts/presentation/risk_trend_card.dart' show complicationNames;
import '../domain/appointment_text.dart';
import '../state/appointment_providers.dart';

/// UC7.5 pre-visit summary, shared by the patient app and the doctor portal (FR-7.4).
class PreVisitSummaryPage extends ConsumerWidget {
  const PreVisitSummaryPage({super.key, required this.appointmentId});

  final String appointmentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('Pre-visit summary')),
    body: PreVisitSummaryView(appointmentId: appointmentId),
  );
}

class PreVisitSummaryView extends ConsumerWidget {
  const PreVisitSummaryView({super.key, required this.appointmentId});

  final String appointmentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(preVisitSummaryProvider(appointmentId));
    return summary.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => Center(
        child: TextButton(
          onPressed: () => ref.invalidate(preVisitSummaryProvider(appointmentId)),
          child: const Text('Could not load the summary. Retry'),
        ),
      ),
      data: (s) => _Body(s: s),
    );
  }
}

/// D-127: overall level = the highest complication level (D-03: not stored), or null.
RiskLevel? overallRiskLevel(Map<String, dynamic> risk) {
  final stored = risk['overallLevel'];
  if (stored is String) {
    try {
      return RiskLevel.fromValue(stored);
    } catch (_) {}
  }
  RiskLevel? top;
  for (final v in ((risk['scores'] as Map?) ?? const {}).values) {
    final level = v is Map ? v['level'] : null;
    if (level is! String) continue;
    try {
      final l = RiskLevel.fromValue(level);
      if (top == null || l.index > top.index) top = l;
    } catch (_) {}
  }
  return top;
}

String _complicationName(String key) {
  try {
    return complicationNames[Complication.fromValue(key)] ?? key;
  } catch (_) {
    return key;
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.s});

  final Map<String, dynamic> s;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vitals = s['vitals'] as Map<String, dynamic>?;
    final risk = s['risk'] as Map<String, dynamic>?;
    final meds = (s['medications'] as List? ?? const []).cast<Map<dynamic, dynamic>>();
    final gaps = (s['dataGaps'] as List? ?? const []).cast<String>();
    final open = (s['openItems'] as List? ?? const []).cast<String>();
    final when = DateTime.tryParse('${s['dateTime']}');
    final overall = risk == null ? null : overallRiskLevel(risk);

    Widget section(IconData icon, String title, List<Widget> children, {Widget? trailing}) => Card(
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
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      ),
    );

    Widget stat(String label, String value) => Expanded(
      child: Container(
        padding: const EdgeInsets.all(10),
        margin: const EdgeInsets.symmetric(horizontal: 3),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: theme.textTheme.labelSmall),
            const SizedBox(height: 2),
            Text(value, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );

    Widget pill(String text, Color c, {Key? key}) => Container(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelMedium?.copyWith(color: c, fontWeight: FontWeight.w600),
      ),
    );

    final scores = <(String, double, RiskLevel?)>[];
    for (final e in ((risk?['scores'] as Map?) ?? const {}).entries) {
      if (e.value is! Map) continue;
      final m = e.value as Map;
      RiskLevel? level;
      try {
        level = RiskLevel.fromValue('${m['level']}');
      } catch (_) {}
      scores.add((_complicationName('${e.key}'), ((m['value'] as num?) ?? 0).toDouble(), level));
    }
    scores.sort((a, b) => b.$2.compareTo(a.$2));

    return ListView(
      key: const Key('pre-visit-summary'),
      padding: const EdgeInsets.all(16),
      children: [
        if (when != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'For ${dateLabel(when)}, ${timeLabel(when)}',
              style: theme.textTheme.bodySmall,
            ),
          ),
        if (gaps.isNotEmpty)
          Card(
            key: const Key('summary-gaps'),
            color: theme.colorScheme.tertiaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Missing information'),
                  for (final g in gaps) Text('• $g', style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ),
        section(Icons.favorite_outline, 'Blood pressure (last 14 days)', [
          if (vitals == null)
            const Text('No readings.')
          else ...[
            Row(
              children: [
                stat('Average', '${vitals['averageSystolic']}/${vitals['averageDiastolic']}'),
                stat('Highest', '${vitals['highest']}'),
                stat('Latest', '${vitals['latest']}'),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${vitals['count']} readings, mmHg'
              '${vitals['averageHeartRate'] == null ? '' : ' · average heart rate ${vitals['averageHeartRate']} bpm (estimate)'}',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ]),
        section(
          Icons.insights_outlined,
          'Risk assessment',
          [
            if (risk == null)
              const Text('Not available yet.')
            else
              for (final (name, value, level) in scores)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(child: Text(name)),
                      pill(
                        riskPercent(value),
                        level == null ? theme.colorScheme.outline : riskColor(level),
                      ),
                    ],
                  ),
                ),
          ],
          trailing: overall == null
              ? null
              : pill(riskLabel(overall), riskColor(overall), key: const Key('summary-overall')),
        ),
        section(Icons.medication_outlined, 'Medicines', [
          if (meds.isEmpty) const Text('None recorded.'),
          for (final m in meds)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Expanded(child: Text('${m['name']}')),
                  if (m['adherenceRate'] != null)
                    Text(
                      'adherence ${(m['adherenceRate'] as num).round()}%',
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
            ),
          for (final o in open) Text(o, style: TextStyle(color: theme.colorScheme.error)),
        ]),
        if (s['carePlan'] != null)
          section(Icons.assignment_outlined, 'Care plan', [Text('${s['carePlan']}')]),
        const SizedBox(height: 8),
        Text(
          'A summary of the records to discuss at the visit; not a diagnosis.',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}
