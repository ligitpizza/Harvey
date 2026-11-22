import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hypertension/core/constants/enums.dart';
import 'package:hypertension/core/utils/validators.dart';
import 'package:hypertension/features/auth/domain/app_user.dart';
import 'package:hypertension/features/auth/presentation/register_page.dart';
import 'package:hypertension/features/auth/state/auth_providers.dart';
import 'package:hypertension/features/notifications/data/notifications_repository.dart';
import 'package:hypertension/features/notifications/presentation/notification_bell.dart';
import 'package:hypertension/features/notifications/state/notification_providers.dart';

import '../helpers/fakes.dart';
import 'auth_pages_test.dart' show fill;
import 'staff_d77_test.dart' show FakeNotifications;

// D-124: the family member's notification inbox and family registration checks.

AppNotification note(String id, String type, {Map<String, String> data = const {}}) =>
    AppNotification(
      id: id,
      title: 'Title $id',
      body: 'Body $id',
      type: type,
      category: 'alerts',
      read: false,
      data: data,
      createdAt: DateTime.now().toUtc(),
    );

void main() {
  group('family notification routes', () {
    test('family notifications open family screens only', () {
      const f = UserRole.familyMember;
      expect(notificationRoute('emergency_alert', {'alertId': 'a1'}, f), '/family/alert/a1');
      expect(notificationRoute('escalation', const {}, f), '/family/home');
      expect(notificationRoute('bp_alert', const {}, f), '/family/home');
      expect(notificationRoute('family_link', const {}, f), '/family/link');
      expect(notificationRoute('order', const {}, f), isNull); // never a patient page
      // The patient keeps the patient routes.
      expect(notificationRoute('bp_alert', const {}, UserRole.patient), '/dashboard');
    });

    test('the family tabs switch tab instead of stacking', () {
      expect(isTabRoute('/family/home'), isTrue);
      expect(isTabRoute('/family/alert/a1'), isFalse);
    });
  });

  group('family bell and inbox', () {
    late FakeNotifications notes;
    setUp(() => notes = FakeNotifications());

    Widget app(StreamController<String?> uid) {
      final router = GoRouter(
        initialLocation: '/family/home',
        routes: [
          GoRoute(
            path: '/family/home',
            builder: (_, _) => Scaffold(
              appBar: AppBar(actions: const [NotificationBell(page: '/family/notifications')]),
            ),
          ),
          GoRoute(path: '/family/notifications', builder: (_, _) => const NotificationsPage()),
          GoRoute(
            path: '/family/alert/:id',
            builder: (_, s) => Text('ALERT ${s.pathParameters['id']}'),
          ),
        ],
      );
      return ProviderScope(
        overrides: [
          notificationsRepositoryProvider.overrideWithValue(notes),
          authUidProvider.overrideWith((ref) => uid.stream),
          currentUserProvider.overrideWith(
            (ref) => Stream.value(
              const AppUser(
                uid: 'f1',
                role: UserRole.familyMember,
                name: 'Mei',
                email: 'm@x.my',
                isActive: true,
              ),
            ),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      );
    }

    testWidgets('the bell opens the family inbox and an alert opens the alert', (t) async {
      notes.items = [
        note('n1', 'emergency_alert', data: {'alertId': 'a9'}),
      ];
      final uid = StreamController<String?>()..add('f1');
      addTearDown(uid.close);
      await t.pumpWidget(app(uid));
      await t.pumpAndSettle();
      expect(find.text('1'), findsOneWidget); // unread badge
      await t.tap(find.byKey(const Key('notification-bell')));
      await t.pumpAndSettle();
      expect(find.text('Title n1'), findsOneWidget);
      await t.tap(find.byKey(const Key('notification-n1')));
      await t.pumpAndSettle();
      expect(find.text('ALERT a9'), findsOneWidget);
      expect(notes.calls, contains('read:n1'));
    });

    testWidgets("switching account reloads the inbox (no previous account's items)", (t) async {
      notes.items = [note('p1', 'bp_alert')];
      final uid = StreamController<String?>()..add('patient-1');
      addTearDown(uid.close);
      await t.pumpWidget(app(uid));
      await t.pumpAndSettle();
      expect(find.text('1'), findsOneWidget);
      // Same phone signs in as the family member, who has no notifications.
      notes.items = [];
      uid.add('f1');
      await t.pumpAndSettle();
      expect(find.text('1'), findsNothing);
    });
  });

  group('family registration', () {
    test('names must be names', () {
      for (final bad in ['12345', 'Ali123', '<b>', 'a', '  ']) {
        expect(Validators.name(bad), isNotNull, reason: bad);
      }
      for (final ok in [
        'Siti binti Ali',
        'Ravi a/l Kumar',
        'Ahmad @ Mat',
        "O'Neil",
        'Tan Mei-Ling',
      ]) {
        expect(Validators.name(ok), isNull, reason: ok);
      }
    });

    tallTest('shows the Harvey logo and checks every field', (t) async {
      final repo = FakeAuthRepository();
      await t.pumpWidget(harness(const RegisterPage(family: true), repo: repo));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('register-logo-family')), findsOneWidget);
      expect(find.text('Harvey Family'), findsOneWidget);

      await t.tap(find.byKey(const Key('register-submit')));
      await t.pumpAndSettle();
      expect(find.text('Enter your full name.'), findsOneWidget);
      expect(find.text('Enter your email address.'), findsOneWidget);
      expect(find.text('Confirm your password.'), findsOneWidget);
      expect(repo.lastRegisterRole, isNull);

      await fill(t, 'register-name', 'Mei 2');
      await fill(t, 'register-email', 'not-an-email');
      await fill(t, 'register-password', 'short');
      await fill(t, 'register-confirm', 'different');
      await t.pumpAndSettle();
      expect(find.textContaining('Use letters only'), findsOneWidget);
      expect(find.text('Enter a valid email address.'), findsOneWidget);
      expect(find.text('Passwords do not match.'), findsOneWidget);

      await fill(t, 'register-name', 'Tan Mei Ling');
      await fill(t, 'register-email', 'mei@x.my');
      await fill(t, 'register-password', 'goodpass1');
      await fill(t, 'register-confirm', 'goodpass1');
      await t.tap(find.byKey(const Key('register-submit')));
      await t.pumpAndSettle();
      expect(repo.lastRegisterRole, UserRole.familyMember);
    });
  });
}
