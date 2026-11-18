import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/enums.dart';
import '../../../core/utils/bp_classifier.dart';
import '../../../core/utils/risk_style.dart';
import '../../../shared/models/health_models.dart';
import '../../vitals/presentation/reading_detail_page.dart';
import '../domain/trend_logic.dart';
import 'bp_trend_chart.dart';
import 'risk_trend_card.dart' show complicationNames;

/// D-110: Health Trends extras. Heart rate on its own chart (PPG is an estimate), how the
/// period's readings split across BP categories, the readings themselves (tap for
/// details), and each condition's current risk with what raises it (D-40).

/// Readings in [range] (newest first) for the extras below.
List<VitalReading> readingsIn(List<VitalReading> all, TrendRange range, DateTime now) {
  final from = range.startFrom(now);
  return [
    for (final r in all)
      if (!r.timestamp.isBefore(from)) r,
  ];
}

class HeartRateCard extends StatelessWidget {
  const HeartRateCard({super.key, required this.readings, required this.range, required this.now});

  final List<VitalReading> readings;
  final TrendRange range;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final hr = [
      for (final r in readings.reversed)
        if (r.heartRate != null) r,
    ];
    final values = hr.map((r) => r.heartRate!).toList();
    return Card(
      key: const Key('trends-heart-rate'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Heart rate trend', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            if (hr.isEmpty)
              const Text(
                'No heart-rate readings in this period. Measure it with the camera when you '
                'log your blood pressure.',
                key: Key('trends-hr-empty'),
              )
            else ...[
              Text(
                'Average ${(values.reduce((a, b) => a + b) / values.length).round()} bpm · '
                'lowest ${values.reduce((a, b) => a < b ? a : b)} · '
                'highest ${values.reduce((a, b) => a > b ? a : b)}',
                key: const Key('trends-hr-summary'),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 140,
                child: LineChart(
                  LineChartData(
                    minX: range.startFrom(now).millisecondsSinceEpoch.toDouble(),
                    maxX: now.millisecondsSinceEpoch.toDouble(),
                    minY: ((values.reduce((a, b) => a < b ? a : b) - 10) / 10).floor() * 10.0,
                    maxY: ((values.reduce((a, b) => a > b ? a : b) + 10) / 10).ceil() * 10.0,
                    lineBarsData: [
                      LineChartBarData(
                        spots: [
                          for (final r in hr)
                            FlSpot(
                              r.timestamp.millisecondsSinceEpoch.toDouble(),
                              r.heartRate!.toDouble(),
                            ),
                        ],
                        color: BpTrendChart.heartRateColor,
                        barWidth: 3,
                        isCurved: hr.length > 2,
                        preventCurveOverShooting: true,
                        dotData: FlDotData(show: hr.length <= 31),
                      ),
                    ],
                    gridData: const FlGridData(drawVerticalLine: false, horizontalInterval: 10),
                    borderData: FlBorderData(show: false),
                    titlesData: FlTitlesData(
                      topTitles: const AxisTitles(),
                      rightTitles: const AxisTitles(),
                      bottomTitles: const AxisTitles(),
                      leftTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 36,
                          interval: 10,
                          minIncluded: false,
                          maxIncluded: false,
                          getTitlesWidget: (v, meta) => SideTitleWidget(
                            meta: meta,
                            child: Text('${v.toInt()}', style: const TextStyle(fontSize: 11)),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            const Text('Camera heart rate is an estimate.', style: TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class BpCategoryCard extends StatelessWidget {
  const BpCategoryCard({super.key, required this.readings});

  final List<VitalReading> readings;

  @override
  Widget build(BuildContext context) {
    final counts = {for (final c in BpCategory.values) c: 0};
    for (final r in readings) {
      final c = BpClassifier.classify(r.systolic, r.diastolic);
      counts[c] = counts[c]! + 1;
    }
    final total = readings.length;
    return Card(
      key: const Key('trends-categories'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Readings by category', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            if (total == 0)
              const Text('No readings in this period.')
            else ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  height: 18,
                  child: Row(
                    children: [
                      for (final e in counts.entries)
                        if (e.value > 0)
                          Expanded(
                            flex: e.value,
                            child: Container(color: BpClassifier.color(e.key)),
                          ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              for (final e in counts.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      CircleAvatar(radius: 5, backgroundColor: BpClassifier.color(e.key)),
                      const SizedBox(width: 8),
                      Expanded(child: Text(BpClassifier.label(e.key))),
                      Text(
                        '${e.value} (${(e.value * 100 / total).round()}%)',
                        key: Key('trends-cat-${e.key.value}'),
                        style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The period's readings, newest first; each opens its detail page.
class ReadingsListCard extends StatelessWidget {
  const ReadingsListCard({super.key, required this.readings, required this.patientId});

  final List<VitalReading> readings;
  final String patientId;

  static const shown = 10;

  @override
  Widget build(BuildContext context) => Card(
    key: const Key('trends-readings'),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('Readings', style: Theme.of(context).textTheme.titleMedium),
          ),
          if (readings.isEmpty)
            const Padding(padding: EdgeInsets.all(16), child: Text('No readings in this period.')),
          for (final r in readings.take(shown)) ReadingRow(reading: r),
          if (readings.length > shown)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                'Showing the latest $shown of ${readings.length}.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    ),
  );
}

/// One reading as a tappable row (trends and the doctor's patient vitals).
class ReadingRow extends StatelessWidget {
  const ReadingRow({super.key, required this.reading});

  final VitalReading reading;

  @override
  Widget build(BuildContext context) {
    final c = BpClassifier.classify(reading.systolic, reading.diastolic);
    return ListTile(
      key: Key('trend-reading-${reading.id}'),
      leading: CircleAvatar(radius: 6, backgroundColor: BpClassifier.color(c)),
      title: Text(
        '${reading.systolic}/${reading.diastolic} mmHg'
        '${reading.heartRate == null ? '' : ' · ${reading.heartRate} bpm'}',
      ),
      subtitle: Text('${BpClassifier.label(c)} · ${readingTime(reading.timestamp)}'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => openReading(context, reading),
    );
  }
}

/// Each condition's latest level and value, the change since the previous assessment
/// and what raised it (D-40 contributing factors, now shown to the patient too).
class RiskConditionCards extends StatelessWidget {
  const RiskConditionCards({super.key, required this.scores});

  /// Newest first.
  final List<RiskScore> scores;

  @override
  Widget build(BuildContext context) {
    if (scores.isEmpty) return const SizedBox.shrink();
    final latest = scores.first;
    final previous = scores.length > 1 ? scores[1] : null;
    return Column(
      key: const Key('trends-risk-conditions'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Text('Each condition', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        for (final c in Complication.values)
          if (latest.scores[c] case final s?)
            Card(
              key: Key('risk-condition-${c.value}'),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            complicationNames[c]!,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                        Chip(
                          visualDensity: VisualDensity.compact,
                          avatar: CircleAvatar(backgroundColor: riskColor(s.level), radius: 5),
                          label: Text('${riskLabel(s.level)} · ${riskPercent(s.value)}'),
                        ),
                      ],
                    ),
                    Text(
                      _change(s, previous?.scores[c]),
                      key: Key('risk-change-${c.value}'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (s.factors.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Raised by: ${s.factors.map(factorLabel).join(', ')}',
                        key: Key('risk-factors-${c.value}'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
      ],
    );
  }

  static String _change(ComplicationScore now, ComplicationScore? before) {
    if (before == null) return 'First assessment.';
    final diff = ((now.value - before.value) * 100).round();
    if (diff == 0) return 'No change since the last assessment.';
    return '${diff > 0 ? 'Up' : 'Down'} ${diff.abs()} points since the last assessment.';
  }
}
