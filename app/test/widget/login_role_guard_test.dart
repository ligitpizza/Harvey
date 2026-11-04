import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hypertension/core/constants/enums.dart';
import 'package:hypertension/core/router/routers.dart';
import 'package:hypertension/features/auth/domain/app_user.dart';
import 'package:hypertension/features/auth/state/auth_providers.dart';

import '../helpers/fakes.dart';

// D-80: on the patient toggle, a family account must not slip into the family home while
// sign-in is still checking the selected role (it flashed, then signed out silently).

const family = AppUser(
  uid: 'f1',
  email: 'f@x.my',
  name: 'Aisyah',
  role: UserRole.familyMember,
  isActive: true,
);

class _Signed extends Notifier<AppUser?> {
  @override
  AppUser? build() => null;
  void set(AppUser? u) => state = u;
}

final _signed = NotifierProvider<_Signed, AppUser?>(_Signed.new);

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 5; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  testWidgets('a signed-in family account stays on login while sign-in is busy', (t) async {
    final container = ProviderContainer(
      overrides: [
        clientAppProvider.overrideWithValue(ClientApp.patient),
        authRepositoryProvider.overrideWithValue(FakeAuthRepository()),
        authUidProvider.overrideWith((ref) => Stream.value(ref.watch(_signed)?.uid)),
        currentUserProvider.overrideWith((ref) => Stream.value(ref.watch(_signed))),
      ],
    );
    addTearDown(container.dispose);
    // Keep the router provider listened, as the app does (otherwise Riverpod pauses it).
    final router = container.listen(patientRouterProvider, (_, _) {}).read();
    String where() => router.routerDelegate.currentConfiguration.uri.path;
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await settle(t);
    expect(where(), '/login');

    // Sign-in starts: Firebase signs in the family account before the role check ends.
    container.read(authBusyProvider.notifier).set(true);
    container.read(_signed.notifier).set(family);
    await settle(t);
    expect(where(), '/login'); // no jump to /family/home

    // The role check fails: signed out, still on login (the page shows the error).
    container.read(_signed.notifier).set(null);
    container.read(authBusyProvider.notifier).set(false);
    await settle(t);
    expect(where(), '/login');
  });
}
