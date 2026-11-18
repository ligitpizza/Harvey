import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/order_models.dart';
import '../state/orders_providers.dart';
import '../../../shared/widgets/import_dialog.dart';
import 'pharmacy_shared.dart';
import '../../../shared/widgets/page_header.dart';
import '../../../shared/widgets/wide_table.dart';

/// D-70 Inventory tab (pharmacist and admin): Stock and Catalogue as tables. Admins may
/// also delete stock items; catalogue medicines are deactivated, never deleted (old
/// prescriptions refer to them).
class InventoryPage extends ConsumerWidget {
  const InventoryPage({super.key, this.admin = false});
  final bool admin;

  @override
  Widget build(BuildContext context, WidgetRef ref) => DefaultTabController(
    length: 2,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
          child: PageHeader(
            title: 'Inventory',
            subtitle: 'Medicines, prices and stock levels. Low stock is flagged.',
            icon: Icons.inventory_2_outlined,
            color: Colors.brown,
            actions: [
              // D-79: bulk add or update medicines and stock from a CSV / JSON file.
              OutlinedButton.icon(
                key: const Key('inventory-import'),
                onPressed: () async {
                  if (await showImportDialog(context, ImportKind.inventory)) {
                    ref
                      ..invalidate(stockProvider)
                      ..invalidate(catalogProvider);
                  }
                },
                icon: const Icon(Icons.upload_file),
                label: const Text('Import'),
              ),
              IconButton(
                key: const Key('inventory-refresh'),
                tooltip: 'Refresh',
                onPressed: () => ref
                  ..invalidate(stockProvider)
                  ..invalidate(catalogProvider),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        const Align(
          alignment: Alignment.centerLeft,
          child: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(key: Key('inventory-tab-stock'), text: 'Stock'),
              Tab(key: Key('inventory-tab-catalogue'), text: 'Catalogue'),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            children: [
              _StockTab(admin: admin),
              const _CatalogueTab(),
            ],
          ),
        ),
      ],
    ),
  );
}

// ---------------- stock ----------------

String _thousands(int n) =>
    n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

enum _StockFilter { all, low, expiring, expired }

/// How an expiry date reads in the table: past, within 90 days, or fine.
(String, Color?) _expiryLook(String? iso, DateTime now) {
  final d = iso == null ? null : DateTime.tryParse(iso);
  if (d == null) return ('—', null);
  final label =
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  if (!d.isAfter(now)) return (label, Colors.red.shade600);
  if (d.difference(now).inDays <= 90) return (label, Colors.amber.shade800);
  return (label, null);
}

class _StockTab extends ConsumerStatefulWidget {
  const _StockTab({required this.admin});
  final bool admin;

  @override
  ConsumerState<_StockTab> createState() => _StockTabState();
}

class _StockTabState extends ConsumerState<_StockTab> {
  _StockFilter _filter = _StockFilter.all;
  String _query = '';

  Future<void> _receive(StockItem s) async {
    final result = await showDialog<StockEntry>(
      context: context,
      builder: (_) => StockDialog(title: 'Receive ${s.name}', askName: false, current: s),
    );
    if (result == null || !mounted) return;
    await runPharmacyAction(
      context,
      ref,
      () => ref.read(ordersRepositoryProvider).receiveStock(s.id, result.units, result.expiry),
      '${_thousands(result.units)} units of ${s.name} received.',
    );
  }

  Future<void> _lowAt(StockItem s) async {
    final text = await showDialog<String>(
      context: context,
      builder: (_) => PromptDialog(
        title: 'Low-stock warning for ${s.name}',
        message: 'The item is flagged "Low" when units on hand fall below this level.',
        initial: '${s.lowStockAt}',
        fieldKey: const Key('low-at-input'),
        label: 'Warn below (units)',
        confirmText: 'Save',
        keyboardType: TextInputType.number,
        allowed: RegExp(r'[0-9]'),
        maxLength: 6,
        isValid: (v) => StockRules.warnAt(v) == null,
        errorFor: StockRules.warnAt,
      ),
    );
    final v = int.tryParse(text ?? '');
    if (v == null || !mounted) return;
    await runPharmacyAction(
      context,
      ref,
      () => ref.read(ordersRepositoryProvider).setLowStockAt(s.id, v),
      'Warning level for ${s.name} saved.',
    );
  }

  Future<void> _delete(StockItem s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete ${s.name}?'),
        content: const Text('The stock record is removed. Orders already filled are kept.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('stock-delete-confirm'),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await runPharmacyAction(
      context,
      ref,
      () => ref.read(ordersRepositoryProvider).deleteStock(s.id),
      '${s.name} deleted.',
    );
  }

  bool _matches(StockItem s, DateTime now) {
    if (_query.isNotEmpty && !s.name.toLowerCase().contains(_query.toLowerCase())) return false;
    final colour = _expiryLook(s.expiryDate, now).$2;
    return switch (_filter) {
      _StockFilter.all => true,
      _StockFilter.low => s.low || s.units == 0,
      _StockFilter.expiring => colour == Colors.amber.shade800,
      _StockFilter.expired => colour == Colors.red.shade600,
    };
  }

  @override
  Widget build(BuildContext context) {
    final stock = ref.watch(stockProvider);
    final theme = Theme.of(context);
    final now = DateTime.now();
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            const Expanded(child: Text('Units on hand, warning levels and earliest expiry.')),
            FilledButton.tonalIcon(
              key: const Key('new-stock'),
              onPressed: () => addStockItem(context, ref),
              icon: const Icon(Icons.add),
              label: const Text('New stock item'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        stock.when(
          loading: () => const LinearProgressIndicator(),
          error: (_, _) => TextButton(
            onPressed: () => ref.invalidate(stockProvider),
            child: const Text('Could not load stock. Retry'),
          ),
          data: (items) {
            if (items.isEmpty) return const Text('No stock recorded yet.');
            int count(_StockFilter f) {
              final keep = _filter;
              _filter = f;
              final n = items.where((s) => _matches(s, now)).length;
              _filter = keep;
              return n;
            }

            final shown = [
              for (final s in items)
                if (_matches(s, now)) s,
            ];
            Widget chip(_StockFilter f, IconData icon, String label, Color color) =>
                TableSummaryChip(
                  key: Key('stock-filter-${f.name}'),
                  icon: icon,
                  label: '$label (${count(f)})',
                  color: color,
                  selected: _filter == f,
                  onTap: () => setState(() => _filter = f),
                );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    chip(
                      _StockFilter.all,
                      Icons.inventory_2_outlined,
                      'All',
                      theme.colorScheme.primary,
                    ),
                    chip(_StockFilter.low, Icons.trending_down, 'Low or out', Colors.red.shade600),
                    chip(
                      _StockFilter.expiring,
                      Icons.schedule,
                      'Expiring in 90 days',
                      Colors.amber.shade800,
                    ),
                    chip(_StockFilter.expired, Icons.event_busy, 'Expired', Colors.red.shade900),
                    SizedBox(
                      width: 260,
                      child: TextField(
                        key: const Key('stock-search'),
                        decoration: const InputDecoration(
                          isDense: true,
                          prefixIcon: Icon(Icons.search),
                          hintText: 'Search medicines',
                        ),
                        onChanged: (v) => setState(() => _query = v.trim()),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: shown.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('Nothing matches this filter.'),
                        )
                      : WideTable(
                          table: DataTable(
                            key: const Key('stock-table'),
                            columns: const [
                              DataColumn(
                                label: Text('Medicine'),
                                columnWidth: IntrinsicColumnWidth(flex: 3),
                              ),
                              DataColumn(
                                label: Text('Units on hand'),
                                numeric: true,
                                columnWidth: IntrinsicColumnWidth(flex: 1.4),
                              ),
                              DataColumn(
                                label: Text('Status'),
                                columnWidth: IntrinsicColumnWidth(flex: 1.6),
                              ),
                              DataColumn(
                                label: Text('Warn below'),
                                numeric: true,
                                columnWidth: IntrinsicColumnWidth(flex: 1.2),
                              ),
                              DataColumn(
                                label: Text('Earliest expiry'),
                                columnWidth: IntrinsicColumnWidth(flex: 1.6),
                              ),
                              DataColumn(
                                label: Text('Actions'),
                                columnWidth: IntrinsicColumnWidth(flex: 1.6),
                              ),
                            ],
                            rows: [for (final s in shown) _row(s, now, theme)],
                          ),
                        ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  DataRow _row(StockItem s, DateTime now, ThemeData theme) {
    final (expiry, expiryColour) = _expiryLook(s.expiryDate, now);
    final out = s.units == 0;
    return DataRow(
      key: ValueKey('stock-${s.id}'),
      cells: [
        DataCell(
          Row(
            children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Icon(Icons.medication, size: 16, color: theme.colorScheme.primary),
              ),
              const SizedBox(width: 10),
              Flexible(child: Text(s.name, style: theme.textTheme.titleSmall)),
            ],
          ),
        ),
        DataCell(Text(_thousands(s.units), style: theme.textTheme.titleSmall)),
        DataCell(
          out
              ? TablePill('Out of stock', color: Colors.red.shade700, icon: Icons.block)
              : s.low
              ? TablePill('Low', color: Colors.orange.shade800, icon: Icons.trending_down)
              : TablePill('In stock', color: Colors.green.shade700, icon: Icons.check_circle),
        ),
        DataCell(Text(_thousands(s.lowStockAt))),
        DataCell(
          expiryColour == null
              ? Text(expiry)
              : TablePill(
                  expiryColour == Colors.red.shade600 ? 'Expired $expiry' : expiry,
                  color: expiryColour,
                  icon: Icons.schedule,
                ),
        ),
        DataCell(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                key: Key('receive-${s.id}'),
                tooltip: 'Receive stock',
                onPressed: () => _receive(s),
                icon: const Icon(Icons.add_box_outlined),
              ),
              IconButton(
                key: Key('low-at-${s.id}'),
                tooltip: 'Low-stock warning level',
                onPressed: () => _lowAt(s),
                icon: const Icon(Icons.tune),
              ),
              if (widget.admin)
                IconButton(
                  key: Key('stock-delete-${s.id}'),
                  tooltip: 'Delete',
                  onPressed: () => _delete(s),
                  icon: const Icon(Icons.delete_outline),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------- catalogue ----------------

class _CatalogueTab extends ConsumerStatefulWidget {
  const _CatalogueTab();

  @override
  ConsumerState<_CatalogueTab> createState() => _CatalogueTabState();
}

class _CatalogueTabState extends ConsumerState<_CatalogueTab> {
  bool? _offered; // null = all
  String _query = '';

  Future<void> _add(List<CatalogItem> catalog) async {
    final r = await showDialog<CatalogEntry>(
      context: context,
      builder: (_) => CatalogFormDialog(catalog: catalog),
    );
    if (r == null || !mounted) return;
    await runPharmacyAction(
      context,
      ref,
      () => ref
          .read(ordersRepositoryProvider)
          .addCatalogItem(
            name: r.name,
            strength: r.strength,
            form: r.form,
            drugClass: r.drugClass,
            unitPrice: r.price,
          ),
      '${r.name} ${r.strength} added to the catalogue.',
    );
    ref.invalidate(catalogProvider);
  }

  Future<void> _edit(CatalogItem c, List<CatalogItem> catalog) async {
    final r = await showDialog<CatalogEntry>(
      context: context,
      builder: (_) => CatalogFormDialog(item: c, catalog: catalog),
    );
    if (r == null || !mounted) return;
    await runPharmacyAction(
      context,
      ref,
      () => ref
          .read(ordersRepositoryProvider)
          .editCatalogItem(
            c.id,
            name: r.name,
            strength: r.strength,
            form: r.form,
            drugClass: r.drugClass,
            unitPrice: r.price,
          ),
      '${r.name} ${r.strength} saved. New prescriptions use the new price.',
    );
    ref.invalidate(catalogProvider);
  }

  Future<void> _toggle(CatalogItem c, bool active) async {
    await runPharmacyAction(
      context,
      ref,
      () => ref.read(ordersRepositoryProvider).editCatalogItem(c.id, active: active),
      active ? '${c.label} offered to doctors again.' : '${c.label} hidden from doctors.',
    );
    ref.invalidate(catalogProvider);
  }

  @override
  Widget build(BuildContext context) {
    final catalog = ref.watch(catalogProvider);
    final theme = Theme.of(context);
    final items = catalog.value ?? const <CatalogItem>[];
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Medicines doctors can prescribe. Prices apply to new prescriptions only.',
              ),
            ),
            FilledButton.tonalIcon(
              key: const Key('catalog-add'),
              onPressed: () => _add(items),
              icon: const Icon(Icons.add),
              label: const Text('Add medicine'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        catalog.when(
          loading: () => const LinearProgressIndicator(),
          error: (_, _) => TextButton(
            onPressed: () => ref.invalidate(catalogProvider),
            child: const Text('Could not load the catalogue. Retry'),
          ),
          data: (items) {
            final q = _query.toLowerCase();
            final shown = [
              for (final c in items)
                if ((_offered == null || c.active == _offered) &&
                    (q.isEmpty ||
                        c.label.toLowerCase().contains(q) ||
                        c.drugClass.toLowerCase().contains(q)))
                  c,
            ];
            Widget chip(bool? v, IconData icon, String label, Color color) => TableSummaryChip(
              key: Key('catalog-filter-${v ?? 'all'}'),
              icon: icon,
              label: '$label (${items.where((c) => v == null || c.active == v).length})',
              color: color,
              selected: _offered == v,
              onTap: () => setState(() => _offered = v),
            );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    chip(null, Icons.menu_book_outlined, 'All', theme.colorScheme.primary),
                    chip(true, Icons.visibility_outlined, 'Offered', Colors.green.shade700),
                    chip(false, Icons.visibility_off_outlined, 'Hidden', theme.colorScheme.outline),
                    SizedBox(
                      width: 260,
                      child: TextField(
                        key: const Key('catalog-search'),
                        decoration: const InputDecoration(
                          isDense: true,
                          prefixIcon: Icon(Icons.search),
                          hintText: 'Search name or class',
                        ),
                        onChanged: (v) => setState(() => _query = v.trim()),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: shown.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('Nothing matches this filter.'),
                        )
                      : WideTable(
                          table: DataTable(
                            key: const Key('catalog-table'),
                            columns: const [
                              DataColumn(
                                label: Text('Medicine'),
                                columnWidth: IntrinsicColumnWidth(flex: 2.4),
                              ),
                              DataColumn(
                                label: Text('Class'),
                                columnWidth: IntrinsicColumnWidth(flex: 2.4),
                              ),
                              DataColumn(
                                label: Text('Form'),
                                columnWidth: IntrinsicColumnWidth(flex: 1.2),
                              ),
                              DataColumn(
                                label: Text('Unit price'),
                                numeric: true,
                                columnWidth: IntrinsicColumnWidth(flex: 1.2),
                              ),
                              DataColumn(
                                label: Text('Offered'),
                                columnWidth: IntrinsicColumnWidth(flex: 1),
                              ),
                              DataColumn(
                                label: Text('Edit'),
                                columnWidth: IntrinsicColumnWidth(flex: 0.8),
                              ),
                            ],
                            rows: [
                              for (final c in shown)
                                DataRow(
                                  key: ValueKey('catalog-${c.id}'),
                                  color: c.active
                                      ? null
                                      : WidgetStatePropertyAll(
                                          theme.colorScheme.surfaceContainerHighest.withValues(
                                            alpha: 0.5,
                                          ),
                                        ),
                                  cells: [
                                    DataCell(
                                      Text.rich(
                                        TextSpan(
                                          children: [
                                            TextSpan(
                                              text: c.name,
                                              style: theme.textTheme.titleSmall,
                                            ),
                                            TextSpan(
                                              text: '  ${c.strength}',
                                              style: theme.textTheme.bodyMedium?.copyWith(
                                                color: theme.colorScheme.onSurfaceVariant,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    DataCell(
                                      c.drugClass.isEmpty
                                          ? const Text('—')
                                          : TablePill(
                                              c.drugClass,
                                              color: theme.colorScheme.primary,
                                            ),
                                    ),
                                    DataCell(Text(c.form[0].toUpperCase() + c.form.substring(1))),
                                    DataCell(
                                      Text(rm(c.unitPrice), style: theme.textTheme.titleSmall),
                                    ),
                                    DataCell(
                                      Switch(
                                        key: Key('catalog-active-${c.id}'),
                                        value: c.active,
                                        onChanged: (v) => _toggle(c, v),
                                      ),
                                    ),
                                    DataCell(
                                      IconButton(
                                        key: Key('catalog-edit-${c.id}'),
                                        tooltip: 'Edit',
                                        onPressed: () => _edit(c, items),
                                        icon: const Icon(Icons.edit_outlined),
                                      ),
                                    ),
                                  ],
                                ),
                            ],
                          ),
                        ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}
