import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hypertension/core/constants/enums.dart';
import 'package:hypertension/core/utils/login_alias.dart';
import 'package:hypertension/features/auth/presentation/login_page.dart';
import 'package:hypertension/features/auth/presentation/setup_code_page.dart';
import 'package:hypertension/features/walk_in/walk_in_page.dart';
import 'package:hypertension/shared/providers/api_providers.dart';
import 'package:hypertension/shared/services/api/api_client.dart';

import '../helpers/fakes.dart';

// D-129: walk-in patients without an email (UC1.1 at the counter, UC1.2 sign-in, D-80).

Future<void> fill(WidgetTester t, String key, String text) =>
    t.enterText(find.byKey(Key(key)), text);

class WalkInApi extends FakeApiClient {
  Map<String, dynamic>? registered;
  final codes = <String>[];

  @override
  Future<Map<String, dynamic>> registerWalkIn(
    String name,
    String? email,
    String icNumber, {
    String? nationality,
    String? phone,
  }) async {
    registered = {'name': name, 'email': email, 'ic': icNumber, 'phone': phone};
    return {'uid': 'p9', 'emailSent': false, 'setupCode': email == null ? '482913' : null};
  }

  @override
  Future<Map<String, dynamic>> walkInSetupCode(String uid) async {
    codes.add(uid);
    return {'uid': uid, 'setupCode': '111222'};
  }

  @override
  Future<Map<String, dynamic>> findWalkInPatients(String q) async => {
    'patients': [
      {'id': 'p2', 'name': 'Ah Kow', 'email': null, 'phone': '+60123456789', 'hasEmail': false},
    ],
  };

  @override
  Future<Map<String, dynamic>> walkInDoctors() async => {'workingDay': true, 'doctors': []};
}

Future<void> pumpWalkIn(WidgetTester t, WalkInApi api) async {
  t.view.physicalSize = const Size(1300, 1400);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: const MaterialApp(home: Scaffold(body: WalkInPage())),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  test('D-129 the sign-in alias matches the backend rule', () {
    expect(loginAlias('880202-14-5566'), '880202145566@id.harvey.invalid');
    expect(loginAlias(' A1234567 '), 'a1234567@id.harvey.invalid');
    expect(signInEmail('mei@x.my'), 'mei@x.my');
    expect(isLoginAlias('880202145566@id.harvey.invalid'), isTrue);
    expect(isLoginAlias('mei@x.my'), isFalse);
  });

  group('D-129 sign-in', () {
    tallTest('a patient signs in with their MyKad number', (t) async {
      final repo = FakeAuthRepository();
      await t.pumpWidget(harness(const LoginPage(), repo: repo));
      expect(find.text('Email or MyKad/passport'), findsOneWidget);
      await fill(t, 'login-email', '880202-14-5566');
      await fill(t, 'login-password', 'secret123');
      await t.tap(find.byKey(const Key('login-submit')));
      await t.pumpAndSettle();
      expect(repo.lastSignInEmail, '880202145566@id.harvey.invalid');
      expect(repo.lastSelectedRole, UserRole.patient);
    });

    tallTest('an email still signs in as typed; a bad ID is refused', (t) async {
      final repo = FakeAuthRepository();
      await t.pumpWidget(harness(const LoginPage(), repo: repo));
      await fill(t, 'login-email', '1234');
      await fill(t, 'login-password', 'secret123');
      await t.tap(find.byKey(const Key('login-submit')));
      await t.pump();
      expect(repo.calls, isEmpty);
      await fill(t, 'login-email', 'mei@x.my');
      await t.tap(find.byKey(const Key('login-submit')));
      await t.pumpAndSettle();
      expect(repo.lastSignInEmail, 'mei@x.my');
    });

    tallTest('family sign-in stays email only and has no setup-code link', (t) async {
      final repo = FakeAuthRepository();
      await t.pumpWidget(harness(const LoginPage(), repo: repo, app: ClientApp.family));
      expect(find.text('Email Address'), findsOneWidget);
      expect(find.byKey(const Key('login-setup-code')), findsNothing);
    });

    tallTest('the setup-code page sets the password for the ID alias', (t) async {
      final repo = FakeAuthRepository();
      await t.pumpWidget(harness(const SetupCodePage(), repo: repo));
      await fill(t, 'setup-id', '880202145566');
      await fill(t, 'setup-code', '482913');
      await fill(t, 'setup-password', 'NewPass123');
      await fill(t, 'setup-confirm', 'NewPass123');
      await t.tap(find.byKey(const Key('setup-submit')));
      await t.pumpAndSettle();
      expect(repo.calls, ['verify:482913:NewPass123']);
      expect(repo.lastCodeEmail, '880202145566@id.harvey.invalid');
      expect(find.byKey(const Key('setup-done')), findsOneWidget);
    });

    tallTest('a wrong code explains what to do', (t) async {
      final repo = FakeAuthRepository()
        ..codeError = ApiException('INVALID_CODE', 'That code is wrong. 4 tries left.');
      await t.pumpWidget(harness(const SetupCodePage(), repo: repo));
      await fill(t, 'setup-id', '880202145566');
      await fill(t, 'setup-code', '000000');
      await fill(t, 'setup-password', 'NewPass123');
      await fill(t, 'setup-confirm', 'NewPass123');
      await t.tap(find.byKey(const Key('setup-submit')));
      await t.pumpAndSettle();
      expect(find.textContaining('4 tries left'), findsOneWidget);
      expect(find.textContaining('ask the clinic counter'), findsOneWidget);
    });
  });

  group('D-129 walk-in counter', () {
    testWidgets('register without an email shows the setup code once', (t) async {
      final api = WalkInApi();
      await pumpWalkIn(t, api);
      await t.tap(find.byKey(const Key('walk-in-register')));
      await t.pumpAndSettle();
      await fill(t, 'walk-in-name', 'Ah Kow');
      await fill(t, 'walk-in-phone', '012-345 6789');
      await fill(t, 'walk-in-ic', '880202145566');
      await t.tap(find.byKey(const Key('walk-in-save')));
      await t.pumpAndSettle();
      expect(api.registered!['email'], isNull);
      expect(api.registered!['phone'], '012-345 6789');
      expect(find.byKey(const Key('walk-in-code-dialog')), findsOneWidget);
      expect(find.text('482913'), findsOneWidget);
      await t.tap(find.byKey(const Key('walk-in-code-done')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('walk-in-patient')), findsOneWidget);
      expect(find.textContaining('signs in with MyKad/passport'), findsOneWidget);
    });

    testWidgets('a bad optional phone is refused before sending', (t) async {
      final api = WalkInApi();
      await pumpWalkIn(t, api);
      await t.tap(find.byKey(const Key('walk-in-register')));
      await t.pumpAndSettle();
      await fill(t, 'walk-in-name', 'Ah Kow');
      await fill(t, 'walk-in-phone', '12');
      await fill(t, 'walk-in-ic', '880202145566');
      await t.tap(find.byKey(const Key('walk-in-save')));
      await t.pumpAndSettle();
      expect(api.registered, isNull);
    });

    testWidgets('a no-email patient can get a new setup code', (t) async {
      final api = WalkInApi();
      await pumpWalkIn(t, api);
      await fill(t, 'walk-in-search', '0123456789');
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      expect(find.textContaining('+60123456789'), findsOneWidget);
      await t.tap(find.byKey(const Key('walk-in-result-p2')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('walk-in-new-code')));
      await t.pumpAndSettle();
      expect(api.codes, ['p2']);
      expect(find.text('111222'), findsOneWidget);
    });
  });
}
