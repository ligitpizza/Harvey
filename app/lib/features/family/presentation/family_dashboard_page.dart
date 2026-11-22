import '../../notifications/presentation/notification_bell.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/enums.dart';
import '../../../core/utils/bp_classifier.dart';
import '../../../core/utils/risk_style.dart';
import '../../../shared/models/health_models.dart';
import '../../appointments/domain/appointment_text.dart' show dateLabel, timeLabel;
import '../../dashboard/domain/dashboard_logic.dart' show greetingFor;
import '../../dashboard/state/dashboard_providers.dart';
import '../../medications/domain/med_schedule.dart' show toMyt;
import '../data/family_repository.dart';
import '../data/patient_location.dart';
import '../state/family_providers.dart';

final _readingsProvider = StreamProvider.autoDispose.family<List<VitalReading>, String>(
  (ref, id) => ref.watch(dashboardRepositoryProvider).recentReadings(id, limit: 60),
);
final _riskProvider = StreamProvider.autoDispose.family<RiskScore?, String>(
  (ref, id) => ref.watch(dashboardRepositoryProvider).latestRiskScore(id),
);

/// An unacknowledged alert from the last day is shown as a banner (UC15.3).
EmergencyAlert? activeAlert(List<EmergencyAlert> alerts, DateTime now) => alerts
    .where((a) => !a.isAcknowledged && now.difference(a.sentAt) < const Duration(hours: 24))
    .firstOrNull;

/// Family Dashboard (Fig 4.3.16.2; FR-14.2, UC15.1): read-only.
class FamilyDashboardPage extends ConsumerWidget {
  const FamilyDashboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final linked = ref.watch(linkedPatientIdProvider);
    final pending = ref.watch(myPendingLinkProvider).value;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Family Dashboard'),
        // D-124: the family member's notification inbox.
        actions: const [NotificationBell(page: '/family/notifications')],
      ),
      body: linked.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => const Center(child: Text('Could not load. Check your connection.')),
        data: (patientId) => patientId == null
            ? _NotLinked(pending: pending != null)
            : _Linked(patientId: patientId),
      ),
    );
  }
}

class _NotLinked extends StatelessWidget {
  const _NotLinked({required this.pending});

  final bool pending;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      Icon(pending ? Icons.hourglass_top : Icons.link, size: 56),
      const SizedBox(height: 12),
      Text(
        pending ? 'Waiting for approval' : 'Not linked yet',
        key: const Key('family-not-linked'),
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.titleLarge,
      ),
      const SizedBox(height: 8),
      Text(
        pending
            ? 'Your request was sent. You will see their health here once they approve it.'
            : 'Ask your family member for the link code in their Harvey app (Settings → '
                  'Family), then enter it here.',
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 16),
      if (!pending)
        FilledButton.icon(
          key: const Key('family-go-link'),
          onPressed: () => context.go('/family/link'),
          icon: const Icon(Icons.key),
          label: const Text('Enter link code'),
        ),
    ],
  );
}

class _Linked extends ConsumerWidget {
  const _Linked({required this.patientId});

  final String patientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final now = ref.watch(nowProvider)();
    final person = ref.watch(linkedPersonProvider(patientId)).value;
    final readings = ref.watch(_readingsProvider(patientId)).value ?? const <VitalReading>[];
    final risk = ref.watch(_riskProvider(patientId)).value;
    final alert = activeAlert(ref.watch(myEmergencyAlertsProvider).value ?? const [], now);
    final today = toMyt(now);
    bool sameDay(DateTime t, DateTime d) {
      final l = toMyt(t);
      return l.year == d.year && l.month == d.month && l.day == d.day;
    }

    final latest = readings.firstOrNull;
    final latestToday = latest != null && sameDay(latest.timestamp, today) ? latest : null;
    final yesterday = today.subtract(const Duration(days: 1));
    final prev = readings.where((r) => sameDay(r.timestamp, yesterday)).firstOrNull;
    final hr = readings.where((r) => r.heartRate != null).firstOrNull;
    final level = risk?.overallLevel;
    final week = readings
        .where((r) => now.difference(r.timestamp).inDays < 7)
        .toList()
        .reversed
        .toList();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // D-79: the same gradient header as the patient app.
        Container(
          key: const Key('family-header'),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: LinearGradient(
              colors: [
                theme.colorScheme.primary,
                Color.lerp(theme.colorScheme.primary, Colors.indigo, 0.45)!,
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: Colors.white,
                foregroundColor: theme.colorScheme.primary,
                child: Text(
                  (person?.name ?? '?').characters.first.toUpperCase(),
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(greetingFor(now), style: const TextStyle(color: Colors.white70)),
                    Text(
                      person?.name ?? '…',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Text(
                      "You're following them · read-only",
                      style: TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (alert != null)
          Card(
            key: const Key('family-alert-banner'),
            color: Colors.red.shade700,
            child: ListTile(
              leading: const Icon(Icons.warning_amber, color: Colors.white),
              title: Text(
                'Emergency: ${alert.title}',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
              subtitle: Text(
                '${dateLabel(alert.sentAt)}, ${timeLabel(alert.sentAt)} · tap to see where they are',
                style: const TextStyle(color: Colors.white),
              ),
              trailing: const Icon(Icons.chevron_right, color: Colors.white),
              onTap: () => context.go('/family/alert/${alert.id}'),
            ),
          ),
        // D-80: where they are (last known location).
        _FamilyMapCard(patientId: patientId, name: person?.name),
        _Tinted(
          key: const Key('family-status'),
          color: level == null ? theme.colorScheme.outline : riskColor(level),
          child: ListTile(
            title: Text('CURRENT STATUS', style: theme.textTheme.labelLarge),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.circle,
                      size: 10,
                      color: level == null ? Colors.grey : riskColor(level),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      level == null ? 'Not assessed yet' : riskLabel(level),
                      style: theme.textTheme.titleMedium,
                    ),
                  ],
                ),
                Text(switch (level) {
                  null => 'A risk assessment appears after three readings.',
                  RiskLevel.low => 'Readings look steady.',
                  RiskLevel.moderate => 'Elevated blood pressure detected recently.',
                  RiskLevel.high => 'High risk. They may need to see their doctor soon.',
                  RiskLevel.critical => 'Critical risk. Please check on them now.',
                }),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text("Today's vitals", style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Builder(
          builder: (context) {
            final r = latestToday ?? latest;
            final cat = r == null ? null : BpClassifier.classify(r.systolic, r.diastolic);
            final color = cat == null ? theme.colorScheme.outline : BpClassifier.color(cat);
            return _Tinted(
              key: const Key('family-bp'),
              color: color,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.favorite, color: color),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'BLOOD PRESSURE',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (latestToday != null) Text(timeLabel(latestToday.timestamp)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    if (latestToday == null)
                      Text(
                        'No reading today${latest == null ? '' : ' (last: ${latest.systolic}/${latest.diastolic}, ${dateLabel(latest.timestamp)})'}',
                      )
                    else ...[
                      Text(
                        '${latestToday.systolic}/${latestToday.diastolic} mmHg',
                        style: theme.textTheme.headlineSmall?.copyWith(
                          color: color,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        [
                          BpClassifier.label(cat!),
                          if (prev != null)
                            '${latestToday.systolic - prev.systolic >= 0 ? '+' : ''}'
                                '${latestToday.systolic - prev.systolic} from yesterday',
                        ].join(' · '),
                      ),
                    ],
                    if (cat == BpCategory.crisis)
                      Container(
                        key: const Key('family-crisis'),
                        margin: const EdgeInsets.only(top: 10),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Text(
                          'Crisis range. Check on them now; call 999 if they have chest pain, '
                          'breathlessness, weakness or confusion.',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 8),
        _Tinted(
          key: const Key('family-hr'),
          color: Colors.pink.shade400,
          child: ListTile(
            leading: Icon(Icons.monitor_heart_outlined, color: Colors.pink.shade400),
            title: const Text('HEART RATE'),
            subtitle: Text(
              hr == null ? 'No heart rate recorded' : '${hr.heartRate} BPM (camera estimate)',
            ),
            trailing: hr == null ? null : Text(timeLabel(hr.timestamp)),
          ),
        ),
        const SizedBox(height: 12),
        Text('7-day trend', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Card(
          key: const Key('family-trend'),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: week.length < 2
                ? const Text('Not enough readings this week to show a trend.')
                : SizedBox(
                    height: 160,
                    child: LineChart(
                      LineChartData(
                        gridData: const FlGridData(drawVerticalLine: false),
                        borderData: FlBorderData(show: false),
                        titlesData: const FlTitlesData(
                          topTitles: AxisTitles(),
                          rightTitles: AxisTitles(),
                          bottomTitles: AxisTitles(),
                          leftTitles: AxisTitles(
                            sideTitles: SideTitles(showTitles: true, reservedSize: 32),
                          ),
                        ),
                        lineBarsData: [
                          LineChartBarData(
                            spots: [
                              for (final (i, r) in week.indexed)
                                FlSpot(i.toDouble(), r.systolic.toDouble()),
                            ],
                            color: theme.colorScheme.primary,
                            isCurved: true,
                          ),
                          LineChartBarData(
                            spots: [
                              for (final (i, r) in week.indexed)
                                FlSpot(i.toDouble(), r.diastolic.toDouble()),
                            ],
                            color: Colors.teal,
                            isCurved: true,
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Read-only view. Only your family member and their doctor can change their records.',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// D-79: a softly tinted card with a coloured left edge (as on the patient Home).
class _Tinted extends StatelessWidget {
  const _Tinted({super.key, required this.color, required this.child});
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Material(
      color: Color.alphaBlend(
        color.withValues(alpha: 0.08),
        Theme.of(context).colorScheme.surfaceContainerLow,
      ),
      elevation: 1,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: color, width: 5)),
        ),
        child: child,
      ),
    ),
  );
}

/// D-80: the linked patient's last known location on a map, with how old it is.
class _FamilyMapCard extends ConsumerWidget {
  const _FamilyMapCard({required this.patientId, this.name});

  final String patientId;
  final String? name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final loc = ref.watch(patientLocationProvider(patientId));
    final now = ref.watch(nowProvider)();
    final who = name ?? 'They';
    Widget body;
    String? note;
    final l = loc.value;
    if (loc.isLoading && l == null) {
      body = const SizedBox(height: 60, child: Center(child: CircularProgressIndicator()));
    } else if (l == null || !l.sharing || !l.hasPoint) {
      body = ListTile(
        key: const Key('family-map-empty'),
        leading: const Icon(Icons.location_off_outlined),
        title: Text(
          l != null && !l.sharing ? '$who turned off location sharing.' : 'No location yet.',
        ),
        subtitle: Text(
          l != null && !l.sharing
              ? 'They can switch it on in Harvey Settings.'
              : 'It appears after $who opens Harvey with location allowed.',
        ),
      );
    } else {
      final stale = l.updatedAt != null && now.difference(l.updatedAt!) > const Duration(hours: 2);
      note = l.updatedAt == null ? 'Updating…' : 'Updated ${agoText(l.updatedAt!, now)}';
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              key: const Key('family-map'),
              height: 220,
              child: ref.read(mapBuilderProvider)(l.lat!, l.lng!, name ?? 'Patient'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Icon(
                  stale ? Icons.history : Icons.my_location,
                  size: 18,
                  color: stale ? Colors.orange.shade700 : Colors.green.shade600,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    stale ? '$note · may have moved since' : note,
                    key: const Key('family-map-updated'),
                  ),
                ),
                TextButton.icon(
                  key: const Key('family-map-open'),
                  onPressed: () => ref.read(openUrlProvider)(directionsUrl(l.lat!, l.lng!)),
                  icon: const Icon(Icons.directions_outlined),
                  label: const Text('Directions'),
                ),
              ],
            ),
          ),
        ],
      );
    }
    return Card(
      key: const Key('family-location'),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.place_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('Where $who is', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 8),
            body,
          ],
        ),
      ),
    );
  }
}
