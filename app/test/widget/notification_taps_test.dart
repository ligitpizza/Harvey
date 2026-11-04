import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hypertension/core/app.dart';
import 'package:hypertension/core/constants/enums.dart';
import 'package:hypertension/features/auth/domain/app_user.dart';
import 'package:hypertension/features/auth/state/auth_providers.dart';
import 'package:hypertension/shared/services/push/notification_taps.dart';

// D-80: tapping a phone notification (push or dose reminder) opens its screen.

const patient = AppUser(
  uid: 'p1',
  email: 'p@x.my',
  name: 'Siti',
  role: UserRole.patient,
  isActive: true,
  onboardingComplete: true,
);

GoRouter router() => GoRouter(
  initialLocation: '/dashboard',
  routes: [
    ShellRoute(
      builder: (_, s, child) =>
          Scaffold(body: child, bottomNavigationBar: Text('TABS ${s.matchedLocation}')),
      routes: [
        GoRoute(path: '/dashboard', builder: (_, _) => const Text('HOME')),
        GoRoute(path: '/medications', builder: (_, _) => const Text('MEDS PAGE')),
      ],
    ),
    GoRoute(path: '/chat/:id', builder: (_, s) => Text('CHAT ${s.pathParameters['id']}')),
  ],
);

Future<GoRouter> pump(WidgetTester t) async {
  final r = router();
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        currentUserProvider.overrideWith((ref) => Stream.value(patient)),
        clientAppProvider.overrideWithValue(ClientApp.patient),
      ],
      child: Consumer(
        builder: (context, ref, _) {
          ref.watch(currentUserProvider);
          ref.listen(notificationTapProvider, (_, next) {
            final data = next.value;
            if (data != null) openNotificationTap(ref, r, data);
          });
          return MaterialApp.router(routerConfig: r);
        },
      ),
    ),
  );
  await t.pumpAndSettle();
  return r;
}

void main() {
  test('local payloads: dose reminders and pushes shown in the app', () {
    expect(NotificationTaps.fromPayload('dose:m1'), {'type': 'dose', 'id': 'm1'});
    expect(NotificationTaps.fromPayload('{"type":"message","from":"d1"}'), {
      'type': 'message',
      'from': 'd1',
    });
    expect(NotificationTaps.fromPayload('nonsense'), isNull);
    expect(NotificationTaps.fromPayload(null), isNull);
  });

  testWidgets('a take-medicine reminder opens the Meds tab with its content', (t) async {
    await pump(t);
    NotificationTaps.add({'type': 'dose', 'id': 'm1'});
    await t.pumpAndSettle();
    expect(find.text('MEDS PAGE'), findsOneWidget);
    expect(find.text('TABS /medications'), findsOneWidget);
  });

  testWidgets('a doctor message opens that chat on top, so back returns', (t) async {
    final r = await pump(t);
    NotificationTaps.add({'type': 'message', 'from': 'd1'});
    await t.pumpAndSettle();
    expect(find.text('CHAT d1'), findsOneWidget);
    r.pop();
    await t.pumpAndSettle();
    expect(find.text('HOME'), findsOneWidget);
  });
}
