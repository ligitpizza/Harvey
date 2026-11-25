import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hypertension/core/constants/enums.dart';
import 'package:hypertension/features/auth/data/auth_repository.dart';
import 'package:hypertension/shared/services/api/api_client.dart';

import '../../helpers/fakes.dart';

// D-131: a patient types another identifier of their account (UC1.2 sign-in).

/// Every sign-in is rejected; [stopAt] is rejected as deactivated so the test can see the
/// retry happened without building a whole signed-in user.
class _Auth extends Fake implements FirebaseAuth {
  _Auth(this.stopAt);

  final String stopAt;
  final tried = <String>[];

  @override
  Future<UserCredential> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    tried.add(email);
    throw FirebaseAuthException(code: email == stopAt ? 'user-disabled' : 'invalid-credential');
  }
}

class _Db extends Fake implements FirebaseFirestore {}

class _Api extends FakeApiClient {
  _Api(this.answer);

  final String? answer;
  final resolved = <String>[];
  final failed = <String>[];

  @override
  Future<String> resolveSignIn(String identifier, String password) async {
    resolved.add('$identifier:$password');
    if (answer == null) throw ApiException('INVALID_CREDENTIALS', 'Incorrect email or password.');
    return answer!;
  }

  @override
  Future<void> reportLoginFailed({
    required String email,
    required String reason,
    required String app,
  }) async => failed.add('$email:$reason');
}

Future<Object?> signIn(FirebaseAuthRepository repo, String email, UserRole role) async {
  try {
    await repo.signIn(
      email: email,
      password: 'Yoo_jews1',
      selectedRole: role,
      app: ClientApp.patient,
    );
    return null;
  } catch (e) {
    return e;
  }
}

void main() {
  test('a MyKad alias the account does not use is resolved to its email login', () async {
    final auth = _Auth('kow@x.my');
    final api = _Api('kow@x.my');
    final repo = FirebaseAuthRepository(auth: auth, firestore: _Db(), api: api);
    final e = await signIn(repo, '081229780003@id.harvey.invalid', UserRole.patient);
    expect(auth.tried, ['081229780003@id.harvey.invalid', 'kow@x.my']);
    expect(api.resolved, ['081229780003:Yoo_jews1']); // the number, not the alias
    expect((e! as AuthFailure).reason, LoginFailureReason.accountDeactivated);
  });

  test('a contact email is resolved to the MyKad alias login', () async {
    final auth = _Auth('041229070447@id.harvey.invalid');
    final api = _Api('041229070447@id.harvey.invalid');
    final repo = FirebaseAuthRepository(auth: auth, firestore: _Db(), api: api);
    await signIn(repo, 'kow+user1@x.my', UserRole.patient);
    expect(auth.tried, ['kow+user1@x.my', '041229070447@id.harvey.invalid']);
  });

  test('no match keeps the normal wrong-password message, tried once', () async {
    final auth = _Auth('-');
    final api = _Api(null);
    final repo = FirebaseAuthRepository(auth: auth, firestore: _Db(), api: api);
    final e = await signIn(repo, 'kow@x.my', UserRole.patient);
    expect(auth.tried, ['kow@x.my']);
    expect((e! as AuthFailure).reason, LoginFailureReason.invalidCredentials);
    expect(api.failed.single, startsWith('kow@x.my:'));
  });

  test('family sign-in is never resolved', () async {
    final auth = _Auth('-');
    final api = _Api('x@x.my');
    final repo = FirebaseAuthRepository(auth: auth, firestore: _Db(), api: api);
    await signIn(repo, 'fam@x.my', UserRole.familyMember);
    expect(api.resolved, isEmpty);
    expect(auth.tried, ['fam@x.my']);
  });
}
