import 'package:flutter/material.dart';

import '../../../core/constants/enums.dart';
import '../../../core/utils/bp_classifier.dart';

/// D-121: shared pieces of the Reading Saved and Reading details pages.

const heartColor = Color(0xFFE0457B);

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

/// D-121: which number put the reading in its category. The AHA chart uses the higher
/// category of the two numbers, so 120/80 is Stage 1 because of the diastolic 80.
/// Null when both numbers agree (nothing surprising to explain).
String? categoryReason(int systolic, int diastolic) {
  final c = BpClassifier.classify(systolic, diastolic);
  final bySys = BpClassifier.classify(systolic, 0);
  final byDia = diastolic >= 80 ? BpClassifier.classify(0, diastolic) : BpCategory.normal;
  if (c.index < BpCategory.stage1.index || bySys == byDia) return null;
  final label = BpClassifier.label(c);
  if (byDia == c) {
    return 'Your bottom number ($diastolic) is in the $label range, so the reading counts '
        'as $label even though the top number ($systolic) is lower. The chart uses the '
        'higher of the two.';
  }
  return 'Your top number ($systolic) is in the $label range, so the reading counts as '
      '$label even though the bottom number ($diastolic) is lower. The chart uses the '
      'higher of the two.';
}

/// D-122: where the heart rate came from, or null for older readings that do not say.
String? heartRateSourceLabel(HeartRateSource? s) => switch (s) {
  HeartRateSource.camera => 'Camera estimate',
  HeartRateSource.manual => 'Entered by you',
  null => null,
};

/// The five AHA categories as a coloured scale with this reading's category marked.
class BpScaleBar extends StatelessWidget {
  const BpScaleBar({super.key, required this.category});

  final BpCategory category;

  static const _short = {
    BpCategory.normal: 'Normal',
    BpCategory.elevated: 'Elevated',
    BpCategory.stage1: 'Stage 1',
    BpCategory.stage2: 'Stage 2',
    BpCategory.crisis: 'Crisis',
  };

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.labelSmall;
    return Column(
      key: const Key('bp-scale'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            for (final c in BpCategory.values)
              Expanded(
                child: Container(
                  height: c == category ? 10 : 6,
                  margin: const EdgeInsets.symmetric(horizontal: 1.5),
                  decoration: BoxDecoration(
                    color: BpClassifier.color(c).withValues(alpha: c == category ? 1 : 0.3),
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            for (final c in BpCategory.values)
              Expanded(
                child: Text(
                  _short[c]!,
                  textAlign: TextAlign.center,
                  style: small?.copyWith(
                    fontWeight: c == category ? FontWeight.w700 : FontWeight.w400,
                    color: c == category
                        ? BpClassifier.color(c)
                        : small.color?.withValues(alpha: 0.6),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// A coloured "pill" with a dot, used for the BP category and the risk level.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(backgroundColor: color, radius: 4),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// One number in a small tile: systolic, diastolic or heart rate.
class VitalStatTile extends StatelessWidget {
  const VitalStatTile({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.unit,
    required this.color,
    this.footnote,
  });

  final IconData icon;
  final String label;
  final String value;
  final String unit;
  final Color color;
  final String? footnote;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.labelMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(value, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
          Text(unit, style: theme.textTheme.labelSmall),
          if (footnote != null) ...[
            const SizedBox(height: 2),
            Text(footnote!, style: theme.textTheme.labelSmall?.copyWith(color: color)),
          ],
        ],
      ),
    );
  }
}

/// Card heading with a tinted icon.
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.icon, required this.title, this.trailing});

  final IconData icon;
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: scheme.primaryContainer.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 18, color: scheme.primary),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        ?trailing,
      ],
    );
  }
}

/// Three stat tiles side by side: systolic, diastolic and heart rate.
class BpStatRow extends StatelessWidget {
  const BpStatRow({
    super.key,
    required this.systolic,
    required this.diastolic,
    required this.heartRate,
    this.source,
  });

  final int systolic;
  final int diastolic;
  final int? heartRate;
  final HeartRateSource? source;

  @override
  Widget build(BuildContext context) {
    final sysColor = BpClassifier.color(BpClassifier.classify(systolic, 0));
    final diaColor = BpClassifier.color(
      diastolic >= 80 ? BpClassifier.classify(0, diastolic) : BpCategory.normal,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: VitalStatTile(
            key: const Key('stat-systolic'),
            icon: Icons.arrow_upward_rounded,
            label: 'Systolic',
            value: '$systolic',
            unit: 'mmHg · top',
            color: sysColor,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: VitalStatTile(
            key: const Key('stat-diastolic'),
            icon: Icons.arrow_downward_rounded,
            label: 'Diastolic',
            value: '$diastolic',
            unit: 'mmHg · bottom',
            color: diaColor,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: VitalStatTile(
            key: const Key('stat-heart-rate'),
            icon: Icons.favorite_rounded,
            label: 'Heart rate',
            value: heartRate == null ? '—' : '$heartRate',
            unit: heartRate == null ? 'not measured' : 'bpm',
            color: heartColor,
            footnote: heartRate == null ? null : heartRateSourceLabel(source),
          ),
        ),
      ],
    );
  }
}

/// The white rounded panel each section of the reading pages sits in.
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }
}
