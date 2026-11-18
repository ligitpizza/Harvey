import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/enums.dart';
import '../../../core/utils/bp_classifier.dart';
import '../../../shared/models/health_models.dart';
import '../../symptom_checker/presentation/triage_result_page.dart';
import '../../symptom_checker/state/symptom_providers.dart';

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

/// What each category means, in plain words (AHA categories, D-02).
String categoryMeaning(BpCategory c) => switch (c) {
  BpCategory.normal => 'Below 120/80. Keep up your healthy habits.',
  BpCategory.elevated =>
    'Systolic 120 to 129 with diastolic below 80. Lifestyle changes help keep it from rising.',
  BpCategory.stage1 =>
    'Systolic 130 to 139 or diastolic 80 to 89. Follow your treatment plan and keep logging.',
  BpCategory.stage2 =>
    'Systolic 140 or more, or diastolic 90 or more. Talk to your doctor if it stays this high.',
  BpCategory.crisis =>
    'Above 180/120. Rest 5 minutes and measure again. If it stays this high, or you have '
        'chest pain, breathlessness, weakness or confusion, call 999.',
};

class ReadingDetailPage extends ConsumerWidget {
  const ReadingDetailPage({super.key, required this.reading, this.staff = false});

  final VitalReading reading;
  final bool staff;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = BpClassifier.classify(reading.systolic, reading.diastolic);
    final color = BpClassifier.color(c);
    final theme = Theme.of(context);
    final check = ref.watch(triageForReadingProvider((reading.patientId, reading.id)));
    return Scaffold(
      appBar: AppBar(title: const Text('Reading details')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            key: const Key('reading-detail-bp'),
            clipBehavior: Clip.antiAlias,
            child: Container(
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: color, width: 6)),
              ),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(readingTime(reading.timestamp), style: theme.textTheme.bodySmall),
                  const SizedBox(height: 4),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '${reading.systolic}/${reading.diastolic}',
                          style: theme.textTheme.displaySmall,
                        ),
                        const TextSpan(text: ' mmHg'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Chip(
                    key: const Key('reading-detail-category'),
                    avatar: CircleAvatar(backgroundColor: color, radius: 6),
                    label: Text(BpClassifier.label(c)),
                  ),
                  Text(categoryMeaning(c)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.arrow_upward),
                  title: const Text('Systolic (top number)'),
                  trailing: Text('${reading.systolic} mmHg'),
                ),
                ListTile(
                  leading: const Icon(Icons.arrow_downward),
                  title: const Text('Diastolic (bottom number)'),
                  trailing: Text('${reading.diastolic} mmHg'),
                ),
                ListTile(
                  key: const Key('reading-detail-hr'),
                  leading: const Icon(Icons.favorite_border),
                  title: const Text('Heart rate'),
                  subtitle: reading.heartRate == null
                      ? null
                      : const Text(
                          'From the camera or your monitor; a camera reading is an '
                          'estimate.',
                        ),
                  trailing: Text(
                    reading.heartRate == null ? 'Not measured' : '${reading.heartRate} bpm',
                  ),
                ),
                if (reading.note != null && reading.note!.trim().isNotEmpty)
                  ListTile(
                    key: const Key('reading-detail-note'),
                    leading: const Icon(Icons.sticky_note_2_outlined),
                    title: const Text('Note'),
                    subtitle: Text(reading.note!),
                  ),
              ],
            ),
          ),
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
