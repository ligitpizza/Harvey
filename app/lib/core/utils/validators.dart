/// Form validators shared by all entrypoints. Each returns an error message or null.
abstract final class Validators {
  /// D-28: patients must be at least 13 years old.
  static const minimumAge = 13;

  static final _email = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
  // D-82: Malaysian mobile: 01X then 7 digits (011: 8), after +60 / 60 / 0.
  static final _myMobile = RegExp(r'^1(1\d{8}|[02-9]\d{7})$');
  static final _letter = RegExp(r'[A-Za-z]');
  static final _digit = RegExp(r'[0-9]');

  static const passwordRule = 'At least 8 characters, including a letter and a number.';

  static String? email(String? value) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) return 'Enter your email address.';
    if (!_email.hasMatch(v)) return 'Enter a valid email address.';
    return null;
  }

  /// UC1.1 E2: password complexity.
  static String? password(String? value) {
    final v = value ?? '';
    if (v.length < 8 || !_letter.hasMatch(v) || !_digit.hasMatch(v)) {
      return passwordRule;
    }
    return null;
  }

  static String? requiredText(String? value, {String label = 'This field'}) {
    return (value?.trim() ?? '').isEmpty ? '$label is required.' : null;
  }

  // D-124: letters (any language), spaces and . ' - @ / as in "Siti binti Ali",
  // "Ravi a/l Kumar", "O'Neil", "Ahmad @ Mat".
  static final _nameChars = RegExp(r"^[\p{L}\p{M} .'@/-]+$", unicode: true);
  static final _nameLetter = RegExp(r'\p{L}', unicode: true);

  static String? name(String? value) {
    final v = value?.trim() ?? '';
    if (v.length < 2) return 'Enter your full name.';
    if (v.length > 100) return 'Name is too long.';
    if (!_nameChars.hasMatch(v) || _nameLetter.allMatches(v).length < 2) {
      return 'Use letters only (spaces and . \' - @ / are fine).';
    }
    return null;
  }

  static const phoneRule = 'Enter a Malaysian mobile number, e.g. 012-345 6789.';

  /// D-82: a Malaysian mobile number (+60). Spaces and dashes are fine.
  static String? phone(String? value) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) return 'Enter a phone number.';
    return normaliseMyPhone(v) == null ? phoneRule : null;
  }

  /// '012-345 6789' / '+60 12 345 6789' -> '+60123456789'; null when it isn't one.
  static String? normaliseMyPhone(String value) {
    var d = value.replaceAll(RegExp(r'[\s-]'), '');
    if (d.startsWith('+60')) {
      d = d.substring(3);
    } else if (d.startsWith('60')) {
      d = d.substring(2);
    } else if (d.startsWith('0')) {
      d = d.substring(1);
    } else {
      return null;
    }
    return _myMobile.hasMatch(d) ? '+60$d' : null;
  }

  /// D-82: home address at sign-up.
  static String? address(String? value) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) return 'Enter your home address.';
    if (v.length < 10) return 'Enter the full address (street, postcode, city).';
    return null;
  }

  /// Numeric range check used by onboarding (height, weight, ...).
  static String? numberInRange(String? value, num min, num max, {required String label}) {
    final n = num.tryParse(value?.trim() ?? '');
    if (n == null) return '$label is required.';
    if (n < min || n > max) return '$label must be between $min and $max.';
    return null;
  }

  /// Latest date of birth allowed today (exactly [minimumAge] years ago).
  static DateTime latestAllowedDob(DateTime now) =>
      DateTime(now.year - minimumAge, now.month, now.day);

  /// Whole years between [dob] and [now].
  static int ageOn(DateTime dob, DateTime now) {
    var age = now.year - dob.year;
    if (now.month < dob.month || (now.month == dob.month && now.day < dob.day)) age--;
    return age;
  }

  static String? dateOfBirth(DateTime? dob, DateTime now) {
    if (dob == null) return 'Date of birth is required.';
    if (ageOn(dob, now) < minimumAge) {
      return 'You must be at least $minimumAge years old to use Harvey.';
    }
    return null;
  }
}
