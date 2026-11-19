import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/enums.dart';
import '../../../core/utils/bp_classifier.dart';
import '../../../shared/models/health_models.dart';
import '../../symptom_checker/presentation/triage_result_page.dart';
import '../../symptom_checker/state/symptom_providers.dart';
import 'bp_widgets.dart';

export 'bp_widgets.dart' show categoryMeaning;

/// D-110: one BP reading in full, for the patient (Vitals, Health Trends) and the doctor
/// (patient vitals). [staff] hides the patient-only actions on a linked symptom check.
Future<void> openReading(BuildContext context, VitalReading reading, {bool staff = false}) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReadingDetailPage(reading: reading, staff: staff),
      ),
    );

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

/// "Wed 18 Nov 2026, 9:05 AM" (local time).
String readingTime(DateTime t) {
  final l = t.toLocal();
  final h = l.hour % 12 == 0 ? 12 : l.hour % 12;
  return '${_days[l.weekday - 1]} ${l.day} ${_months[l.month - 1]} ${l.year}, '
      '$h:${l.minute.toString().padLeft(2, '0')} ${l.hour < 12 ? 'AM' : 'PM'}';
}

class ReadingDetailPage extends ConsumerWidget {
  const ReadingDetailPage({super.key, required this.reading, this.staff = false});

  final VitalReading reading;
  final bool staff;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = BpClassifier.classify(reading.systolic, reading.diastolic);
    final color = BpClassifier.color(c);
    final theme = Theme.of(context);
    final reason = categoryReason(reading.systolic, reading.diastolic);
    final check = ref.watch(triageForReadingProvider((reading.patientId, reading.id)));
    return Scaffold(
      appBar: AppBar(title: const Text('Reading details')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // D-121: hero with the reading, its place on the AHA scale and why.
          Container(
            key: const Key('reading-detail-bp'),
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [color.withValues(alpha: 0.16), theme.colorScheme.surface],
              ),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: color.withValues(alpha: 0.35)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.event_note_outlined, size: 18, color: theme.colorScheme.primary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(readingTime(reading.timestamp), style: theme.textTheme.bodySmall),
                    ),
                    StatusPill(
                      key: const Key('reading-detail-category'),
                      label: BpClassifier.label(c),
                      color: color,
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${reading.systolic}/${reading.diastolic}',
                      style: theme.textTheme.displayMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        height: 1,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text('mmHg', style: theme.textTheme.titleMedium),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                BpScaleBar(category: c),
                const SizedBox(height: 12),
                Text(categoryMeaning(c)),
                if (reason != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    key: const Key('reading-detail-reason'),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface.withValues(alpha: 0.8),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline, size: 18, color: color),
                        const SizedBox(width: 8),
                        Expanded(child: Text(reason, style: theme.textTheme.bodySmall)),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          BpStatRow(
            key: const Key('reading-detail-hr'),
            systolic: reading.systolic,
            diastolic: reading.diastolic,
            heartRate: reading.heartRate,
            source: reading.heartRateSource,
          ),
          if (reading.heartRate != null && reading.heartRateSource != HeartRateSource.manual)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 4),
              child: Text(
                'Heart rate ${reading.heartRate} bpm. A reading from the phone camera is an '
                'estimate.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          if (reading.note != null && reading.note!.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            Panel(
              key: const Key('reading-detail-note'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SectionHeader(icon: Icons.sticky_note_2_outlined, title: 'Note'),
                  const SizedBox(height: 10),
                  Text(reading.note!),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          // D-110/D-111: the symptom check this reading was taken for, if any.
          ...check.maybeWhen(
            data: (id) => [
              if (id != null)
                Card(
                  key: const Key('reading-detail-triage'),
                  child: ListTile(
                    leading: const Icon(Icons.health_and_safety_outlined),
                    title: const Text('Symptom check with this reading'),
                    subtitle: const Text('See the triage result and advice.'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => TriageResultLoader(id: id, staff: staff),
                      ),
                    ),
                  ),
                ),
            ],
            orElse: () => const <Widget>[],
          ),
          const SizedBox(height: 12),
          Text(
            'Categories follow the American Heart Association blood pressure chart. '
            'This is not a diagnosis.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
