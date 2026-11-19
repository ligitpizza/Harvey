import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/enums.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/bp_classifier.dart';
import '../../../core/utils/risk_style.dart';
import '../../ai_agent/presentation/agent_update_card.dart';
import '../../charts/presentation/risk_trend_card.dart' show complicationNames;
import '../data/vitals_repository.dart';
import 'bp_widgets.dart';

/// Fig 4.3.3.3 Reading Saved: confirms the entry with its BP category and heart rate.
/// D-121: restyled with a hero card, the AHA scale and stat tiles.
class ReadingSavedPage extends StatelessWidget {
  const ReadingSavedPage({super.key, required this.reading});

  final LoggedReading reading;

  @override
  Widget build(BuildContext context) {
    final color = BpClassifier.color(reading.category);
    final t = reading.loggedAt;
    final time =
        '${t.hour % 12 == 0 ? 12 : t.hour % 12}:${t.minute.toString().padLeft(2, '0')} '
        '${t.hour < 12 ? 'AM' : 'PM'}';
    final theme = Theme.of(context);
    final reason = categoryReason(reading.systolic, reading.diastolic);
    return Scaffold(
      appBar: AppBar(title: const Text('Reading Saved')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          if (reading.category == BpCategory.crisis) const _CrisisBanner(),
          Container(
            key: const Key('saved-card'),
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
                    const CircleAvatar(
                      radius: 14,
                      backgroundColor: BpColors.normal,
                      child: Icon(Icons.check_rounded, size: 18, color: Colors.white),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Reading saved',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text('Today, $time', style: theme.textTheme.bodySmall),
                        ],
                      ),
                    ),
                    StatusPill(
                      key: const Key('saved-category'),
                      label: BpClassifier.label(reading.category),
                      color: color,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${reading.systolic}/${reading.diastolic}',
                      key: const Key('saved-value'),
                      style: theme.textTheme.displayMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.onSurface,
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
                BpScaleBar(category: reading.category),
                const SizedBox(height: 12),
                Text(
                  reason ?? categoryMeaning(reading.category),
                  key: const Key('saved-meaning'),
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                BpStatRow(
                  systolic: reading.systolic,
                  diastolic: reading.diastolic,
                  heartRate: reading.heartRate,
                ),
                if (reading.heartRate != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    'A heart rate from the phone camera is an estimate.',
                    key: const Key('saved-hr'),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    key: const Key('saved-view-trends'),
                    onPressed: () => context.pushReplacement('/trends'),
                    icon: const Icon(Icons.trending_up),
                    label: const Text('View Trends'),
                  ),
                ),
              ],
            ),
          ),
          if (reading.bookAppointmentPrompt) ...[
            const SizedBox(height: 16),
            _BookAppointmentCard(mild: reading.alertLevel == AlertLevel.mild),
          ],
          // UC2.7: proactive AI update once a risk score exists (D-34).
          if (reading.risk != null) ...[const SizedBox(height: 16), const AgentUpdateCard()],
          const SizedBox(height: 16),
          if (reading.risk != null)
            _RiskCard(risk: reading.risk!)
          else if (reading.readingsUntilRisk > 0)
            Panel(
              key: const Key('saved-risk-progress'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SectionHeader(icon: Icons.insights_outlined, title: 'Risk assessment'),
                  const SizedBox(height: 12),
                  Text(
                    'Log ${reading.readingsUntilRisk} more '
                    'reading${reading.readingsUntilRisk == 1 ? '' : 's'} '
                    'to get your risk assessment.',
                  ),
                ],
              ),
            ),
          const SizedBox(height: 16),
          if (reading.recommendations.isEmpty)
            const Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SectionHeader(icon: Icons.emoji_events_outlined, title: 'Great job logging!'),
                  SizedBox(height: 12),
                  Text(
                    'Consistent tracking helps you and your doctor understand your heart health '
                    'better. Keep it up!',
                  ),
                ],
              ),
            )
          else
            _RecommendationsCard(tips: reading.recommendations),
          const SizedBox(height: 20),
          SizedBox(
            height: 52,
            child: FilledButton.tonal(
              onPressed: () => context.canPop() ? context.pop() : context.go('/dashboard'),
              child: const Text('Done'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Health-safety message for a crisis-range reading (CLAUDE.md: emergency number 999).
/// Doctor/family escalation is delivered by Module 9 (Increment 2).
class _CrisisBanner extends StatelessWidget {
  const _CrisisBanner();

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const Key('crisis-banner'),
      color: BpClassifier.color(BpCategory.crisis),
      margin: const EdgeInsets.only(bottom: 16),
      child: const Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          'This reading is very high. Sit quietly for 5 minutes and measure again. '
          'If you have chest pain, shortness of breath, weakness, confusion or blurred vision, '
          'call 999 now.',
          style: TextStyle(color: Colors.white),
        ),
      ),
    );
  }
}

/// UC9.2 / UC9.3: high reading or risk. Booking itself is FR-7.5 (appointments module).
class _BookAppointmentCard extends StatelessWidget {
  const _BookAppointmentCard({this.mild = false});

  /// D-37 Mild: an optional offer; the doctor gets the daily BP report.
  final bool mild;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const Key('saved-book-prompt'),
      color: mild
          ? Theme.of(context).colorScheme.secondaryContainer
          : Theme.of(context).colorScheme.errorContainer,
      child: ListTile(
        leading: const Icon(Icons.event_available),
        title: Text(
          mild ? 'Would you like to book an appointment?' : 'Please see your doctor soon',
        ),
        subtitle: Text(
          mild
              ? 'Your reading is slightly high. Your doctor will receive a BP report, and you '
                    'can book an appointment if you would like to talk it through.'
              : 'Your doctor has been notified. Avoid heavy physical exertion and book an '
                    'appointment to review your treatment.',
        ),
        trailing: TextButton(
          key: const Key('saved-book-button'),
          onPressed: () => context.push('/appointments'),
          child: const Text('Book'),
        ),
      ),
    );
  }
}

/// UC9.1 result: overall level and each complication (FR-9.2, FR-9.3).
class _RiskCard extends StatelessWidget {
  const _RiskCard({required this.risk});

  final ReadingRisk risk;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall;
    final rows = [
      for (final c in Complication.values)
        if (risk.scores[c] != null) c,
    ];
    return Panel(
      key: const Key('saved-risk'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            icon: Icons.insights_outlined,
            title: 'Risk assessment',
            trailing: StatusPill(
              key: const Key('saved-risk-overall'),
              label: riskLabel(risk.overall),
              color: riskColor(risk.overall),
            ),
          ),
          const SizedBox(height: 6),
          Text('Estimated chance of each complication.', style: muted),
          const SizedBox(height: 6),
          for (final (i, c) in rows.indexed) ...[
            if (i > 0)
              Divider(height: 1, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4)),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  Expanded(child: Text(complicationNames[c]!)),
                  if (risk.diagnosed.contains(c))
                    Text('Already diagnosed', key: Key('saved-diagnosed-${c.value}'), style: muted)
                  else
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                      decoration: BoxDecoration(
                        color: riskColor(risk.scores[c]!.level).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        riskPercent(risk.scores[c]!.value),
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: riskColor(risk.scores[c]!.level),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
          if (risk.lowConfidence) ...[
            const SizedBox(height: 8),
            Text(
              'Some health details are missing, so this estimate is less certain. '
              'Complete your health profile to improve it.',
              key: const Key('saved-risk-low-confidence'),
              style: muted,
            ),
          ],
        ],
      ),
    );
  }
}

/// FR-9.4 personalised tips; the server always ends with the not-a-doctor disclaimer.
class _RecommendationsCard extends StatelessWidget {
  const _RecommendationsCard({required this.tips});

  final List<String> tips;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = tips.length > 1 ? tips.sublist(0, tips.length - 1) : tips;
    return Panel(
      key: const Key('saved-recommendations'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(icon: Icons.lightbulb_outline, title: 'Recommendations'),
          const SizedBox(height: 8),
          for (final tip in body)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.check_circle_outline, size: 18, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(child: Text(tip)),
                ],
              ),
            ),
          if (tips.length > 1) ...[
            const SizedBox(height: 8),
            Text(tips.last, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}
