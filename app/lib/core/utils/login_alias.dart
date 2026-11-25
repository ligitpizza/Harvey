/// D-129: a walk-in patient registered without an email signs in with their MyKad or
/// passport number. Firebase needs an email, so the account's login is an alias built
/// from the number at a reserved `.invalid` domain (never receives mail). Must match
/// backend/app/services/login_alias.py.
library;

const loginAliasDomain = 'id.harvey.invalid';

/// 900101-14-5678 -> 900101145678@id.harvey.invalid; A1234567 -> a1234567@id.harvey.invalid.
String loginAlias(String identityNumber) =>
    '${identityNumber.replaceAll(RegExp(r'[\s-]'), '').toLowerCase()}@$loginAliasDomain';

bool isLoginAlias(String? email) =>
    (email ?? '').trim().toLowerCase().endsWith('@$loginAliasDomain');

/// The sign-in page field: an email as typed, or the alias of a MyKad/passport number.
String signInEmail(String typed) => typed.contains('@') ? typed.trim() : loginAlias(typed);
