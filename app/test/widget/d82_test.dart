import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hypertension/core/constants/enums.dart';
import 'package:hypertension/core/utils/validators.dart';
import 'package:hypertension/features/appointments/presentation/booking_confirmed_page.dart';
import 'package:hypertension/features/appointments/state/appointment_providers.dart';
import 'package:hypertension/features/family/state/family_providers.dart';
import 'package:hypertension/features/provider_portal/presentation/patient_detail_page.dart';
import 'package:hypertension/shared/models/health_models.dart';
import 'package:hypertension/shared/widgets/dose_input.dart';

// D-82: dose = amount + unit, Malaysian mobile numbers, clinic map, appointment history.

void main() {
  group('dose', () {
    test('parse and write like the API', () {
      expect(Dose.parse('5mg').toString(), '5mg');
      expect(Dose.parse('5 MG').toString(), '5mg');
      expect(Dose.parse('2.5 ml').toString(), '2.5ml');
      expect(Dose.parse('1 tablet').toString(), '1 tablet');
      expect(Dose.parse('2 Tablet').toString(), '2 tablets');
      expect(Dose.parse('20mg 1 tablet'), isNull); // older free text
      expect(Dose.parse('abc'), isNull);
      expect(Dose.parse('0 mg'), isNull);
    });

    testWidgets('the amount takes numbers only; the unit comes from the list', (t) async {
      String? value;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DoseField(fieldKey: 'dose', onChanged: (v) => value = v),
          ),
        ),
      );
      await t.enterText(find.byKey(const Key('dose')), '5mg!');
      await t.pump();
      expect(find.text('5'), findsOneWidget); // letters and symbols are dropped
      expect(value, '5mg');
      await t.enterText(find.byKey(const Key('dose')), '2.5');
      await t.tap(find.byKey(const Key('dose-unit')));
      await t.pumpAndSettle();
      await t.tap(find.text('tablet(s)').last);
      await t.pumpAndSettle();
      expect(value, '2.5 tablets');
    });

    testWidgets('an older free-text dose asks to be re-entered', (t) async {
      String? value = 'x';
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DoseField(
              fieldKey: 'dose',
              initial: '20mg 1 tablet',
              onChanged: (v) => value = v,
            ),
          ),
        ),
      );
      await t.pump();
      expect(find.textContaining('Re-enter it'), findsOneWidget);
      expect(value, isNull);
    });
  });

  test('Malaysian mobile numbers', () {
    expect(Validators.normaliseMyPhone('012-345 6789'), '+60123456789');
    expect(Validators.normaliseMyPhone('+60 11-2345 6789'), '+601123456789');
    expect(Validators.phone('03-1234 5678'), Validators.phoneRule);
    expect(Validators.phone('+65 9123 4567'), Validators.phoneRule);
    expect(Validators.phone('0123456789'), isNull);
    expect(Validators.address('Penang'), isNotNull);
    expect(Validators.address('12 Jalan Bukit, 11200 Penang'), isNull);
  });

  testWidgets('the booking page shows the clinic on a map with directions', (t) async {
    final opened = <Uri>[];
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          clinicLocationProvider.overrideWith(
            (ref) async => {
              'name': 'Harvey Hypertension Clinic',
              'address': '77, Lorong Lembah Permai Tiga, 11200 Tanjung Bungah',
              'lat': 5.4587728,
              'lng': 100.2885841,
            },
          ),
          mapBuilderProvider.overrideWithValue((lat, lng, label) => Text('MAP $lat,$lng')),
          openUrlProvider.overrideWithValue((u) async {
            opened.add(u);
            return true;
          }),
        ],
        child: const MaterialApp(home: Scaffold(body: ClinicLocationCard())),
      ),
    );
    await t.pumpAndSettle();
    expect(find.textContaining('Lorong Lembah Permai Tiga'), findsOneWidget);
    expect(find.text('MAP 5.4587728,100.2885841'), findsOneWidget);
    await t.tap(find.byKey(const Key('clinic-directions')));
    expect(opened.single.toString(), contains('destination=5.4587728,100.2885841'));
  });

  testWidgets('appointment history lists past visits with their outcome', (t) async {
    final past = DateTime.utc(2026, 10, 1, 2);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppointmentHistoryList(
            appointments: [
              Appointment(
                id: 'a1',
                patientId: 'p1',
                dateTime: past,
                status: AppointmentStatus.completed,
              ),
              Appointment(
                id: 'a2',
                patientId: 'p1',
                dateTime: past.subtract(const Duration(days: 7)),
                status: AppointmentStatus.noShow,
                walkIn: true,
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('history-appt-a1')), findsOneWidget);
    expect(find.textContaining('Walk-in'), findsOneWidget);
  });
}
