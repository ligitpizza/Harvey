import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hypertension/features/leave/leave_pages.dart';
import 'package:hypertension/features/walk_in/walk_in_page.dart';
import 'package:hypertension/shared/providers/api_providers.dart';
import 'package:hypertension/shared/services/api/api_client.dart';

import '../helpers/fakes.dart';

// D-80: staff leave and walk-in bookings.

String iso(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

final soon = DateTime.now().add(const Duration(days: 7));

class D80Api extends FakeApiClient {
  final calls = <String>[];
  List<Map<String, dynamic>> leave = [];
  List<Map<String, dynamic>> toMove = [];
  Object? bookError;

  @override
  Future<Map<String, dynamic>> leaveRequests() async => {'leave': leave};

  @override
  Future<Map<String, dynamic>> leaveReschedule() async => {'appointments': toMove};

  @override
  Future<Map<String, dynamic>> applyLeave(String startDate, String endDate, String reason) async {
    calls.add('apply:$startDate:$endDate:$reason');
    return {'id': 'l9'};
  }

  @override
  Future<Map<String, dynamic>> cancelLeave(String id) async {
    calls.add('cancel:$id');
    return {'status': 'cancelled'};
  }

  @override
  Future<Map<String, dynamic>> decideLeave(String id, String decision, {String? note}) async {
    calls.add('decide:$id:$decision:${note ?? ''}');
    return {'status': decision == 'approve' ? 'approved' : 'rejected', 'flaggedAppointments': 2};
  }

  @override
  Future<Map<String, dynamic>> findWalkInPatients(String q) async => {
    'patients': [
      {
        'id': 'p1',
        'name': 'Siti Aminah',
        'email': 'siti@x.my',
        'icLast4': '5678',
        'doctorId': 'd1',
        'doctorName': 'Dr John',
      },
    ],
  };

  @override
  Future<Map<String, dynamic>> walkInDoctors() async => {
    'workingDay': true,
    'doctors': [
      {
        'id': 'd1',
        'name': 'Dr John',
        'onLeave': false,
        'patients': 3,
        'maxPatients': 30,
        'slots': [
          {'time': '2026-11-05T03:00:00+00:00', 'period': 'morning'},
          {'time': '2026-11-05T03:30:00+00:00', 'period': 'morning'},
        ],
      },
    ],
  };

  @override
  Future<Map<String, dynamic>> bookWalkIn({
    required String patientId,
    required String doctorId,
    required String dateTime,
    required String type,
  }) async {
    if (bookError != null) throw bookError!;
    calls.add('book:$patientId:$doctorId:$dateTime:$type');
    return {'id': 'a1'};
  }
}

Map<String, dynamic> leaveJson(String id, String status, {int? affected, String role = 'doctor'}) =>
    {
      'id': id,
      'staffName': 'Dr John',
      'staffRole': role,
      'startDate': iso(soon),
      'endDate': iso(soon.add(const Duration(days: 1))),
      'days': 2,
      'reason': 'Conference',
      'status': status,
      'affectedAppointments': ?affected,
    };

late D80Api api;

Future<void> pump(WidgetTester t, Widget page) async {
  t.view.physicalSize = const Size(1300, 1400);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: MaterialApp(home: Scaffold(body: page)),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  setUp(() => api = D80Api());

  group('staff leave', () {
    testWidgets('my leave lists requests with their clash count and can be cancelled', (t) async {
      api.leave = [leaveJson('l1', 'pending', affected: 3)];
      await pump(t, const StaffLeavePage());
      expect(find.text('Pending'), findsOneWidget);
      expect(find.byKey(const Key('leave-clash-l1')), findsOneWidget);
      expect(find.textContaining('3 booked appointment(s)'), findsOneWidget);
      await t.tap(find.byKey(const Key('cancel-leave-l1')));
      await t.pumpAndSettle();
      await t.tap(find.text('Cancel leave').last);
      await t.pumpAndSettle();
      expect(api.calls, ['cancel:l1']);
    });

    testWidgets('apply needs dates and a reason', (t) async {
      await pump(t, const StaffLeavePage());
      expect(find.byKey(const Key('leave-empty')), findsOneWidget);
      await t.tap(find.byKey(const Key('apply-leave')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('leave-submit')));
      await t.pumpAndSettle();
      expect(find.text('Choose the leave dates.'), findsOneWidget);
      expect(api.calls, isEmpty);
    });

    testWidgets('admin approves with a note and sees appointments to move', (t) async {
      api.leave = [
        leaveJson('l1', 'pending', affected: 2),
        leaveJson('l2', 'approved', role: 'pharmacist'),
      ];
      api.toMove = [
        {
          'id': 'a1',
          'patientId': 'p1',
          'patientName': 'Siti',
          'doctorId': 'd1',
          'doctorName': 'Dr John',
          'dateTime': '2026-11-12T02:00:00+00:00',
          'type': 'checkup',
        },
      ];
      await pump(t, const AdminLeavePage());
      expect(find.byKey(const Key('move-a1')), findsOneWidget);
      expect(find.textContaining('Dr John is on leave'), findsOneWidget);
      // Waiting for a decision, and decided leave kept as history.
      expect(find.byKey(const Key('leave-l1')), findsOneWidget);
      expect(find.byKey(const Key('approve-l1')), findsOneWidget);
      expect(find.byKey(const Key('leave-l2')), findsOneWidget);
      expect(find.byKey(const Key('approve-l2')), findsNothing);
      expect(find.text('History (1)'), findsOneWidget);
      await t.tap(find.byKey(const Key('approve-l1')));
      await t.pumpAndSettle();
      expect(find.textContaining('2 appointment(s) will be flagged'), findsOneWidget);
      await t.enterText(find.byKey(const Key('leave-note')), 'Enjoy');
      await t.tap(find.byKey(const Key('leave-confirm')));
      await t.pumpAndSettle();
      expect(api.calls, ['decide:l1:approve:Enjoy']);
      expect(find.textContaining('2 appointment(s) to reschedule'), findsOneWidget);
      await t.tap(find.byKey(const Key('history-rejected')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('leave-l2')), findsNothing);
      expect(find.byKey(const Key('leave-history-empty')), findsOneWidget);
    });
  });

  group('walk-in', () {
    testWidgets('find a patient, pick their doctor\'s slot and book', (t) async {
      await pump(t, const WalkInPage());
      await t.enterText(find.byKey(const Key('walk-in-search')), 'siti');
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('walk-in-result-p1')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('walk-in-patient')), findsOneWidget);
      expect(find.textContaining('IC …5678'), findsOneWidget);
      // Their doctor is preselected; no doctor dropdown.
      expect(find.byKey(const Key('walk-in-doctor')), findsNothing);
      await t.tap(find.byKey(const Key('walk-in-slot-2026-11-05T03:30:00.000Z')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('walk-in-type-follow_up')));
      await t.tap(find.byKey(const Key('walk-in-book')));
      await t.pumpAndSettle();
      expect(api.calls, ['book:p1:d1:2026-11-05T03:30:00.000Z:follow_up']);
      expect(find.byKey(const Key('walk-in-done')), findsOneWidget);
    });

    testWidgets('a slot taken meanwhile shows the reason', (t) async {
      api.bookError = ApiException('SLOT_TAKEN', 'That slot was just taken. Choose another.');
      await pump(t, const WalkInPage());
      await t.enterText(find.byKey(const Key('walk-in-search')), 'siti');
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('walk-in-result-p1')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('walk-in-slot-2026-11-05T03:00:00.000Z')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('walk-in-book')));
      await t.pumpAndSettle();
      expect(find.text('That slot was just taken. Choose another.'), findsOneWidget);
    });

    testWidgets('new patient form checks the IC before sending', (t) async {
      await pump(t, const WalkInPage());
      await t.tap(find.byKey(const Key('walk-in-register')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('walk-in-name')), 'Mei Ling');
      await t.enterText(find.byKey(const Key('walk-in-email')), 'mei@x.my');
      await t.enterText(find.byKey(const Key('walk-in-ic')), '1234');
      await t.tap(find.byKey(const Key('walk-in-save')));
      await t.pumpAndSettle();
      expect(find.text('Enter the 12-digit IC number.'), findsOneWidget);
    });
  });

  test('D-80 approved leave becomes calendar labels per day', () {
    final all = [
      LeaveRequest.fromJson({...leaveJson('l1', 'approved'), 'staffId': 'd1'}),
      LeaveRequest.fromJson({...leaveJson('l2', 'pending'), 'staffId': 'd1'}),
      LeaveRequest.fromJson({...leaveJson('l3', 'approved', role: 'pharmacist'), 'staffId': 'ph1'}),
    ];
    final day = DateTime(soon.year, soon.month, soon.day);
    final next = day.add(const Duration(days: 1));
    final admin = leaveByDay(all, admin: true);
    expect(admin[day], ['Dr John on leave', 'Dr John on leave (pharmacy)']);
    expect(admin[next]?.length, 2);
    expect(leaveByDay(all, admin: true, onlyStaffId: 'd1')[day], ['Dr John on leave']);
    expect(leaveByDay(all, admin: false, onlyStaffId: 'd1')[day], ['On leave']);
  });
}
