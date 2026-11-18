import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../appointments/domain/appointment_text.dart' show dateLabel;
import '../../medications/domain/med_schedule.dart' show describeSchedule;
import '../data/order_models.dart';
import '../state/orders_providers.dart';
import 'order_widgets.dart';
import '../../../shared/widgets/fill_grid.dart';
import '../../../shared/widgets/profile_header.dart';
import '../../../shared/widgets/wide_table.dart' show TablePill;

/// D-69: a pharmacy patient's dispensing details: profile, allergies and conditions,
/// medicines, prescriptions and orders. No readings, risk, notes or record files.
/// D-116: laid out as a profile header, safety banner, counts and section cards.
class PharmacyPatientPage extends ConsumerWidget {
  const PharmacyPatientPage({super.key, required this.patientId});
  final String patientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(pharmacyPatientProvider(patientId));
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            TextButton.icon(
              key: const Key('back-to-patients'),
              onPressed: () => context.go('/pharmacy/patients'),
              icon: const Icon(Icons.arrow_back),
              label: const Text('Patients'),
            ),
            const Spacer(),
          ],
        ),
        const SizedBox(height: 8),
        detail.when(
          loading: () => const LinearProgressIndicator(),
          error: (_, _) => const Text('This patient could not be loaded.'),
          data: (p) => _Body(p: p, patientId: patientId),
        ),
      ],
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.p, required this.patientId});
  final PharmacyPatientDetail p;
  final String patientId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = p.orders.where((o) => o.isActive).length;
    final recurring = p.prescriptions.where((r) => r.isRecurring).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ProfileHeaderCard(
          name: p.name,
          color: Colors.teal.shade700,
          badges: [ProfileBadge('Patient', color: Colors.teal.shade700, icon: Icons.person)],
          facts: [
            if (p.age != null || p.gender != null)
              (Icons.cake_outlined, [if (p.age != null) '${p.age} years', ?p.gender].join(' · ')),
            if (p.phone != null) (Icons.phone_outlined, p.phone!),
            if (p.email != null) (Icons.mail_outline, p.email!),
            if (p.address != null) (Icons.home_outlined, p.address!),
          ],
          actions: [
            FilledButton.icon(
              key: const Key('message-patient'),
              onPressed: () => context.go('/pharmacy/messages/$patientId'),
              icon: const Icon(Icons.chat_outlined),
              label: const Text('Message patient'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _SafetyBanner(p: p),
        const SizedBox(height: 16),
        FillGrid(
          minItemWidth: 180,
          spacing: 12,
          equalHeight: true,
          children: [
            _Count(Icons.medication_outlined, '${p.medications.length}', 'Current medicines'),
            _Count(
              Icons.description_outlined,
              '${p.prescriptions.length}',
              recurring == 0 ? 'Prescriptions' : 'Prescriptions · $recurring monthly',
            ),
            _Count(Icons.receipt_long_outlined, '${p.orders.length}', 'Orders'),
            _Count(
              Icons.local_pharmacy_outlined,
              '$active',
              'In progress',
              color: active > 0 ? Colors.blue.shade700 : null,
            ),
          ],
        ),
        const SizedBox(height: 16),
        FillGrid(
          minItemWidth: 460,
          children: [
            InfoSection(
              icon: Icons.medication_outlined,
              title: 'Current medicines',
              child: p.medications.isEmpty
                  ? const Text('None recorded.')
                  : Column(children: [for (final m in p.medications) _MedicineRow(m: m)]),
            ),
            InfoSection(
              icon: Icons.description_outlined,
              title: 'Prescriptions',
              child: p.prescriptions.isEmpty
                  ? const Text('None.')
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [for (final r in p.prescriptions) _PrescriptionTile(r: r)],
                    ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        InfoSection(
          icon: Icons.receipt_long_outlined,
          title: 'Orders and payments',
          child: p.orders.isEmpty
              ? const Text('None.')
              : Column(
                  children: [
                    for (final o in p.orders)
                      ListTile(
                        key: Key('patient-order-${o.id}'),
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(
                          backgroundColor: theme.colorScheme.secondaryContainer,
                          child: Icon(
                            o.method == homeDelivery
                                ? Icons.local_shipping_outlined
                                : Icons.storefront_outlined,
                            size: 20,
                          ),
                        ),
                        // D-85: open the order with its payments and receipt.
                        onTap: () => context.go(
                          Uri(
                            path: '/pharmacy/order/${o.id}',
                            queryParameters: {
                              'back': GoRouterState.of(context).uri.path,
                              'backLabel': 'Patient',
                            },
                          ).toString(),
                        ),
                        title: Text('${o.ref} · ${cycleLabel(o.cycleDate)}'),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              OrderStatusChip.staff(o),
                              TablePill(
                                'payment ${o.paymentStatus}',
                                color: o.isPaid
                                    ? Colors.green.shade700
                                    : o.paymentFailed
                                    ? theme.colorScheme.error
                                    : theme.colorScheme.outline,
                              ),
                              if (o.method != null)
                                Text(o.method == homeDelivery ? 'Home delivery' : 'Collection'),
                            ],
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (o.total != null)
                              Text(rm(o.total!), style: theme.textTheme.titleSmall),
                            const Icon(Icons.chevron_right),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// Allergies first and loud; conditions as chips.
class _SafetyBanner extends StatelessWidget {
  const _SafetyBanner({required this.p});
  final PharmacyPatientDetail p;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allergic = p.allergies.isNotEmpty;
    final colour = allergic ? theme.colorScheme.error : Colors.green.shade700;
    return Container(
      key: const Key('patient-allergies'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: allergic ? theme.colorScheme.errorContainer : colour.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border(left: BorderSide(color: colour, width: 5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            allergic ? Icons.warning_amber_rounded : Icons.verified_user_outlined,
            color: colour,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  allergic ? 'Allergies: ${p.allergies}' : 'No known allergies',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: allergic ? theme.colorScheme.onErrorContainer : null,
                  ),
                ),
                const SizedBox(height: 8),
                if (p.conditions.isEmpty)
                  Text('No conditions recorded', style: theme.textTheme.bodySmall)
                else
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final c in p.conditions)
                        Chip(
                          visualDensity: VisualDensity.compact,
                          avatar: const Icon(Icons.healing_outlined, size: 16),
                          label: Text(c.replaceAll('_', ' ')),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count(this.icon, this.value, this.label, {this.color});
  final IconData icon;
  final String value;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = color ?? theme.colorScheme.primary;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: c),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(value, style: theme.textTheme.titleLarge?.copyWith(color: c)),
                  Text(label, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MedicineRow extends StatelessWidget {
  const _MedicineRow({required this.m});
  final PatientMedicine m;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final left = m.quantityOnHand;
    final low = left != null && left < 7;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            m.fromDoctor ? Icons.medical_services_outlined : Icons.person_outline,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${m.name} · ${m.dosage}', style: theme.textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(
                  [
                    describeSchedule(m.schedule),
                    m.fromDoctor ? 'from ${m.prescribedBy ?? 'doctor'}' : 'self-added',
                  ].join(' · '),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (left != null)
            TablePill(
              '${left.toStringAsFixed(0)} left',
              color: low ? Colors.orange.shade800 : theme.colorScheme.outline,
            ),
        ],
      ),
    );
  }
}

class _PrescriptionTile extends StatelessWidget {
  const _PrescriptionTile({required this.r});
  final PatientPrescription r;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = r.items.isEmpty
        ? [r.medicationDetails]
        : [
            for (final i in r.items)
              '${i.label} ${i.dose}, ${frequencyLabel(i.frequency).toLowerCase()} ×${i.quantity}',
          ];
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final l in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('•  '),
                  Expanded(child: Text(l)),
                ],
              ),
            ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (r.issuedAt != null)
                Text('Issued ${dateLabel(r.issuedAt!)}', style: theme.textTheme.bodySmall),
              if (r.isRecurring)
                TablePill('Repeats monthly', color: Colors.indigo.shade400, icon: Icons.repeat),
            ],
          ),
        ],
      ),
    );
  }
}
