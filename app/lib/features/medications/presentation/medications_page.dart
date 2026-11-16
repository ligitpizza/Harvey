import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/models/health_models.dart';
import '../../../shared/services/api/api_client.dart';
import '../../auth/state/auth_providers.dart';
import '../../dashboard/state/dashboard_providers.dart';
import '../../provider_portal/domain/portal_models.dart';
import '../domain/med_schedule.dart';
import '../../../shared/widgets/prescription_style.dart';
import '../domain/prescription_import.dart';
import '../state/medication_providers.dart';
import '../../orders/presentation/order_widgets.dart';

/// Fig 4.3.5.1 Medications (FR-5.1, FR-5.2, FR-5.3, FR-5.4; UC5.2, UC5.3, UC5.5).
class MedicationsPage extends ConsumerStatefulWidget {
  const MedicationsPage({super.key});

  @override
  ConsumerState<MedicationsPage> createState() => _MedicationsPageState();
}

class _MedicationsPageState extends ConsumerState<MedicationsPage> {
  Timer? _tick;
  final _busy = <String>{};

  @override
  void initState() {
    super.initState();
    // Upcoming doses become "Take" an hour before their time.
    _tick = Timer.periodic(const Duration(minutes: 1), (_) => ref.invalidate(todaysDosesProvider));
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _confirm(Medication med, {DateTime? scheduledTime}) async {
    final key = '${med.id}@$scheduledTime';
    setState(() => _busy.add(key));
    final messenger = ScaffoldMessenger.of(context);
    try {
      final late = await ref
          .read(medicationsRepositoryProvider)
          .confirmDose(med.id, scheduledTime: scheduledTime);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            late ? '${med.name} recorded as taken late.' : '${med.name} dose recorded.',
          ),
        ),
      );
    } on ApiException catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            e.code == 'DOSE_ALREADY_LOGGED' ? 'That dose is already recorded.' : e.message,
          ),
        ),
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not record the dose. Please try again.')),
      );
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }

  @override
  Widget build(BuildContext context) {
    final meds = ref.watch(medicationsProvider);
    final doses = ref.watch(todaysDosesProvider);
    final now = ref.watch(nowProvider)();
    return Scaffold(
      appBar: AppBar(title: const Text('Meds')),
      floatingActionButton: FloatingActionButton(
        key: const Key('add-medication'),
        tooltip: 'Add medication',
        onPressed: () => context.push('/medications/add'),
        child: const Icon(Icons.add),
      ),
      body: meds.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => _Message(
          icon: Icons.cloud_off,
          text: 'Could not load your medications.',
          action: TextButton(
            onPressed: () => ref.invalidate(medicationsProvider),
            child: const Text('Retry'),
          ),
        ),
        data: (list) {
          final prescriptions = ref.watch(myPrescriptionsProvider).value ?? const <Prescription>[];
          if (list.isEmpty && prescriptions.isEmpty) {
            return _Message(
              key: const Key('meds-empty'),
              icon: Icons.medication_outlined,
              text: 'No medications yet. Tap + to add your first one and get reminders.',
              action: TextButton(
                key: const Key('record-prescription'),
                onPressed: () => context.push('/medications/prescription'),
                child: const Text('Record a prescription from another clinic'),
              ),
            );
          }
          final scheduled = doses.value ?? const <ScheduledDose>[];
          final prn = [
            for (final m in list)
              if (tryParseSchedule(m.schedule) == null) m,
          ];
          final refills = [
            for (final m in list)
              if (needsRefill(m)) m,
          ];
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            children: [
              _ScheduleHeader(now: now),
              const MonthlyOrdersBanner(), // UC13.2 (D-66)
              if (scheduled.isNotEmpty) const _ReminderStatusLine(),
              if (scheduled.isNotEmpty) const _ExactRemindersBanner(),
              if (scheduled.isNotEmpty) const _BackgroundBanner(),
              if (scheduled.isNotEmpty) _ProgressCard(doses: scheduled),
              for (final period in DosePeriod.values.where((p) => p != DosePeriod.asNeeded))
                if (scheduled.any((d) => d.period == period)) ...[
                  _PeriodHeader(period: period),
                  for (final d in scheduled.where((d) => d.period == period))
                    _DoseTile(
                      dose: d,
                      busy: _busy.contains('${d.medication.id}@${d.moment}'),
                      onTake: () => _confirm(d.medication, scheduledTime: d.moment),
                    ),
                ],
              if (prn.isNotEmpty) ...[
                const _PeriodHeader(period: DosePeriod.asNeeded),
                for (final m in prn)
                  _AsNeededTile(
                    med: m,
                    busy: _busy.contains('${m.id}@null'),
                    onLog: () => _confirm(m),
                  ),
              ],
              if (refills.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text('Action needed', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                for (final m in refills) _RefillCard(med: m),
              ],
              const SizedBox(height: 16),
              if (list.isNotEmpty) ...[
                Text('Your medicines', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                for (final m in list) _MedicineTile(med: m),
              ] else
                const Text('No medicines on your reminder list yet.'),
              const SizedBox(height: 16),
              Text('Prescriptions', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              for (final p in prescriptions)
                _PrescriptionTile(
                  prescription: p,
                  tracked: alreadyTracked(p.medicationDetails, list.map((m) => m.name)),
                ),
              // D-50: prescriptions from other clinics, shown in green.
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('record-prescription'),
                  onPressed: () => context.push('/medications/prescription'),
                  icon: const Icon(Icons.add),
                  label: const Text('Record a prescription from another clinic'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// What the phone actually scheduled, or why it couldn't (never fail silently).
class _ReminderStatusLine extends ConsumerWidget {
  const _ReminderStatusLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(reminderStatusProvider);
    final scheme = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.bodySmall;
    Widget problem(String key, String text) => Row(
      key: Key(key),
      children: [
        Expanded(
          child: Text(text, style: small?.copyWith(color: scheme.error)),
        ),
        TextButton(
          key: const Key('reminders-retry'),
          onPressed: () {
            final meds = ref.read(reminderMedicationsProvider);
            if (meds != null) syncReminders(ref, meds);
          },
          child: const Text('Try again'),
        ),
      ],
    );
    return switch (status) {
      AsyncError(:final error) => problem(
        'reminders-failed',
        'Phone reminders could not be set: $error',
      ),
      AsyncData(:final value) when value.errors.isNotEmpty => problem(
        'reminders-partial',
        'Some reminders could not be set:\n${value.errors.join('\n')}',
      ),
      AsyncData(:final value) => _RemindersCard(
        key: const Key('reminders-ok'),
        scheduled: value.scheduled,
        exact: value.exact,
      ),
      _ => const SizedBox.shrink(),
    };
  }
}

/// D-99: "Atorvastatin 20mg 8:00 AM" lines grouped by time, in time order.
List<(String, List<String>)> remindersByTime(List<String> scheduled) {
  final pattern = RegExp(r'^(.*)\s(\d{1,2}):(\d{2})\s([AP]M)$');
  final groups = <String, List<String>>{};
  final order = <String, int>{};
  for (final line in scheduled) {
    final m = pattern.firstMatch(line.trim());
    if (m == null) {
      (groups['Other'] ??= []).add(line);
      order['Other'] = 24 * 60;
      continue;
    }
    final h = int.parse(m.group(2)!) % 12 + (m.group(4) == 'PM' ? 12 : 0);
    final time = '${m.group(2)}:${m.group(3)} ${m.group(4)}';
    (groups[time] ??= []).add(m.group(1)!.trim());
    order[time] = h * 60 + int.parse(m.group(3)!);
  }
  final keys = groups.keys.toList()..sort((a, b) => order[a]!.compareTo(order[b]!));
  return [for (final k in keys) (k, groups[k]!)];
}

/// D-99: the reminders the phone set, folded to one line; tap to see them by time.
class _RemindersCard extends StatefulWidget {
  const _RemindersCard({super.key, required this.scheduled, required this.exact});

  final List<String> scheduled;
  final bool exact;

  @override
  State<_RemindersCard> createState() => _RemindersCardState();
}

class _RemindersCardState extends State<_RemindersCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final n = widget.scheduled.length;
    final groups = remindersByTime(widget.scheduled);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: n == 0 ? null : () => setState(() => _open = !_open),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: (widget.exact ? Colors.green : Colors.orange).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.alarm_on,
                      size: 20,
                      color: widget.exact ? Colors.green.shade700 : Colors.orange.shade800,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          n == 0 ? 'No phone reminders set' : 'Phone reminders on · $n set',
                          key: const Key('reminders-summary'),
                          style: theme.textTheme.titleSmall,
                        ),
                        if (n > 0)
                          Text(
                            widget.exact
                                ? 'At ${groups.map((g) => g.$1).join(', ')}'
                                : 'Reminders may be a few minutes late',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
                  if (n > 0)
                    Icon(_open ? Icons.expand_less : Icons.expand_more, color: scheme.outline),
                ],
              ),
              if (_open) ...[
                const SizedBox(height: 10),
                for (final (time, names) in groups)
                  Padding(
                    key: Key('reminder-time-$time'),
                    padding: const EdgeInsets.only(bottom: 8, right: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 76,
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: scheme.primaryContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            time,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: scheme.onPrimaryContainer,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (final name in names)
                                Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 2),
                                  child: Row(
                                    children: [
                                      Icon(Icons.circle, size: 6, color: scheme.primary),
                                      const SizedBox(width: 8),
                                      Expanded(child: Text(name)),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// D-43: without Android's "Alarms & reminders" permission, reminders may arrive late.
class _ExactRemindersBanner extends ConsumerWidget {
  const _ExactRemindersBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(exactRemindersAllowedProvider).value != false) return const SizedBox.shrink();
    return Card(
      key: const Key('exact-reminders-banner'),
      child: ListTile(
        leading: const Icon(Icons.alarm_off_outlined),
        title: const Text('Reminders may arrive late'),
        subtitle: const Text('Allow "Alarms & reminders" so Harvey reminds you on time.'),
        trailing: TextButton(
          key: const Key('allow-exact-reminders'),
          onPressed: () async {
            final reminders = ref.read(doseRemindersProvider);
            await reminders.requestExact();
            ref.invalidate(exactRemindersAllowedProvider);
            // Re-schedule so existing reminders use the new precision.
            final meds = ref.read(reminderMedicationsProvider);
            if (meds != null) await syncReminders(ref, meds);
          },
          child: const Text('Allow'),
        ),
      ),
    );
  }
}

/// Phones that save battery aggressively (Honor, Xiaomi) can hold reminders back.
class _BackgroundBanner extends ConsumerWidget {
  const _BackgroundBanner();

  Future<void> _phoneSteps(BuildContext context, WidgetRef ref) async {
    final open = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        key: const Key('background-steps'),
        title: const Text('Keep reminders on time'),
        content: const Text(
          'In the settings page that opens:\n\n'
          'Honor / Huawei: Battery → App launch → Harvey → turn off "Manage '
          'automatically", then turn on Auto-launch, Secondary launch and Run in background.\n\n'
          'Xiaomi / Redmi: turn on Autostart and set Battery saver to "No restrictions".\n\n'
          'Other phones: set Battery to "Unrestricted".',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('open-phone-settings'),
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('Open settings'),
          ),
        ],
      ),
    );
    if (open == true) await ref.read(backgroundAccessProvider).openSettings();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(backgroundPromptProvider).value != true) return const SizedBox.shrink();
    final access = ref.read(backgroundAccessProvider);
    return Card(
      key: const Key('background-banner'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.battery_alert_outlined),
                SizedBox(width: 12),
                Expanded(child: Text('Let Harvey run in the background')),
              ],
            ),
            const SizedBox(height: 4),
            const Text('Battery saving on some phones stops medicine reminders.'),
            Wrap(
              alignment: WrapAlignment.end,
              children: [
                TextButton(
                  key: const Key('background-not-now'),
                  onPressed: () async {
                    await access.dismiss();
                    ref.invalidate(backgroundPromptProvider);
                  },
                  child: const Text('Not now'),
                ),
                TextButton(
                  key: const Key('background-phone-settings'),
                  onPressed: () => _phoneSteps(context, ref),
                  child: const Text('Phone settings'),
                ),
                FilledButton.tonal(
                  key: const Key('background-allow'),
                  onPressed: () async {
                    await access.request();
                    ref.invalidate(backgroundPromptProvider);
                  },
                  child: const Text('Allow'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// D-91: one medicine of a prescription's text ("Felodipine 5mg 1 tablet, once daily x30"):
/// the name with its strength, and the rest (dose, how often, quantity).
typedef RxLine = ({String name, String detail});

final _strength = RegExp(
  r'^(.*?\d+(?:\.\d+)?\s?(?:mg|mcg|g|ml|iu|units?|%))(?=\s|,|$)(.*)$',
  caseSensitive: false,
);

List<RxLine> prescriptionLines(String details) => [
  for (final part in details.split(';'))
    if (part.trim().isNotEmpty) _line(part.trim()),
];

RxLine _line(String text) {
  final m = _strength.firstMatch(text);
  if (m != null) {
    final rest = m.group(2)!.trim().replaceFirst(RegExp(r'^,\s*'), '');
    return (
      name: m.group(1)!.trim(),
      detail: rest.replaceAllMapped(RegExp(r'\bx(\d+)\b'), (q) => '×${q.group(1)}'),
    );
  }
  final comma = text.indexOf(',');
  return comma < 0
      ? (name: text, detail: '')
      : (name: text.substring(0, comma).trim(), detail: text.substring(comma + 1).trim());
}

/// D-49/D-50: a prescription (doctor-issued blue, patient-reported green) that the
/// patient can copy into their reminders; their own ones open for editing.
/// D-91: collapsed to the medicine names; tap to see one row per medicine.
class _PrescriptionTile extends StatefulWidget {
  const _PrescriptionTile({required this.prescription, required this.tracked});

  final Prescription prescription;
  final bool tracked;

  @override
  State<_PrescriptionTile> createState() => _PrescriptionTileState();
}

class _PrescriptionTileState extends State<_PrescriptionTile> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.prescription;
    final issued = toMyt(p.issuedAt);
    final color = prescriptionColor(p);
    final theme = Theme.of(context);
    final lines = prescriptionLines(p.medicationDetails);
    final count = lines.length;
    return Card(
      key: Key('rx-${p.id}'),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: color, width: 1.5),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _open = !_open),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 4, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    backgroundColor: color.withValues(alpha: 0.15),
                    child: Icon(
                      p.byPatient ? Icons.edit_note : Icons.receipt_long_outlined,
                      color: color,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          count <= 1
                              ? (lines.isEmpty ? p.medicationDetails : lines.first.name)
                              : '$count medicines',
                          style: theme.textTheme.titleMedium,
                        ),
                        if (!_open && count > 1)
                          Text(
                            lines.map((l) => l.name).join(' · '),
                            key: Key('rx-names-${p.id}'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        if (!_open && count == 1 && lines.first.detail.isNotEmpty)
                          Text(lines.first.detail, key: Key('rx-detail-${p.id}')),
                        const SizedBox(height: 2),
                        Text(
                          '${p.byPatient ? 'Recorded' : 'Prescribed'} ${issued.day} '
                          '${_months[issued.month - 1]} ${issued.year}'
                          '${p.isRecurring ? ' • repeats monthly' : ''}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: Key('rx-expand-${p.id}'),
                    tooltip: _open ? 'Show less' : 'Show details',
                    onPressed: () => setState(() => _open = !_open),
                    icon: Icon(_open ? Icons.expand_less : Icons.expand_more),
                  ),
                ],
              ),
              if (_open) ...[
                const SizedBox(height: 8),
                for (final (i, l) in lines.indexed)
                  Container(
                    key: Key('rx-line-${p.id}-$i'),
                    margin: const EdgeInsets.only(left: 52, right: 8, bottom: 6),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.07),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.medication_outlined, size: 20, color: color),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l.name,
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (l.detail.isNotEmpty)
                                Text(l.detail, style: theme.textTheme.bodyMedium),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                if (p.byPatient)
                  Padding(
                    padding: const EdgeInsets.only(left: 52),
                    child: TextButton.icon(
                      key: Key('rx-edit-${p.id}'),
                      onPressed: () => context.push('/medications/prescription', extra: p),
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: const Text('Edit'),
                    ),
                  ),
              ],
              // Chip left, action right; on narrow phones the action wraps below.
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: SizedBox(
                  width: double.infinity,
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    children: [
                      PrescriptionSourceChip(prescription: p, forDoctor: false),
                      if (widget.tracked)
                        const Chip(label: Text('On your list'))
                      else
                        TextButton.icon(
                          key: Key('rx-add-${p.id}'),
                          onPressed: () => context.push(
                            '/medications/add',
                            extra: draftFromPrescription(p.medicationDetails),
                          ),
                          icon: const Icon(Icons.alarm_add_outlined, size: 18),
                          label: const Text('Add to my reminders'),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({super.key, required this.icon, required this.text, this.action});

  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48),
          const SizedBox(height: 12),
          Text(text, textAlign: TextAlign.center),
          ?action,
        ],
      ),
    ),
  );
}

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec', //
];

String _clock(DateTime instant) {
  final l = toMyt(instant);
  return DoseTime(l.hour, l.minute).label;
}

class _ScheduleHeader extends StatelessWidget {
  const _ScheduleHeader({required this.now});

  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final l = toMyt(now);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(child: Text("Today's Schedule", style: theme.textTheme.titleMedium)),
          Text(
            '${_weekdays[l.weekday - 1]}, ${_months[l.month - 1]} ${l.day}',
            style: TextStyle(color: theme.colorScheme.primary),
          ),
        ],
      ),
    );
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.doses});

  final List<ScheduledDose> doses;

  @override
  Widget build(BuildContext context) {
    final taken = doses.where((d) => d.state == DoseState.taken).length;
    final left = doses.length - taken;
    final scheme = Theme.of(context).colorScheme;
    final total = doses.length;
    final (headline, detail) = left == 0
        ? ('All done for today', 'Every dose is taken. Well done!')
        : taken == 0
        ? ("Today's doses", '$left ${left == 1 ? 'dose' : 'doses'} to take today.')
        : ('Great progress!', '$left ${left == 1 ? 'dose' : 'doses'} left for today.');
    // D-99: the next dose still to take.
    final next = doses
        .where((d) => d.state == DoseState.due || d.state == DoseState.upcoming)
        .fold<ScheduledDose?>(null, (a, d) => a == null || d.moment.isBefore(a.moment) ? d : a);
    final missed = doses.where((d) => d.state == DoseState.missed).length;
    final colors = left == 0
        ? [Colors.green.shade500, Colors.teal.shade400]
        : [scheme.primary, Colors.blue.shade400];
    return Container(
      key: const Key('meds-progress'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          colors: colors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: colors.first.withValues(alpha: 0.3),
            blurRadius: 12,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 72,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox.expand(
                  child: CircularProgressIndicator(
                    value: total == 0 ? 0 : taken / total,
                    strokeWidth: 7,
                    strokeCap: StrokeCap.round,
                    backgroundColor: Colors.white.withValues(alpha: 0.25),
                    valueColor: const AlwaysStoppedAnimation(Colors.white),
                  ),
                ),
                Text(
                  '$taken/$total',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  headline,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(detail, style: const TextStyle(color: Colors.white)),
                if (next != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    key: const Key('meds-next-dose'),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'Next: ${next.medication.name} at ${next.time.label}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
                if (missed > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '$missed missed today',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// D-77: one colour per time of day, so doses are easy to tell apart.
Color periodColor(DosePeriod p) => switch (p) {
  DosePeriod.morning => Colors.amber.shade700,
  DosePeriod.afternoon => Colors.deepOrange.shade400,
  DosePeriod.evening => Colors.indigo.shade400,
  DosePeriod.asNeeded => Colors.teal.shade500,
};

class _PeriodHeader extends StatelessWidget {
  const _PeriodHeader({required this.period});

  final DosePeriod period;

  @override
  Widget build(BuildContext context) {
    final icon = switch (period) {
      DosePeriod.morning => Icons.wb_sunny_outlined,
      DosePeriod.afternoon => Icons.wb_cloudy_outlined,
      DosePeriod.evening => Icons.nightlight_outlined,
      DosePeriod.asNeeded => Icons.water_drop_outlined,
    };
    final color = periodColor(period);
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Container(
        key: Key('period-${period.name}'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            Text(
              period.label.toUpperCase(),
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(color: color, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }
}

class _DoseTile extends StatelessWidget {
  const _DoseTile({required this.dose, required this.busy, required this.onTake});

  final ScheduledDose dose;
  final bool busy;
  final VoidCallback onTake;

  @override
  Widget build(BuildContext context) {
    final med = dose.medication;
    final scheme = Theme.of(context).colorScheme;
    final taken = dose.state == DoseState.taken;
    final Widget? trailing = switch (dose.state) {
      // The taken time sits under the dose (below) so the name keeps its full width.
      DoseState.taken => null,
      // D-49: a missed dose can still be recorded as taken late until midnight.
      DoseState.missed =>
        busy
            ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator())
            : OutlinedButton(
                key: Key('late-${med.id}-${dose.time.hhmm}'),
                style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
                onPressed: onTake,
                child: const Text('Took it late'),
              ),
      DoseState.upcoming => const Text('Upcoming'),
      DoseState.due =>
        busy
            ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator())
            : FilledButton(
                key: Key('take-${med.id}-${dose.time.hhmm}'),
                onPressed: onTake,
                child: const Text('Take'),
              ),
    };
    final color = periodColor(DosePeriod.of(dose.time));
    return Card(
      key: Key('dose-${med.id}-${dose.time.hhmm}'),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: color.withValues(alpha: 0.6)),
      ),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.15),
          foregroundColor: color,
          child: Icon(taken ? Icons.check_circle : Icons.medication_outlined),
        ),
        title: Text(
          med.name,
          style: taken ? const TextStyle(decoration: TextDecoration.lineThrough) : null,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${med.dosage} • ${dose.time.label}'
              '${dose.state == DoseState.missed ? ' • Missed' : ''}',
            ),
            if (med.fromDoctor) // D-69: set by the doctor (locked)
              Text(
                'From ${med.prescribedBy ?? 'your doctor'}',
                key: Key('from-doctor-${med.id}'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (taken)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  dose.confirmedAt == null
                      ? 'Taken'
                      : '${dose.isLate ? 'Taken late' : 'Taken'} at ${_clock(dose.confirmedAt!)}',
                  key: Key('taken-${med.id}-${dose.time.hhmm}'),
                  style: TextStyle(
                    color: dose.isLate ? Colors.orange.shade800 : scheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
        trailing: trailing,
      ),
    );
  }
}

class _AsNeededTile extends ConsumerWidget {
  const _AsNeededTile({required this.med, required this.busy, required this.onLog});

  final Medication med;
  final bool busy;
  final VoidCallback onLog;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logs = ref.watch(todaysDoseLogsProvider(med.id)).value ?? const <DoseLog>[];
    final last = logs.isEmpty ? null : logs.first.confirmedAt ?? logs.first.scheduledTime;
    return Card(
      key: Key('prn-${med.id}'),
      child: ListTile(
        leading: const CircleAvatar(child: Icon(Icons.healing_outlined)),
        title: Text(med.name),
        subtitle: Text(
          last == null
              ? med.dosage
              : '${med.dosage} • taken ${logs.length}× today, last at ${_clock(last)}',
        ),
        trailing: busy
            ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator())
            : FilledButton.tonal(
                key: Key('log-${med.id}'),
                onPressed: onLog,
                child: const Text('Log dose'),
              ),
      ),
    );
  }
}

class _RefillCard extends ConsumerWidget {
  const _RefillCard({required this.med});

  final Medication med;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final days = daysOfSupply(med)!.floor();
    final doctorId = ref.watch(currentUserProvider).value?.assignedDoctorId;
    return Card(
      key: Key('refill-${med.id}'),
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Refill required\n${med.name} (${med.dosage})',
                    style: TextStyle(color: scheme.onErrorContainer),
                  ),
                ),
                Chip(label: Text(days == 1 ? '1 day left' : '$days days left')),
              ],
            ),
            const SizedBox(height: 12),
            // Until Module 13 (pharmacy orders), a refill request goes to the doctor (D-43).
            FilledButton(
              key: Key('request-refill-${med.id}'),
              style: FilledButton.styleFrom(backgroundColor: scheme.error),
              onPressed: doctorId == null || doctorId.trim().isEmpty
                  ? () => ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'No doctor is assigned to you yet, so a refill '
                          'cannot be requested in the app.',
                        ),
                      ),
                    )
                  : () => context.push(
                      '/chat/${doctorId.trim()}',
                      extra:
                          'Hello doctor, I am running low on ${med.name} ${med.dosage} '
                          '(about $days days left). Could you please renew my prescription?',
                    ),
              child: const Text('Request refill from doctor'),
            ),
          ],
        ),
      ),
    );
  }
}

/// D-99: one medicine: name and dose, its reminder times, adherence as a bar, doses
/// left and who prescribed it. Tap to open it (details for doctor medicines, D-90).
class _MedicineTile extends StatelessWidget {
  const _MedicineTile({required this.med});

  final Medication med;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final times = tryParseSchedule(med.schedule);
    final rate = med.adherenceRate;
    final rateColor = rate == null
        ? scheme.outline
        : rate >= 80
        ? Colors.green.shade600
        : rate >= 50
        ? Colors.orange.shade700
        : Colors.red.shade600;
    final accent = med.fromDoctor ? scheme.primary : Colors.teal.shade600;
    final left = med.quantityOnHand;
    return Card(
      key: Key('medicine-${med.id}'),
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        onTap: () => context.push('/medications/edit', extra: med),
        child: Container(
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: accent, width: 5)),
          ),
          padding: const EdgeInsets.fromLTRB(14, 14, 8, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(Icons.medication, color: accent),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          med.name,
                          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          med.fromDoctor
                              ? '${med.dosage} · from ${med.prescribedBy ?? 'your doctor'}'
                              : med.dosage,
                          style: theme.textTheme.bodyMedium?.copyWith(color: scheme.outline),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    med.fromDoctor ? Icons.chevron_right : Icons.edit_outlined,
                    color: scheme.outline,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (times == null)
                    _Pill(icon: Icons.water_drop_outlined, text: 'As needed', color: Colors.teal)
                  else
                    for (final t in times)
                      _Pill(icon: Icons.alarm, text: t.label, color: periodColor(DosePeriod.of(t))),
                  if (left != null)
                    _Pill(
                      icon: Icons.inventory_2_outlined,
                      text: '${left.toStringAsFixed(0)} left',
                      color: needsRefill(med) ? Colors.red : Colors.blueGrey,
                    ),
                ],
              ),
              if (times != null) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Text('Adherence (30 days)', style: theme.textTheme.bodySmall),
                    const Spacer(),
                    Text(
                      rate == null ? 'No history yet' : '${rate.toStringAsFixed(0)}%',
                      key: Key('adherence-${med.id}'),
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: rateColor,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                ),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: (rate ?? 0) / 100,
                      minHeight: 7,
                      color: rateColor,
                      backgroundColor: rateColor.withValues(alpha: 0.15),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.text, required this.color});
  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(
          text,
          style: TextStyle(color: color, fontSize: 12.5, fontWeight: FontWeight.w600),
        ),
      ],
    ),
  );
}
