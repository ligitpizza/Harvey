import 'package:flutter/material.dart';
import 'structured_text.dart';

import '../models/health_models.dart';

/// D-41: every saved version of the care plan, newest first; the newest is the current one.
/// Used by the patient's dashboard card and the doctor's care plan editor.
class CarePlanHistoryList extends StatelessWidget {
  const CarePlanHistoryList({super.key, required this.versions, this.shrinkWrap = false});

  final List<CarePlanVersion> versions;
  final bool shrinkWrap;

  static String when(DateTime t) {
    const months = [
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
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '${t.day} ${months[t.month - 1]} ${t.year}, $h:${t.minute.toString().padLeft(2, '0')} '
        '${t.hour < 12 ? 'AM' : 'PM'}';
  }

  @override
  Widget build(BuildContext context) {
    if (versions.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(8),
        child: Text('No earlier versions yet.', key: Key('care-plan-history-empty')),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return ListView.builder(
      key: const Key('care-plan-history'),
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      itemCount: versions.length,
      itemBuilder: (context, i) {
        final current = i == 0;
        final last = i == versions.length - 1;
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Timeline rail: a dot per version joined by a line.
              SizedBox(
                width: 24,
                child: Column(
                  children: [
                    const SizedBox(height: 14),
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: current ? scheme.primary : scheme.surface,
                        border: Border.all(color: scheme.primary, width: 2),
                        shape: BoxShape.circle,
                      ),
                    ),
                    if (!last) Expanded(child: Container(width: 2, color: scheme.outlineVariant)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Card(
                  key: Key('care-plan-version-$i'),
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: current ? scheme.primary : scheme.outlineVariant),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: current
                      ? Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _header(context, versions[i].savedAt, current: true),
                              const SizedBox(height: 8),
                              StructuredText(versions[i].content),
                            ],
                          ),
                        )
                      : ExpansionTile(
                          shape: const Border(),
                          collapsedShape: const Border(),
                          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
                          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                          expandedCrossAxisAlignment: CrossAxisAlignment.start,
                          title: _header(context, versions[i].savedAt),
                          subtitle: Text(
                            versions[i].content.trim().split('\n').first,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          children: [StructuredText(versions[i].content)],
                        ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _header(BuildContext context, DateTime at, {bool current = false}) => Row(
    children: [
      Expanded(child: Text(when(at), style: Theme.of(context).textTheme.labelLarge)),
      if (current) const Chip(visualDensity: VisualDensity.compact, label: Text('Current')),
    ],
  );
}
