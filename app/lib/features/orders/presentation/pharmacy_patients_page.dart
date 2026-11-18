import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/order_models.dart';
import '../state/orders_providers.dart';
import '../../../shared/widgets/page_header.dart';
import '../../../shared/widgets/wide_table.dart';

/// D-70 pharmacy Patients tab: every patient (like the admin user list, patients only),
/// each opening the dispensing view.
class PharmacyPatientsPage extends ConsumerStatefulWidget {
  const PharmacyPatientsPage({super.key});

  @override
  ConsumerState<PharmacyPatientsPage> createState() => _PharmacyPatientsPageState();
}

class _PharmacyPatientsPageState extends ConsumerState<PharmacyPatientsPage> {
  String _query = '';
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final list = ref.watch(pharmacyLookupProvider(_query));
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const PageHeader(
          title: 'Patients',
          subtitle: 'Open a patient to see dispensing details or message them.',
          icon: Icons.people_alt_outlined,
          color: Colors.teal,
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('patients-search'),
          controller: _search,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: 'Name, email, IC or patient ID, then press Enter',
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear',
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() {
                      _search.clear();
                      _query = '';
                    }),
                  ),
          ),
          onSubmitted: (v) => setState(() => _query = v.trim()),
        ),
        const SizedBox(height: 16),
        list.when(
          loading: () => const LinearProgressIndicator(),
          error: (_, _) => TextButton(
            onPressed: () => ref.invalidate(pharmacyLookupProvider(_query)),
            child: const Text('Could not load patients. Retry'),
          ),
          data: (patients) => patients.isEmpty
              ? const Padding(
                  key: Key('patients-empty'),
                  padding: EdgeInsets.all(16),
                  child: Text('No patient matches.'),
                )
              : Card(
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      WideTable(
                        table: DataTable(
                          key: const Key('patients-table'),
                          showCheckboxColumn: false,
                          dataRowMinHeight: 60,
                          dataRowMaxHeight: 64,
                          columns: const [
                            DataColumn(
                              label: Text('Patient'),
                              columnWidth: IntrinsicColumnWidth(flex: 3),
                            ),
                            DataColumn(
                              label: Text('Age / gender'),
                              columnWidth: IntrinsicColumnWidth(flex: 1.4),
                            ),
                            DataColumn(
                              label: Text('Orders'),
                              numeric: true,
                              columnWidth: IntrinsicColumnWidth(flex: 1),
                            ),
                            DataColumn(
                              label: Text('Active orders'),
                              columnWidth: IntrinsicColumnWidth(flex: 1.4),
                            ),
                            DataColumn(
                              label: Text('Account'),
                              columnWidth: IntrinsicColumnWidth(flex: 1.2),
                            ),
                            DataColumn(label: Text(''), columnWidth: IntrinsicColumnWidth()),
                          ],
                          rows: [
                            for (final PharmacyPatient p in patients)
                              DataRow(
                                key: ValueKey('patient-${p.id}'),
                                onSelectChanged: (_) => context.go('/pharmacy/patients/${p.id}'),
                                cells: [
                                  DataCell(
                                    Row(
                                      children: [
                                        CircleAvatar(
                                          radius: 18,
                                          backgroundColor: theme.colorScheme.primaryContainer,
                                          child: Text(
                                            _initials(p.name),
                                            style: theme.textTheme.labelLarge?.copyWith(
                                              color: theme.colorScheme.onPrimaryContainer,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Flexible(
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(p.name, style: theme.textTheme.titleSmall),
                                              Text(
                                                p.email ?? '—',
                                                style: theme.textTheme.bodySmall?.copyWith(
                                                  color: theme.colorScheme.onSurfaceVariant,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  DataCell(
                                    Text([if (p.age != null) '${p.age}', ?p.gender].join(' · ')),
                                  ),
                                  DataCell(Text('${p.orderCount}')),
                                  DataCell(
                                    p.activeOrders == 0
                                        ? Text(
                                            'None',
                                            style: TextStyle(color: theme.colorScheme.outline),
                                          )
                                        : TablePill(
                                            '${p.activeOrders} in progress',
                                            color: Colors.blue.shade700,
                                            icon: Icons.local_pharmacy_outlined,
                                          ),
                                  ),
                                  DataCell(
                                    p.isActive
                                        ? TablePill('Active', color: Colors.green.shade700)
                                        : TablePill('Deactivated', color: theme.colorScheme.error),
                                  ),
                                  const DataCell(Icon(Icons.chevron_right)),
                                ],
                              ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          '${patients.length} patient${patients.length == 1 ? '' : 's'}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

String _initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  return (parts.length == 1 ? parts.first[0] : parts.first[0] + parts.last[0]).toUpperCase();
}
