import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/enums.dart';
import '../../../core/utils/bp_classifier.dart';
import '../../../core/utils/risk_style.dart';
import '../../symptom_checker/presentation/triage_result_page.dart';
import '../../symptom_checker/state/symptom_providers.dart';
import '../../vitals/presentation/reading_detail_page.dart';
import '../domain/portal_models.dart';
import '../state/portal_providers.dart';
import 'portal_widgets.dart';

/// One clinical alert in full (UAT): what happened, when, what triggered it (the reading
/// and its symptom check), what to do next, and acknowledge / dismiss while it is open.
Future<void> openAlert(BuildContext context, ClinicalAlert alert) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => AlertDetailPage(alert: alert)));

/// Suggested next steps for the doctor, by alert type and severity.
List<String> alertNextSteps(ClinicalAlert a) {
  final urgent = a.severity == RiskLevel.critical;
  return switch (a.type) {
    ClinicalAlertType.threshold => [
      if (urgent) 'Contact the patient now; advise 999 if they have symptoms.',
      'Ask them to rest 5 minutes and re-measure.',
      'Review their medicines and adherence.',
    ],
    ClinicalAlertType.triage => [
      if (urgent) 'Call the patient now; the checker advised emergency care.',
      'Open the symptom check to see what they reported.',
      'Book a review if symptoms continue.',
    ],
    ClinicalAlertType.riskEscalation || ClinicalAlertType.deterioration => [
      'Review the risk assessment and recent trend.',
      'Consider a medication review or earlier appointment.',
    ],
    ClinicalAlertType.flaggedMessage => [
      'Open the conversation and reply to the patient.',
      if (urgent) 'Call them if the message suggests an emergency.',
    ],
    ClinicalAlertType.lowAdherence || ClinicalAlertType.medicationReview => [
      'Check the Medications tab for missed doses.',
      'Message the patient about barriers to taking them.',
    ],
  };
}

class AlertDetailPage extends ConsumerWidget {
  const AlertDetailPage({super.key, required this.alert});

  final ClinicalAlert alert;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final color = riskColor(alert.severity);
    final escalated = alert.message.startsWith('ESCALATED');
    final message = alert.message.replaceFirst(RegExp(r'^(ESCALATED|URGENT)[^:]*:\s*'), '');
    final open = alert.status == ClinicalAlertStatus.open;
    final waited = DateTime.now().difference(alert.createdAt);
    final readingId = alert.vitalReadingId;
    return Scaffold(
      appBar: AppBar(title: Text(alertTypeLabel(alert.type))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            key: const Key('alert-header'),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
              border: Border(left: BorderSide(color: color, width: 6)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    _Pill(severityWord(alert.severity), color),
                    _Pill(switch (alert.status) {
                      ClinicalAlertStatus.open => 'Open',
                      ClinicalAlertStatus.acknowledged => 'Acknowledged',
                      ClinicalAlertStatus.dismissed => 'Dismissed',
                    }, open ? theme.colorScheme.error : Colors.green.shade700),
                    if (escalated) _Pill('Escalated: no response in 2 hours', color),
                  ],
                ),
                const SizedBox(height: 12),
                Text(message, key: const Key('alert-message'), style: theme.textTheme.bodyLarge),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.notifications_active_outlined),
                  title: const Text('Raised'),
                  trailing: Text(formatDate(alert.createdAt)),
                ),
                if (alert.acknowledgedAt != null)
                  ListTile(
                    leading: const Icon(Icons.task_alt),
                    title: Text(
                      alert.status == ClinicalAlertStatus.dismissed ? 'Dismissed' : 'Acknowledged',
                    ),
                    trailing: Text(formatDate(alert.acknowledgedAt!)),
                  )
                else if (open)
                  ListTile(
                    key: const Key('alert-waiting'),
                    leading: Icon(Icons.timer_outlined, color: theme.colorScheme.error),
                    title: const Text('Waiting for a response'),
                    trailing: Text(
                      waited.inHours >= 1
                          ? '${waited.inHours} h ${waited.inMinutes % 60} min'
                          : '${waited.inMinutes} min',
                    ),
                  ),
              ],
            ),
          ),
          if (readingId != null) _Trigger(patientId: alert.patientId, readingId: readingId),
          const SizedBox(height: 8),
          Text('Suggested next steps', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          for (final step in alertNextSteps(alert))
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.arrow_right),
              title: Text(step),
            ),
          if (open) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    key: const Key('alert-acknowledge'),
                    onPressed: () => _close(context, ref, ClinicalAlertStatus.acknowledged),
                    icon: const Icon(Icons.task_alt),
                    label: const Text('Acknowledge'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    key: const Key('alert-dismiss'),
                    onPressed: () => _close(context, ref, ClinicalAlertStatus.dismissed),
                    child: const Text('Dismiss'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Acknowledge when you have acted on it; dismiss if no action is needed.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _close(BuildContext context, WidgetRef ref, ClinicalAlertStatus status) async {
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    try {
      await ref.read(portalRepositoryProvider).closeAlert(alert.id, status);
      nav.pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            status == ClinicalAlertStatus.acknowledged ? 'Alert acknowledged.' : 'Alert dismissed.',
          ),
        ),
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not update the alert. Please try again.')),
      );
    }
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.text, this.color);
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.labelMedium?.copyWith(color: color, fontWeight: FontWeight.w600),
    ),
  );
}

/// The reading that raised the alert, and its symptom check if there was one.
class _Trigger extends ConsumerWidget {
  const _Trigger({required this.patientId, required this.readingId});

  final String patientId;
  final String readingId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reading = ref.watch(portalReadingProvider(readingId)).value;
    final check = ref.watch(triageForReadingProvider((patientId, readingId))).value;
    if (reading == null && check == null) return const SizedBox.shrink();
    return Card(
      key: const Key('alert-trigger'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text('What triggered it', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          if (reading != null)
            ListTile(
              key: const Key('alert-reading'),
              leading: CircleAvatar(
                radius: 6,
                backgroundColor: BpClassifier.color(
                  BpClassifier.classify(reading.systolic, reading.diastolic),
                ),
              ),
              title: Text(
                '${reading.systolic}/${reading.diastolic} mmHg'
                '${reading.heartRate == null ? '' : ' · ${reading.heartRate} bpm (estimate)'}',
              ),
              subtitle: Text(
                '${BpClassifier.label(BpClassifier.classify(reading.systolic, reading.diastolic))}'
                ' · ${formatDate(reading.timestamp)}',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => openReading(context, reading, staff: true),
            ),
          if (check != null)
            ListTile(
              key: const Key('alert-triage'),
              leading: const Icon(Icons.health_and_safety_outlined),
              title: const Text('Symptom check'),
              subtitle: const Text('What the patient reported and the advice given.'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => TriageResultLoader(id: check, staff: true)),
              ),
            ),
        ],
      ),
    );
  }
}
