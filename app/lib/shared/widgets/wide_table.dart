import 'package:flutter/material.dart';

/// D-114: a [DataTable] that fills its card. Columns given `IntrinsicColumnWidth(flex:)`
/// share the spare width, so a wide page has no blank strip on the right; a narrow page
/// scrolls the table sideways instead of squashing it.
class WideTable extends StatelessWidget {
  const WideTable({super.key, required this.table});

  final DataTable table;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: box.maxWidth),
        child: table,
      ),
    ),
  );
}

/// A rounded coloured label for table cells (status, class, form).
class TablePill extends StatelessWidget {
  const TablePill(this.text, {super.key, required this.color, this.icon});

  final String text;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[Icon(icon, size: 14, color: color), const SizedBox(width: 4)],
        Text(
          text,
          style: Theme.of(
            context,
          ).textTheme.labelMedium?.copyWith(color: color, fontWeight: FontWeight.w600),
        ),
      ],
    ),
  );
}

/// A small count tile above a table ("12 medicines", "2 low").
class TableSummaryChip extends StatelessWidget {
  const TableSummaryChip({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    this.selected = false,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => FilterChip(
    avatar: Icon(icon, size: 18, color: color),
    label: Text(label),
    selected: selected,
    showCheckmark: false,
    selectedColor: color.withValues(alpha: 0.16),
    onSelected: onTap == null ? null : (_) => onTap!(),
  );
}
