import 'package:flutter/material.dart';

/// D-80: a grid whose items stretch to use the full width. As many columns fit as
/// [minItemWidth] allows (never more than there are items), and every column shares the
/// leftover space, so a wide or zoomed-out page has no blank strip on the right.
///
/// [equalHeight] makes the items in a row the same height (for tiles; their content
/// must support intrinsic sizing, so not for cards with charts or LayoutBuilders).
class FillGrid extends StatelessWidget {
  const FillGrid({
    super.key,
    required this.children,
    required this.minItemWidth,
    this.spacing = 16,
    this.equalHeight = false,
  });

  final List<Widget> children;
  final double minItemWidth;
  final double spacing;
  final bool equalHeight;

  /// How many columns fit in [width].
  static int columnsFor(double width, double minItemWidth, double spacing, int count) {
    if (count == 0) return 1;
    final fit = ((width + spacing) / (minItemWidth + spacing)).floor();
    return fit.clamp(1, count);
  }

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, box) {
        final cols = columnsFor(box.maxWidth, minItemWidth, spacing, children.length);
        final rows = <Widget>[];
        for (var start = 0; start < children.length; start += cols) {
          final cells = <Widget>[];
          for (var i = 0; i < cols; i++) {
            if (i > 0) cells.add(SizedBox(width: spacing));
            final index = start + i;
            cells.add(
              Expanded(child: index < children.length ? children[index] : const SizedBox()),
            );
          }
          Widget row = Row(
            crossAxisAlignment: equalHeight ? CrossAxisAlignment.stretch : CrossAxisAlignment.start,
            children: cells,
          );
          if (equalHeight) row = IntrinsicHeight(child: row);
          if (rows.isNotEmpty) rows.add(SizedBox(height: spacing));
          rows.add(row);
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
      },
    );
  }
}
