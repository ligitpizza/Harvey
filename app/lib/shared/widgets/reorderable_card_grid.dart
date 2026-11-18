import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fill_grid.dart';

/// D-115: dashboard cards the user can drag into the order they prefer. The order is
/// kept on this device per user ([storageKey]); a card added later appears at the end,
/// and "Reset layout" restores the default order.
///
/// Each card is identified by its `ValueKey<String>` or, failing that, its type.
class ReorderableCardGrid extends StatefulWidget {
  const ReorderableCardGrid({
    super.key,
    required this.storageKey,
    required this.children,
    this.minItemWidth = 380,
    this.spacing = 16,
  });

  final String storageKey;
  final List<Widget> children;
  final double minItemWidth;
  final double spacing;

  static String idOf(Widget w) {
    final k = w.key;
    return k is ValueKey<String> ? k.value : '${w.runtimeType}';
  }

  /// [saved] first (those still present), then any new cards in their default order.
  static List<String> arrange(List<String> defaults, List<String>? saved) => [
    for (final id in saved ?? const <String>[])
      if (defaults.contains(id)) id,
    for (final id in defaults)
      if (!(saved ?? const <String>[]).contains(id)) id,
  ];

  /// [from] dropped on [to]: it takes [to]'s place and the rest shift along.
  static List<String> move(List<String> order, String from, String to) {
    final out = [...order]..remove(from);
    out.insert(out.indexOf(to) + (order.indexOf(from) < order.indexOf(to) ? 1 : 0), from);
    return out;
  }

  @override
  State<ReorderableCardGrid> createState() => _ReorderableCardGridState();
}

class _ReorderableCardGridState extends State<ReorderableCardGrid> {
  List<String>? _saved;
  String? _dragging;

  String get _key => 'dashboard-order:${widget.storageKey}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final saved = (await SharedPreferences.getInstance()).getStringList(_key);
      if (mounted && saved != null) setState(() => _saved = saved);
    } catch (_) {
      // No storage (private window): the default order is used.
    }
  }

  Future<void> _store(List<String>? order) async {
    setState(() => _saved = order);
    try {
      final prefs = await SharedPreferences.getInstance();
      order == null ? await prefs.remove(_key) : await prefs.setStringList(_key, order);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final byId = {for (final w in widget.children) ReorderableCardGrid.idOf(w): w};
    final defaults = byId.keys.toList();
    final order = ReorderableCardGrid.arrange(defaults, _saved);
    final custom = _saved != null && order.join() != defaults.join();
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.open_with, size: 16, color: theme.colorScheme.outline),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Drag a card onto another to rearrange your dashboard.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
              ),
            ),
            if (custom)
              TextButton.icon(
                key: const Key('dash-reset-layout'),
                onPressed: () => _store(null),
                icon: const Icon(Icons.restart_alt, size: 18),
                label: const Text('Reset layout'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        FillGrid(
          minItemWidth: widget.minItemWidth,
          spacing: widget.spacing,
          children: [for (final id in order) _slot(id, byId[id]!, order)],
        ),
      ],
    );
  }

  Widget _slot(String id, Widget card, List<String> order) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, box) => DragTarget<String>(
        onWillAcceptWithDetails: (d) => d.data != id,
        onAcceptWithDetails: (d) => _store(ReorderableCardGrid.move(order, d.data, id)),
        builder: (context, candidates, _) => Draggable<String>(
          key: Key('dash-drag-$id'),
          data: id,
          onDragStarted: () => setState(() => _dragging = id),
          onDragEnd: (_) => setState(() => _dragging = null),
          feedback: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              width: box.maxWidth,
              height: 72,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: scheme.primary, width: 2),
              ),
              child: Icon(Icons.open_with, color: scheme.primary),
            ),
          ),
          child: MouseRegion(
            cursor: SystemMouseCursors.grab,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              foregroundDecoration: candidates.isNotEmpty
                  ? BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: scheme.primary, width: 2),
                    )
                  : null,
              child: Opacity(opacity: _dragging == id ? 0.35 : 1, child: card),
            ),
          ),
        ),
      ),
    );
  }
}
