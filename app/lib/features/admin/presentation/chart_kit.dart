import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

/// D-79: shared chart pieces for the admin analytics pages. Every chart shows its values
/// when the pointer hovers (web) or a finger touches it.

const _tooltipBg = Color(0xEE263238);
const _tooltipText = TextStyle(color: Colors.white, fontSize: 12, height: 1.4);

/// Stacked (or single) bars: "Oct / High: 1 / Critical: 2 / Total: 3".
/// [values][group][series] in the same order as [seriesNames].
BarTouchData stackedBarTouch({
  required List<String> groupLabels,
  required List<String> seriesNames,
  required List<List<num>> values,
}) => BarTouchData(
  enabled: true,
  handleBuiltInTouches: true,
  touchTooltipData: BarTouchTooltipData(
    getTooltipColor: (_) => _tooltipBg,
    fitInsideHorizontally: true,
    fitInsideVertically: true,
    getTooltipItem: (group, groupIndex, rod, rodIndex) {
      final i = group.x;
      if (i < 0 || i >= values.length) return null;
      final row = values[i];
      final lines = <String>[
        for (final (k, name) in seriesNames.indexed)
          if (k < row.length && (row[k] != 0 || seriesNames.length == 1)) '$name: ${_fmt(row[k])}',
      ];
      if (seriesNames.length > 1) {
        lines.add('Total: ${_fmt(row.fold<num>(0, (a, b) => a + b))}');
      }
      return BarTooltipItem(
        '${i < groupLabels.length ? groupLabels[i] : ''}\n',
        _tooltipText.copyWith(fontWeight: FontWeight.bold),
        children: [TextSpan(text: lines.join('\n'), style: _tooltipText)],
      );
    },
  ),
);

/// Line charts: "12/10: 83%".
LineTouchData lineTouch(List<String> xLabels, {String unit = ''}) => LineTouchData(
  enabled: true,
  handleBuiltInTouches: true,
  touchTooltipData: LineTouchTooltipData(
    getTooltipColor: (_) => _tooltipBg,
    fitInsideHorizontally: true,
    fitInsideVertically: true,
    getTooltipItems: (spots) => [
      for (final s in spots)
        LineTooltipItem(
          '${s.x.toInt() < xLabels.length ? '${xLabels[s.x.toInt()]}: ' : ''}'
          '${_fmt(s.y)}$unit',
          _tooltipText.copyWith(color: s.bar.color ?? Colors.white),
        ),
    ],
  ),
);

String _fmt(num v) => v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);

/// A donut that shows the hovered slice (label, value, share) in its centre.
class HoverDonut extends StatefulWidget {
  const HoverDonut({
    super.key,
    required this.slices,
    required this.center,
    this.centerSpace = 55,
    this.radius = 32,
  });

  /// (label, value, colour)
  final List<(String, num, Color)> slices;

  /// Shown in the middle while nothing is hovered.
  final Widget center;
  final double centerSpace;
  final double radius;

  @override
  State<HoverDonut> createState() => _HoverDonutState();
}

class _HoverDonutState extends State<HoverDonut> {
  int? _touched;

  @override
  Widget build(BuildContext context) {
    final shown = [
      for (final s in widget.slices)
        if (s.$2 > 0) s,
    ];
    final total = shown.fold<num>(0, (a, s) => a + s.$2);
    final hovered = _touched != null && _touched! < shown.length ? shown[_touched!] : null;
    return Stack(
      alignment: Alignment.center,
      children: [
        PieChart(
          PieChartData(
            centerSpaceRadius: widget.centerSpace,
            sectionsSpace: 2,
            pieTouchData: PieTouchData(
              enabled: true,
              touchCallback: (event, response) => setState(() {
                _touched = event.isInterestedForInteractions
                    ? response?.touchedSection?.touchedSectionIndex
                    : null;
                if (_touched != null && _touched! < 0) _touched = null;
              }),
            ),
            sections: total == 0
                ? [PieChartSectionData(value: 1, color: Colors.grey.shade300, title: '')]
                : [
                    for (final (i, (_, v, c)) in shown.indexed)
                      PieChartSectionData(
                        value: v.toDouble(),
                        color: c,
                        title: '',
                        radius: i == _touched ? widget.radius + 8 : widget.radius,
                      ),
                  ],
          ),
        ),
        if (hovered == null)
          widget.center
        else
          Column(
            key: const Key('donut-hover'),
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _fmt(hovered.$2),
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: hovered.$3),
              ),
              Text(hovered.$1, textAlign: TextAlign.center),
              Text(
                '${(hovered.$2 / total * 100).round()}%',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
      ],
    );
  }
}

/// Same size, same look KPI tile (analytics, audit logs, system health).
class KpiTile extends StatelessWidget {
  const KpiTile({
    super.key,
    required this.label,
    required this.value,
    required this.color,
    this.note,
    this.icon,
    this.width = 230,
  });

  final String label;
  final String value;
  final Color color;
  final String? note;
  final IconData? icon;
  final double width;

  static const height = 118.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: width,
      height: height,
      child: Card(
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: color, width: 1.5),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 18, color: color),
                    const SizedBox(width: 6),
                  ],
                  Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
                ],
              ),
              Text(
                value,
                style: theme.textTheme.headlineMedium?.copyWith(color: color),
                maxLines: 1,
              ),
              if (note != null)
                Text(
                  note!,
                  style: theme.textTheme.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
