import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/api_providers.dart';
import '../../../shared/services/api/api_client.dart';
import 'chart_kit.dart';

/// D-79: admins add their own charts to Hospital and Usage analytics. A chart is a measure,
/// a chart type and a period; definitions are saved on the admin's account.

class ChartDef {
  const ChartDef({
    required this.id,
    required this.title,
    required this.measure,
    required this.type,
    required this.days,
    required this.page,
  });

  final String id;
  final String title;
  final String measure;
  final String type; // bar | line | donut | stacked
  final int days;
  final String page; // hospital | usage

  factory ChartDef.fromJson(Map<String, dynamic> j) => ChartDef(
    id: '${j['id']}',
    title: '${j['title']}',
    measure: '${j['measure']}',
    type: '${j['type']}',
    days: (j['days'] as num?)?.toInt() ?? 30,
    page: '${j['page']}',
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'measure': measure,
    'type': type,
    'days': days,
    'page': page,
  };
}

class Measure {
  const Measure(this.key, this.label, this.kind, this.page);
  final String key;
  final String label;
  final String kind; // time | category
  final String page;
}

class ChartSeries {
  const ChartSeries({required this.kind, required this.labels, required this.series});
  final String kind;
  final List<String> labels;
  final Map<String, List<num>> series;

  factory ChartSeries.fromJson(Map<String, dynamic> j) => ChartSeries(
    kind: '${j['kind']}',
    labels: [for (final l in j['labels'] as List<dynamic>? ?? const []) '$l'],
    series: {
      for (final e in (j['series'] as Map<String, dynamic>? ?? const {}).entries)
        e.key: [for (final v in e.value as List<dynamic>) (v as num?) ?? 0],
    },
  );
}

final chartMeasuresProvider = FutureProvider.autoDispose<List<Measure>>((ref) async {
  final j = await ref.watch(apiClientProvider).chartMeasures();
  return [
    for (final m in j['measures'] as List<dynamic>? ?? const [])
      Measure('${m['key']}', '${m['label']}', '${m['kind']}', '${m['page']}'),
  ];
}, retry: (_, _) => null);

final myChartsProvider = FutureProvider.autoDispose<List<ChartDef>>((ref) async {
  final j = await ref.watch(apiClientProvider).myCharts();
  return [
    for (final c in j['charts'] as List<dynamic>? ?? const [])
      ChartDef.fromJson(Map<String, dynamic>.from(c as Map)),
  ];
}, retry: (_, _) => null);

final chartSeriesProvider = FutureProvider.autoDispose.family<ChartSeries, (String, int)>((
  ref,
  k,
) async {
  return ChartSeries.fromJson(await ref.watch(apiClientProvider).chartSeries(k.$1, k.$2));
}, retry: (_, _) => null);

const chartTypeNames = {'bar': 'Bar', 'line': 'Line', 'donut': 'Donut', 'stacked': 'Stacked bar'};

const _palette = [
  Color(0xFF1E88E5),
  Color(0xFF00897B),
  Color(0xFFF4511E),
  Color(0xFF8E24AA),
  Color(0xFFFDD835),
  Color(0xFF6D4C41),
  Color(0xFF546E7A),
  Color(0xFFD81B60),
];

Color _categoryColor(String label, int i) => switch (label) {
  'low' => Colors.green.shade600,
  'moderate' => Colors.amber.shade700,
  'high' => Colors.orange.shade800,
  'critical' => Colors.red.shade700,
  _ => _palette[i % _palette.length],
};

/// The custom charts block on an analytics page.
class CustomChartsSection extends ConsumerWidget {
  const CustomChartsSection({super.key, required this.page});
  final String page;

  Future<void> _save(WidgetRef ref, BuildContext context, List<ChartDef> all) async {
    try {
      await ref.read(apiClientProvider).saveCharts([for (final c in all) c.toJson()]);
      ref.invalidate(myChartsProvider);
    } on ApiException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    List<ChartDef> all, [
    ChartDef? existing,
  ]) async {
    final def = await showDialog<ChartDef>(
      context: context,
      builder: (_) => _ChartDialog(page: page, existing: existing),
    );
    if (def == null || !context.mounted) return;
    final next = existing == null
        ? [...all, def]
        : [
            for (final c in all)
              if (c.id == existing.id) def else c,
          ];
    await _save(ref, context, next);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final charts = ref.watch(myChartsProvider);
    final all = charts.value ?? const <ChartDef>[];
    final mine = [
      for (final c in all)
        if (c.page == page) c,
    ];
    return Column(
      key: Key('custom-charts-$page'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(child: Text('My charts', style: Theme.of(context).textTheme.titleLarge)),
            FilledButton.tonalIcon(
              key: const Key('add-chart'),
              onPressed: charts.isLoading ? null : () => _edit(context, ref, all),
              icon: const Icon(Icons.add_chart),
              label: const Text('Add chart'),
            ),
          ],
        ),
        const Text('Build your own charts. They are saved to your account.'),
        const SizedBox(height: 12),
        if (charts.hasError)
          TextButton(
            onPressed: () => ref.invalidate(myChartsProvider),
            child: const Text('Could not load your charts. Retry'),
          )
        else if (mine.isEmpty && !charts.isLoading)
          const Padding(
            key: Key('no-custom-charts'),
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('No custom charts yet. Use Add chart to create one.'),
          ),
        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            for (final c in mine)
              _ChartCard(
                key: Key('chart-${c.id}'),
                def: c,
                onEdit: () => _edit(context, ref, all, c),
                onDelete: () => _save(ref, context, [
                  for (final x in all)
                    if (x.id != c.id) x,
                ]),
              ),
          ],
        ),
      ],
    );
  }
}

class _ChartCard extends ConsumerWidget {
  const _ChartCard({super.key, required this.def, required this.onEdit, required this.onDelete});

  final ChartDef def;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(chartSeriesProvider((def.measure, def.days)));
    final theme = Theme.of(context);
    return SizedBox(
      width: 520,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 8, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(def.title, style: theme.textTheme.titleMedium),
                        Text(
                          '${chartTypeNames[def.type]} · last ${def.days} days',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    key: Key('chart-menu-${def.id}'),
                    onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('Edit')),
                      PopupMenuItem(value: 'delete', child: Text('Remove')),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 240,
                child: data.when(
                  loading: () => const Center(child: CircularProgressIndicator()),
                  error: (_, _) => Center(
                    child: TextButton(
                      onPressed: () => ref.invalidate(chartSeriesProvider((def.measure, def.days))),
                      child: const Text('Could not load. Retry'),
                    ),
                  ),
                  data: (s) => ChartView(type: def.type, data: s),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Draws one series in the chosen type.
class ChartView extends StatelessWidget {
  const ChartView({super.key, required this.type, required this.data});
  final String type;
  final ChartSeries data;

  List<String> get _xLabels => [
    for (final l in data.labels)
      data.kind == 'time' && l.length >= 10
          ? '${int.parse(l.substring(8, 10))}/'
                '${int.parse(l.substring(5, 7))}'
          : l,
  ];

  @override
  Widget build(BuildContext context) {
    final names = data.series.keys.toList();
    final total = data.series.values.expand((v) => v).fold<num>(0, (a, b) => a + b);
    if (data.labels.isEmpty || total == 0) {
      return const Center(child: Text('No data in this period.'));
    }
    final labels = _xLabels;
    final step = (labels.length / 8).ceil().clamp(1, 30);
    FlTitlesData titles() => FlTitlesData(
      topTitles: const AxisTitles(),
      rightTitles: const AxisTitles(),
      leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 34)),
      bottomTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: true,
          reservedSize: 28,
          getTitlesWidget: (v, _) {
            final i = v.toInt();
            if (i < 0 || i >= labels.length || i % step != 0) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(labels[i], style: const TextStyle(fontSize: 10)),
            );
          },
        ),
      ),
    );
    Color colorOf(int k) =>
        names.length == 1 && data.kind == 'category' ? _palette[0] : _palette[k % _palette.length];
    final legend = names.length > 1
        ? Wrap(
            spacing: 10,
            children: [
              for (final (k, n) in names.indexed)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.square, size: 10, color: colorOf(k)),
                    const SizedBox(width: 4),
                    Text(n, style: const TextStyle(fontSize: 12)),
                  ],
                ),
            ],
          )
        : null;
    final values = [
      for (var i = 0; i < labels.length; i++) [for (final n in names) data.series[n]![i]],
    ];

    Widget chart;
    switch (type) {
      case 'donut':
        // One slice per category (or per series, summed over the period).
        final slices = data.kind == 'category' || names.length == 1
            ? [
                for (var i = 0; i < labels.length; i++)
                  (
                    labels[i],
                    values[i].fold<num>(0, (a, b) => a + b),
                    _categoryColor(data.labels[i], i),
                  ),
              ]
            : [
                for (final (k, n) in names.indexed)
                  (n, data.series[n]!.fold<num>(0, (a, b) => a + b), colorOf(k)),
              ];
        chart = Row(
          children: [
            Expanded(
              child: HoverDonut(
                slices: slices,
                center: Text('$total', style: Theme.of(context).textTheme.headlineSmall),
              ),
            ),
            SizedBox(
              width: 150,
              child: ListView(
                children: [
                  for (final (l, v, c) in slices)
                    if (v > 0)
                      Row(
                        children: [
                          Icon(Icons.circle, size: 10, color: c),
                          const SizedBox(width: 6),
                          Expanded(child: Text(l, overflow: TextOverflow.ellipsis)),
                          Text('$v'),
                        ],
                      ),
                ],
              ),
            ),
          ],
        );
      case 'line':
        final maxY = values.expand((v) => v).fold<num>(0, math.max).toDouble();
        chart = LineChart(
          LineChartData(
            minY: 0,
            maxY: maxY == 0 ? 1 : maxY * 1.15,
            titlesData: titles(),
            gridData: const FlGridData(drawVerticalLine: false),
            borderData: FlBorderData(show: false),
            lineTouchData: lineTouch(labels),
            lineBarsData: [
              for (final (k, n) in names.indexed)
                LineChartBarData(
                  spots: [
                    for (var i = 0; i < labels.length; i++)
                      FlSpot(i.toDouble(), data.series[n]![i].toDouble()),
                  ],
                  color: colorOf(k),
                  barWidth: 3,
                  dotData: FlDotData(show: labels.length <= 31),
                ),
            ],
          ),
        );
      default: // bar | stacked
        final stacked = type == 'stacked' || names.length == 1;
        chart = BarChart(
          BarChartData(
            titlesData: titles(),
            gridData: const FlGridData(drawVerticalLine: false),
            borderData: FlBorderData(show: false),
            barTouchData: stackedBarTouch(groupLabels: labels, seriesNames: names, values: values),
            barGroups: [
              for (var i = 0; i < labels.length; i++)
                BarChartGroupData(
                  x: i,
                  barsSpace: 2,
                  barRods: stacked
                      ? [
                          () {
                            var y = 0.0;
                            final items = <BarChartRodStackItem>[];
                            for (final (k, _) in names.indexed) {
                              final v = values[i][k].toDouble();
                              final c = data.kind == 'category' && names.length == 1
                                  ? _categoryColor(data.labels[i], i)
                                  : colorOf(k);
                              items.add(BarChartRodStackItem(y, y + v, c));
                              y += v;
                            }
                            return BarChartRodData(
                              toY: y,
                              width: labels.length <= 10 ? 22 : 6,
                              rodStackItems: items,
                              color: Colors.blueGrey,
                              borderRadius: BorderRadius.zero,
                            );
                          }(),
                        ]
                      : [
                          for (final (k, _) in names.indexed)
                            BarChartRodData(
                              toY: values[i][k].toDouble(),
                              width: labels.length <= 10 ? 10 : 3,
                              color: colorOf(k),
                              borderRadius: BorderRadius.zero,
                            ),
                        ],
                ),
            ],
          ),
        );
    }
    return Column(
      children: [
        Expanded(child: chart),
        if (legend != null) ...[const SizedBox(height: 8), legend],
      ],
    );
  }
}

class _ChartDialog extends ConsumerStatefulWidget {
  const _ChartDialog({required this.page, this.existing});
  final String page;
  final ChartDef? existing;

  @override
  ConsumerState<_ChartDialog> createState() => _ChartDialogState();
}

class _ChartDialogState extends ConsumerState<_ChartDialog> {
  late String? _measure = widget.existing?.measure;
  late String _type = widget.existing?.type ?? 'bar';
  late int _days = widget.existing?.days ?? 30;
  late final _title = TextEditingController(text: widget.existing?.title ?? '');

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final measures = ref.watch(chartMeasuresProvider);
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add chart' : 'Edit chart'),
      content: SizedBox(
        width: 460,
        child: measures.when(
          loading: () => const LinearProgressIndicator(),
          error: (_, _) => const Text('Could not load the list of measures.'),
          data: (all) {
            // This page's measures first, then the rest.
            final ordered = [
              ...all.where((m) => m.page == widget.page),
              ...all.where((m) => m.page != widget.page),
            ];
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButtonFormField<String>(
                  key: const Key('chart-measure'),
                  initialValue: _measure,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'What to show'),
                  items: [
                    for (final m in ordered) DropdownMenuItem(value: m.key, child: Text(m.label)),
                  ],
                  onChanged: (v) => setState(() {
                    _measure = v;
                    final m = all.firstWhere((x) => x.key == v);
                    if (_title.text.isEmpty) _title.text = m.label;
                    if (m.kind == 'category' && _type == 'line') _type = 'bar';
                  }),
                ),
                const SizedBox(height: 12),
                const Text('Chart type'),
                const SizedBox(height: 4),
                SegmentedButton<String>(
                  key: const Key('chart-type'),
                  segments: [
                    for (final e in chartTypeNames.entries)
                      ButtonSegment(value: e.key, label: Text(e.value)),
                  ],
                  selected: {_type},
                  onSelectionChanged: (s) => setState(() => _type = s.first),
                ),
                const SizedBox(height: 12),
                const Text('Period'),
                const SizedBox(height: 4),
                SegmentedButton<int>(
                  key: const Key('chart-days'),
                  segments: const [
                    ButtonSegment(value: 7, label: Text('7 days')),
                    ButtonSegment(value: 30, label: Text('30 days')),
                    ButtonSegment(value: 90, label: Text('90 days')),
                  ],
                  selected: {_days},
                  onSelectionChanged: (s) => setState(() => _days = s.first),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('chart-title'),
                  controller: _title,
                  maxLength: 80,
                  decoration: const InputDecoration(labelText: 'Title'),
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const Key('chart-save'),
          onPressed: _measure == null
              ? null
              : () => Navigator.pop(
                  context,
                  ChartDef(
                    id: widget.existing?.id ?? 'c${DateTime.now().millisecondsSinceEpoch}',
                    title: _title.text.trim().isEmpty ? _measure! : _title.text.trim(),
                    measure: _measure!,
                    type: _type,
                    days: _days,
                    page: widget.page,
                  ),
                ),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
