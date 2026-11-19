import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hypertension/core/constants/enums.dart';
import 'package:hypertension/features/appointments/data/appointments_repository.dart';
import 'package:hypertension/features/appointments/presentation/cover_labels.dart';
import 'package:hypertension/features/appointments/state/appointment_providers.dart';
import 'package:hypertension/features/notifications/state/notification_providers.dart';
import 'package:hypertension/features/provider_portal/domain/portal_models.dart';
import 'package:hypertension/shared/models/health_models.dart';

import '../helpers/fakes.dart';
import 'doctor_portal_test.dart' show FakePatientData, FakePortalRepository, portal;

// D-120: a doctor covers one visit for the patient's own doctor.

const names = {'u-doctor': 'Dr John', 'u-own': 'Dr Lim', 'p9': 'Ravi Kumar'};

final peopleOverride = personProvider.overrideWith(
  (ref, uid) async => names[uid] == null ? null : PersonName(uid, names[uid]!),
);

Appointment appt({String? cover, AppointmentStatus status = AppointmentStatus.booked}) =>
    Appointment(
      id: 'a1',
      patientId: 'p9',
      doctorId: 'u-doctor',
      dateTime: DateTime(2026, 10, 14, 10),
      status: status,
      coverForDoctorId: cover,
    );

void main() {
  group('wording', () {
    test('the patient sees who they saw, and whom they covered for', () {
      expect(
        patientDoctorLine(
          appt(cover: 'u-own', status: AppointmentStatus.completed),
          doctor: 'Dr John',
          coverFor: 'Dr Lim',
        ),
        'Consulted with Dr John (covering for Dr Lim)',
      );
      expect(patientDoctorLine(appt(), doctor: 'Dr John'), 'With Dr John');
      expect(
        patientDoctorLine(appt(cover: 'u-own')),
        'With your doctor (covering for your doctor)',
      );
      expect(coveringLabel('Dr Lim'), 'Covering for Dr Lim');
      expect(coveredByLabel('Dr John'), 'Seen by Dr John (cover)');
    });

    test('appointments and patients read the cover fields', () {
      final a = Appointment.fromFirestore('a1', {
        'patientId': 'p9',
        'doctorId': 'u-doctor',
        'dateTime': Timestamp.fromDate(DateTime(2026, 10, 14)),
        'status': 'completed',
        'coverForDoctorId': 'u-own',
      });
      expect(a.isCover, isTrue);
      expect(a.coverForDoctorId, 'u-own');
      final until = DateTime(2026, 10, 22);
      final p = PortalPatient.fromFirestore('p9', {
        'name': 'Ravi',
        'assignedDoctorId': 'u-own',
        'coverAccess': {
          'u-doctor': {
            'from': Timestamp.fromDate(DateTime(2026, 10, 13)),
            'until': Timestamp.fromDate(until),
          },
        },
      });
      expect(p.coveredBy('u-doctor'), isTrue);
      expect(p.coveredBy('u-own'), isFalse); // the own doctor is not "covering"
      expect(p.coverAccess['u-doctor'], until);
    });

    test('the handover notification opens the patient', () {
      expect(
        notificationRoute('cover_handover', {'patientId': 'p9'}, UserRole.doctor),
        '/doctor/patient/p9',
      );
    });
  });

  group('labels', () {
    testWidgets('patient history names the covering doctor', (t) async {
      await t.pumpWidget(
        ProviderScope(
          overrides: [peopleOverride],
          child: MaterialApp(
            home: Scaffold(
              body: AppointmentDoctorLine(
                appointment: appt(cover: 'u-own', status: AppointmentStatus.completed),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('Consulted with Dr John (covering for Dr Lim)'), findsOneWidget);
    });

    testWidgets('staff tags', (t) async {
      await t.pumpWidget(
        ProviderScope(
          overrides: [peopleOverride],
          child: MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  CoverTag(appointment: appt(cover: 'u-own'), forOwnDoctor: false),
                  CoverTag(appointment: appt(cover: 'u-own'), forOwnDoctor: true),
                ],
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('Covering for Dr Lim'), findsOneWidget);
      expect(find.text('Seen by Dr John (cover)'), findsOneWidget);
    });
  });

  group('patient page for a covering doctor', () {
    late FakePortalRepository repo;
    setUp(() {
      repo = FakePortalRepository()
        ..patients = [
          PortalPatient(
            uid: 'p9',
            name: 'Ravi Kumar',
            assignedDoctorId: 'u-own',
            coverAccess: {'u-doctor': DateTime.utc(2026, 10, 21, 16)}, // midnight MYT, 22 Oct
          ),
          const PortalPatient(uid: 'p1', name: 'Siti Aminah', assignedDoctorId: 'u-doctor'),
        ];
    });

    Widget app(String location) =>
        portal(repo, FakePatientData(), location, extra: [peopleOverride]);

    tallTest('shows the cover banner and only the note action', (t) async {
      await t.pumpWidget(app('/doctor/patient/p9'));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('cover-banner')), findsOneWidget);
      expect(find.textContaining('covering a visit for Dr Lim'), findsOneWidget);
      expect(find.textContaining('until Wed 21 Oct'), findsOneWidget); // last full day
      expect(find.byKey(const Key('action-note')), findsOneWidget);
      for (final k in [
        'action-prescribe',
        'action-report',
        'action-care-plan',
        'action-reassign',
      ]) {
        expect(find.byKey(Key(k)), findsNothing, reason: k);
      }
    });

    tallTest("the patient's own doctor sees every action and no banner", (t) async {
      await t.pumpWidget(app('/doctor/patient/p1'));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('cover-banner')), findsNothing);
      expect(find.byKey(const Key('action-prescribe')), findsOneWidget);
      expect(find.byKey(const Key('action-care-plan')), findsOneWidget);
    });

    tallTest("a colleague's note is labelled with their name", (t) async {
      repo.notesList = [
        ClinicalNote(
          id: 'n1',
          content: 'Seen while Dr Lim was on leave.',
          createdAt: DateTime(2026, 10, 13, 10),
          doctorId: 'u-own',
        ),
        ClinicalNote(
          id: 'n2',
          content: 'Mine.',
          createdAt: DateTime(2026, 10, 12),
          doctorId: 'u-doctor',
        ),
      ];
      await t.pumpWidget(app('/doctor/patient/p1'));
      await t.pumpAndSettle();
      await t.tap(find.text('Clinical notes'));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('note-author-n1')), findsOneWidget);
      expect(find.text('by Dr Lim'), findsOneWidget);
      expect(find.byKey(const Key('note-author-n2')), findsNothing); // own note
    });
  });
}
