import 'package:flutter/material.dart';
import '../../../shared/widgets/structured_text.dart';
import 'alert_detail_page.dart' show openAlert;
import '../../symptom_checker/presentation/triage_result_page.dart' show TriageResultLoader;
import '../../vitals/presentation/reading_detail_page.dart' show openReading;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../records/presentation/shared_records_tab.dart';
import '../../../core/constants/enums.dart';
import '../../../core/utils/bp_classifier.dart';
import '../../../core/utils/risk_style.dart';
import '../../../shared/models/health_models.dart';
import '../../charts/domain/trend_logic.dart';
import '../../charts/presentation/bp_trend_chart.dart';
import '../../charts/presentation/risk_trend_card.dart' show complicationNames;
import '../../charts/state/trends_providers.dart';
import '../../dashboard/state/dashboard_providers.dart';
import '../../medications/domain/med_schedule.dart';
import '../domain/portal_logic.dart';
import '../domain/portal_models.dart';
import '../../symptom_checker/data/symptom_repository.dart';
import '../../symptom_checker/state/symptom_providers.dart';
import '../state/portal_providers.dart';
import '../../appointments/domain/appointment_text.dart' show dateLabel, timeLabel;
import '../../appointments/presentation/appointment_details_dialog.dart';
import '../../appointments/presentation/cover_labels.dart';
import '../../auth/state/auth_providers.dart';
import '../../appointments/presentation/reassignment_dialog.dart';
import '../../appointments/state/appointment_providers.dart';
import 'dose_history.dart';
import 'medication_effect_card.dart';
import 'portal_prescription_tile.dart';
import 'portal_widgets.dart';
import '../../../core/utils/ic_number.dart';
import 'delivery_preference_card.dart';
import 'write_report_dialog.dart';

/// Fig 4.3.12.4 Patient Detail (FR-8.2; UC8.3): vitals, risk, BP trend, medications,
/// prescriptions, care plan and clinical notes for one assigned patient.
class PatientDetailPage extends ConsumerStatefulWidget {
  const PatientDetailPage({super.key, required this.patientId});

  final String patientId;

  @override
  ConsumerState<PatientDetailPage> createState() => _PatientDetailPageState();
}

class _PatientDetailPageState extends ConsumerState<PatientDetailPage> {
  TrendRange _range = TrendRange.month;

  String get id => widget.patientId;

  @override
  Widget build(BuildContext context) {
    final patient = ref.watch(portalPatientProvider(id));
    final now = ref.watch(nowProvider)();
    final wide = MediaQuery.sizeOf(context).width >= 1000;

    return patient.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => const _Message(
        'You can only view patients assigned to you, or a patient whose visit you are '
        'covering (from the day before the visit until 7 days after). Check the patient '
        'list and try again.',
      ),
      data: (p) {
        if (p == null) return const _Message('Patient not found.');
        final covering = p.coveredBy(ref.watch(authUidProvider).value); // D-120
        final top = [
          Expanded(child: _VitalsAndRisk(patientId: id)),
          const SizedBox(width: 16, height: 16),
          Expanded(flex: wide ? 2 : 1, child: _trendCard(now)),
        ];
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('back-to-patients'),
                onPressed: () => context.go('/doctor'),
                icon: const Icon(Icons.arrow_back),
                label: const Text('My patients'),
              ),
            ),
            if (covering) ...[_CoverBanner(patient: p), const SizedBox(height: 12)],
            _Header(patient: p, now: now, covering: covering),
            const SizedBox(height: 16),
            if (wide)
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: top)
            else ...[
              _VitalsAndRisk(patientId: id),
              const SizedBox(height: 16),
              _trendCard(now),
            ],
            const SizedBox(height: 16),
            _HistoryTabs(patientId: id),
          ],
        );
      },
    );
  }

  Widget _trendCard(DateTime now) {
    final readings = ref.watch(readingsInRangeProvider((id, _range)));
    return SectionCard(
      title: 'Blood pressure trend',
      trailing: SegmentedButton<TrendRange>(
        showSelectedIcon: false,
        segments: [
          for (final r in [TrendRange.week, TrendRange.month, TrendRange.quarter])
            ButtonSegment(value: r, label: Text(r.label)),
        ],
        selected: {_range},
        onSelectionChanged: (s) => setState(() => _range = s.first),
      ),
      child: AsyncSection(
        value: readings,
        isEmpty: (r) => r.isEmpty,
        emptyText: 'No readings in this period.',
        builder: (r) => SizedBox(
          height: 240,
          child: BpTrendChart(points: buildPoints(r, _range, now), range: _range, now: now),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(text, textAlign: TextAlign.center),
    ),
  );
}

/// D-120: shown to a doctor covering a visit for the patient's own doctor.
class _CoverBanner extends ConsumerWidget {
  const _CoverBanner({required this.patient});

  final PortalPatient patient;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(authUidProvider).value;
    final own = patient.assignedDoctorId == null
        ? null
        : ref.watch(personProvider(patient.assignedDoctorId!)).value?.name;
    final until = me == null ? null : patient.coverAccess[me];
    // The window ends at midnight; show the last full day.
    final last = until?.subtract(const Duration(minutes: 1));
    final color = Colors.indigo.shade600;
    return Container(
      key: const Key('cover-banner'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.swap_horiz, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              "You are covering a visit for ${own ?? "the patient's own doctor"}. You can read "
              "this patient's records and add clinical notes"
              "${last == null ? '' : ' until ${dateLabel(last)}'}. Your note is shared with "
              "${own ?? 'their doctor'}; prescriptions and the care plan stay with them.",
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.patient, required this.now, this.covering = false});

  final PortalPatient patient;
  final DateTime now;

  /// D-120: a covering doctor only adds notes.
  final bool covering;

  @override
  Widget build(BuildContext context) {
    final age = ageOn(patient.dateOfBirth, now);
    final facts = [
      if (age != null) '$age years',
      if (patient.gender != null) patient.gender![0].toUpperCase() + patient.gender!.substring(1),
      if (patient.icNumber != null) 'MyKad ${maskIc(patient.icNumber)}',
      if (patient.passportNumber != null) // D-103
        'Passport ${maskPassport(patient.passportNumber)}'
            '${patient.nationality == null ? '' : ' (${patient.nationality})'}',
    ].join(' · ');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 16,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            CircleAvatar(
              radius: 28,
              child: Text(patient.name.isEmpty ? '?' : patient.name[0].toUpperCase()),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(patient.name, style: Theme.of(context).textTheme.headlineSmall),
                if (facts.isNotEmpty) Text(facts),
              ],
            ),
            FilledButton.icon(
              key: const Key('action-note'),
              onPressed: () => context.go('/doctor/patient/${patient.uid}/notes'),
              icon: const Icon(Icons.edit_note),
              label: const Text('Add note'),
            ),
            if (!covering) ...[
              OutlinedButton.icon(
                key: const Key('action-prescribe'),
                onPressed: () => context.go('/doctor/patient/${patient.uid}/prescriptions'),
                icon: const Icon(Icons.medication_outlined),
                label: const Text('Prescribe'),
              ),
              // D-100: a written report saved to the patient's Records as a PDF.
              OutlinedButton.icon(
                key: const Key('action-report'),
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  if (await showWriteReport(context, patient.uid, patient.name)) {
                    messenger.showSnackBar(
                      const SnackBar(
                        content: Text(
                          "Report saved to the patient's Records. You'll find it under Records.",
                        ),
                      ),
                    );
                  }
                },
                icon: const Icon(Icons.assignment_ind_outlined),
                label: const Text('Write report'),
              ),
              OutlinedButton.icon(
                key: const Key('action-care-plan'),
                onPressed: () => context.go('/doctor/patient/${patient.uid}/care-plan'),
                icon: const Icon(Icons.assignment_outlined),
                label: const Text('Care plan'),
              ),
              // D-54: hand this patient to another doctor (the admin decides).
              TextButton.icon(
                key: const Key('action-reassign'),
                onPressed: () => requestReassignment(context, patient.uid, patient.name),
                icon: const Icon(Icons.swap_horiz),
                label: const Text('Request reassignment'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Latest BP and the current risk score with each complication (FR-9.2, FR-9.3).
class _VitalsAndRisk extends ConsumerWidget {
  const _VitalsAndRisk({required this.patientId});

  final String patientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reading = ref.watch(patientLatestReadingProvider(patientId));
    final risk = ref.watch(patientLatestRiskProvider(patientId));
    final level = risk.value?.overallLevel;
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: level == null ? Colors.transparent : riskColor(level), width: 2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Latest reading', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            AsyncSection<VitalReading?>(
              value: reading,
              isEmpty: (r) => r == null,
              emptyText: 'No readings yet.',
              builder: (r) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  BpText(
                    key: const Key('detail-latest-bp'),
                    reading: r,
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  Text(
                    '${BpClassifier.label(BpClassifier.classify(r!.systolic, r.diastolic))} · '
                    '${formatDate(r.timestamp)}',
                  ),
                  if (r.heartRate != null) Text('Heart rate ${r.heartRate} bpm (camera estimate)'),
                ],
              ),
            ),
            const Divider(height: 24),
            Row(
              children: [
                Expanded(
                  child: Text('Risk assessment', style: Theme.of(context).textTheme.titleMedium),
                ),
                RiskChip(level: level),
              ],
            ),
            AsyncSection<RiskScore?>(
              value: risk,
              isEmpty: (s) => s == null,
              emptyText: 'No risk score yet (needs three readings).',
              builder: (s) => _RiskList(score: s!),
            ),
          ],
        ),
      ),
    );
  }
}

/// Tabs for the rest of the record (UC8.3 E1: each tab has its own empty state).
class _HistoryTabs extends ConsumerWidget {
  const _HistoryTabs({required this.patientId});

  final String patientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final readings = ref.watch(patientReadingsProvider(patientId));
    final meds = ref.watch(patientMedicationsProvider(patientId));
    final rx = ref.watch(patientPrescriptionsProvider(patientId));
    final plan = ref.watch(patientCarePlanProvider(patientId));
    final notes = ref.watch(patientNotesProvider(patientId));
    final alerts = ref.watch(patientAlertsProvider(patientId));
    final triage = ref.watch(patientTriageProvider(patientId));

    final appts = ref.watch(patientAppointmentHistoryProvider(patientId)); // D-82

    return DefaultTabController(
      length: 7,
      child: Card(
        child: Column(
          children: [
            const TabBar(
              isScrollable: true,
              tabs: [
                Tab(text: 'Vitals'),
                Tab(text: 'Medications'),
                Tab(text: 'Care plan'),
                Tab(text: 'Clinical notes'),
                Tab(text: 'Alerts & triage'),
                Tab(text: 'Records'),
                Tab(text: 'Appointments'),
              ],
            ),
            SizedBox(
              height: 360,
              child: TabBarView(
                children: [
                  _pad(
                    AsyncSection(
                      value: readings,
                      isEmpty: (r) => r.isEmpty,
                      emptyText: 'No readings recorded yet.',
                      builder: (r) => ListView(
                        children: [
                          for (final x in r)
                            ListTile(
                              key: Key('doctor-reading-${x.id}'),
                              dense: true,
                              // D-110: the reading in full, with its symptom check.
                              onTap: () => openReading(context, x, staff: true),
                              trailing: const Icon(Icons.chevron_right),
                              title: BpText(reading: x),
                              subtitle: Text(
                                [
                                  formatDate(x.timestamp),
                                  if (x.heartRate != null) 'HR ${x.heartRate} (estimate)',
                                  if (x.note != null) x.note!,
                                ].join(' · '),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  _pad(
                    ListView(
                      children: [
                        DeliveryPreferenceCard(patientId: patientId),
                        Text(
                          'Patient medication list',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        AsyncSection(
                          value: meds,
                          isEmpty: (m) => m.isEmpty,
                          emptyText: 'The patient has not added any medications.',
                          builder: (m) => Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // Lowest adherence first, so problems are at the top.
                              for (final x
                                  in [...m]..sort(
                                    (a, b) =>
                                        (a.adherenceRate ?? 101).compareTo(b.adherenceRate ?? 101),
                                  ))
                                _MedicineCard(medication: x),
                              const Padding(padding: EdgeInsets.only(top: 4), child: DoseLegend()),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        MedicationEffectCard(patientId: patientId),
                        const SizedBox(height: 12),
                        Text('Prescriptions', style: Theme.of(context).textTheme.titleSmall),
                        AsyncSection(
                          value: rx,
                          isEmpty: (p) => p.isEmpty,
                          emptyText: 'No prescriptions issued yet.',
                          builder: (p) => Column(
                            children: [
                              for (final x in p)
                                PortalPrescriptionTile(prescription: x, patientId: patientId),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  _pad(
                    AsyncSection<CarePlan?>(
                      value: plan,
                      isEmpty: (p) => p == null,
                      emptyText: 'No care plan yet. Use "Care plan" above to write one.',
                      builder: (p) => ListView(
                        children: [
                          Card(
                            key: const Key('care-plan-current'),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(
                                        Icons.assignment_outlined,
                                        size: 18,
                                        color: Theme.of(context).colorScheme.primary,
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          'Updated ${formatDate(p!.updatedAt)}',
                                          style: Theme.of(context).textTheme.labelLarge,
                                        ),
                                      ),
                                      const _Tag('Current'),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  StructuredText(p.content),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  _pad(NotesList(notes: notes)),
                  _pad(_AlertHistory(alerts: alerts, triage: triage)),
                  _pad(SharedRecordsTab(patientId: patientId)),
                  _pad(
                    AsyncSection(
                      value: appts,
                      isEmpty: (a) => a.isEmpty,
                      emptyText: 'No past appointments.',
                      builder: (a) => AppointmentHistoryList(
                        appointments: a,
                        onOpen: (x) => showAppointmentDetails(context, x),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pad(Widget child) => Padding(padding: const EdgeInsets.all(16), child: child);
}

/// Past notes, newest first (also shown under the editor after saving, Fig 4.3.12.6).
class NotesList extends ConsumerWidget {
  const NotesList({super.key, required this.notes, this.shrinkWrap = false});

  final AsyncValue<List<ClinicalNote>> notes;
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(authUidProvider).value;
    // D-120: a note written by another doctor (e.g. while covering) says who wrote it.
    String? author(ClinicalNote n) => n.doctorId == null || n.doctorId == me
        ? null
        : 'by ${ref.watch(personProvider(n.doctorId!)).value?.name ?? 'another doctor'}';
    return _notes(context, author);
  }

  Widget _notes(BuildContext context, String? Function(ClinicalNote) author) => AsyncSection(
    value: notes,
    isEmpty: (n) => n.isEmpty,
    emptyText: 'No clinical notes yet.',
    builder: (n) => ListView.builder(
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      itemCount: n.length,
      itemBuilder: (_, i) => Card(
        key: Key('note-${n[i].id}'),
        margin: const EdgeInsets.symmetric(vertical: 4),
        clipBehavior: Clip.antiAlias,
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: i == 0
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.outlineVariant,
                width: 4,
              ),
            ),
          ),
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.edit_note, size: 18, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      formatDate(n[i].createdAt),
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                  if (author(n[i]) case final by?)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Text(
                        by,
                        key: Key('note-author-${n[i].id}'),
                        style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: Colors.indigo.shade600,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  if (i == 0) const _Tag('Latest'),
                ],
              ),
              const SizedBox(height: 8),
              StructuredText(n[i].content),
            ],
          ),
        ),
      ),
    ),
  );
}

/// D-37: the patient's alert and symptom-check history ("full event logged to the record").
class _AlertHistory extends StatelessWidget {
  const _AlertHistory({required this.alerts, required this.triage});

  final AsyncValue<List<ClinicalAlert>> alerts;
  final AsyncValue<List<TriageRecord>> triage;

  static String _outcome(TriageOutcome o) => switch (o) {
    TriageOutcome.seekEmergencyCare => 'Seek emergency care',
    TriageOutcome.contactDoctor => 'Contact doctor',
    TriageOutcome.monitorAtHome => 'Monitor at home',
  };

  @override
  Widget build(BuildContext context) => ListView(
    children: [
      Text('Alerts', style: Theme.of(context).textTheme.titleSmall),
      AsyncSection(
        value: alerts,
        isEmpty: (a) => a.isEmpty,
        emptyText: 'No alerts for this patient.',
        builder: (a) => Column(
          children: [
            for (final x in a)
              ListTile(
                key: Key('alert-${x.id}'),
                dense: true,
                // Opens the alert in full: trigger, timeline, next steps, actions.
                onTap: () => openAlert(context, x),
                trailing: const Icon(Icons.chevron_right),
                leading: CircleAvatar(radius: 6, backgroundColor: riskColor(x.severity)),
                title: Text('${alertTypeLabel(x.type)} · ${severityWord(x.severity)}'),
                subtitle: Text(
                  '${alertTimeline(x)}\n${x.message}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                isThreeLine: true,
              ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      Text('Symptom checks', style: Theme.of(context).textTheme.titleSmall),
      AsyncSection(
        value: triage,
        isEmpty: (t) => t.isEmpty,
        emptyText: 'No symptom checks yet.',
        builder: (t) => Column(
          children: [
            for (final x in t)
              ListTile(
                key: Key('triage-${x.id}'),
                dense: true,
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => TriageResultLoader(id: x.id, staff: true),
                  ),
                ),
                title: Text('${_outcome(x.outcome)} · ${x.severity.value}'),
                subtitle: Text(
                  '${formatDate(x.generatedAt)} · ${x.symptomIds.map((s) => s.replaceAll('_', ' ')).join(', ')}',
                ),
              ),
          ],
        ),
      ),
    ],
  );
}

/// D-82: past appointments with their outcome (completed, no-show, cancelled…).
class AppointmentHistoryList extends StatelessWidget {
  const AppointmentHistoryList({super.key, required this.appointments, this.onOpen});

  final List<Appointment> appointments;

  /// Opens one appointment's details.
  final ValueChanged<Appointment>? onOpen;

  static (Color, IconData) _style(Appointment a) => switch (a.status) {
    AppointmentStatus.completed => (Colors.green.shade600, Icons.check_circle_outline),
    AppointmentStatus.noShow => (Colors.orange.shade700, Icons.person_off_outlined),
    AppointmentStatus.cancelled => (Colors.grey, Icons.cancel_outlined),
    _ => (Colors.blueGrey, Icons.schedule),
  };

  @override
  Widget build(BuildContext context) => ListView(
    children: [
      for (final a in appointments)
        Builder(
          builder: (context) {
            final (color, icon) = _style(a);
            return ListTile(
              key: Key('history-appt-${a.id}'),
              dense: true,
              // D-85: open the visit (outcome, notes, pre-visit summary), as on the calendar.
              onTap: onOpen == null ? null : () => onOpen!(a),
              trailing: onOpen == null ? null : const Icon(Icons.chevron_right),
              leading: Icon(icon, color: color),
              title: Text('${dateLabel(a.dateTime)}, ${timeLabel(a.dateTime)} · ${a.type.label}'),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (a.isCover)
                    Padding(
                      padding: const EdgeInsets.only(top: 2, bottom: 2),
                      child: CoverTag(appointment: a, forOwnDoctor: true),
                    ),
                  Text(
                    [
                      a.isOverdue(DateTime.now()) ? 'Not completed' : a.status.label,
                      if (a.walkIn) 'Walk-in',
                      if (a.isAdminAssigned) 'Admin assigned',
                      if (a.changeReason != null) a.changeReason!,
                    ].join(' · '),
                  ),
                ],
              ),
            );
          },
        ),
    ],
  );
}

/// Risk assessment, highest first: a coloured level pill and bar per condition. What
/// raised a Moderate-or-higher estimate (D-40) shows as chips under that condition; the
/// explanation sits behind the info icon instead of a paragraph.
class _RiskList extends StatelessWidget {
  const _RiskList({required this.score});

  final RiskScore score;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = [
      for (final c in Complication.values)
        if (score.scores[c] case final v?) (c, v),
    ]..sort((a, b) => b.$2.value.compareTo(a.$2.value));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        for (final (c, v) in rows)
          Padding(
            key: Key('risk-row-${c.value}'),
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        complicationNames[c]!,
                        style: v.level == RiskLevel.low
                            ? theme.textTheme.bodyMedium
                            : theme.textTheme.titleSmall,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: riskColor(v.level).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${riskLabel(v.level)} · ${riskPercent(v.value)}',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: riskColor(v.level),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: v.value.clamp(0.0, 1.0),
                    minHeight: 5,
                    color: riskColor(v.level),
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  ),
                ),
                // D-40 contributing factors, Moderate and above only (Ping 2026-10-14).
                if (v.factors.isNotEmpty && v.level != RiskLevel.low)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Wrap(
                      key: Key('factors-${c.value}'),
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final f in v.factors.take(3))
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              border: Border.all(color: theme.colorScheme.outlineVariant),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(factorLabel(f), style: theme.textTheme.labelSmall),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Text(
                'Scored ${formatDate(score.generatedAt)} · ${modelLabel(score.modelUsed)}',
                style: theme.textTheme.bodySmall,
              ),
            ),
            const Tooltip(
              message:
                  'Chips list the inputs that most raised each estimate for this patient '
                  '(model associations, not proven causes).',
              child: Icon(Icons.info_outline, size: 18),
            ),
          ],
        ),
      ],
    );
  }
}

/// One medicine on the doctor's Medications tab: name, dose and times, who added it,
/// adherence as a coloured badge and bar, the 14-day dots; missed/late doses fold away.
class _MedicineCard extends StatelessWidget {
  const _MedicineCard({required this.medication});

  final Medication medication;

  static Color _rateColor(double r) => r >= 80
      ? Colors.green.shade600
      : r >= 50
      ? Colors.amber.shade800
      : Colors.red.shade600;

  @override
  Widget build(BuildContext context) {
    final m = medication;
    final theme = Theme.of(context);
    final rate = m.adherenceRate;
    final times = describeSchedule(m.schedule);
    return Card(
      key: Key('doctor-med-${m.id}'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        leading: CircleAvatar(
          radius: 18,
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Icon(Icons.medication_outlined, color: theme.colorScheme.primary, size: 20),
        ),
        title: Row(
          children: [
            Expanded(child: Text('${m.name} ${m.dosage}', style: theme.textTheme.titleSmall)),
            if (rate != null)
              Container(
                key: Key('doctor-med-rate-${m.id}'),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: _rateColor(rate).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${rate.round()}% taken',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: _rateColor(rate),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 2),
            Text(
              '$times · ${m.fromDoctor ? 'prescribed' : 'added by the patient'}',
              style: theme.textTheme.bodySmall,
            ),
            if (rate != null) ...[
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: (rate / 100).clamp(0.0, 1.0),
                  minHeight: 5,
                  color: _rateColor(rate),
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                ),
              ),
            ],
            const SizedBox(height: 6),
            DoseHistory(medication: m, showNotable: false),
          ],
        ),
        children: [
          Text('Missed and late doses', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          DoseNotableList(medication: m),
        ],
      ),
    );
  }
}

/// A small rounded label ("Latest", "Current").
class _Tag extends StatelessWidget {
  const _Tag(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onPrimaryContainer),
      ),
    );
  }
}
