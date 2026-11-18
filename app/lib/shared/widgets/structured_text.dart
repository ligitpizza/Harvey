import 'package:flutter/material.dart';

/// Clinical text (notes, care plans) laid out for reading: "Heading: value" lines show the
/// heading in bold with the value beside it, an empty template heading shows a faint dash,
/// and any other line is plain text. Selectable, so staff can copy from it.
class StructuredText extends StatelessWidget {
  const StructuredText(this.text, {super.key, this.maxLines});

  final String text;

  /// Shows only the first lines (a preview); null shows everything.
  final int? maxLines;

  static final _heading = RegExp(r'^\s*([^:\n]{2,60}):\s*(.*)$');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    var lines = text.trim().split('\n');
    if (maxLines != null && lines.length > maxLines!) lines = lines.take(maxLines!).toList();
    final rows = <Widget>[];
    for (final raw in lines) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) {
        rows.add(const SizedBox(height: 6));
        continue;
      }
      final m = _heading.firstMatch(line);
      if (m == null) {
        rows.add(Text(line, style: theme.textTheme.bodyMedium));
        continue;
      }
      final value = m.group(2)!.trim();
      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '${m.group(1)!.trim()}: ',
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                TextSpan(
                  text: value.isEmpty ? '—' : value,
                  style: value.isEmpty
                      ? theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline)
                      : theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ),
      );
    }
    return SelectionArea(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows),
    );
  }
}
